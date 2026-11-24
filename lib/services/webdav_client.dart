import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// WebDAV 传输/协议错误。[status] 为 HTTP 状态码（无响应时为 null）。
class WebDavException implements Exception {
  final String message;
  final int? status;

  WebDavException(this.message, [this.status]);

  @override
  String toString() => message;
}

/// 目录项（PROPFIND 结果）
class WebDavEntry {
  final String name;
  final String rel;
  final bool isDir;
  final int size;
  final double mtime;
  final String etag;

  const WebDavEntry({
    required this.name,
    required this.rel,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
    this.etag = '',
  });
}

/// 一次响应的原始内容
class WebDavResponse {
  final int status;
  final List<int> body;
  /// The validator from this exact response, never from an earlier listing.
  final String etag;

  const WebDavResponse(this.status, this.body, {this.etag = ''});
}

/// 极简 WebDAV 客户端：只用 dart:io HttpClient，无第三方依赖。
/// 覆盖 PC 端 sync_engine 用到的 PROPFIND / MKCOL / PUT / MOVE / GET / DELETE。
class WebDavClient {
  final String baseUrl;
  final String username;
  final String password;
  final String remoteDir;
  final Duration timeout;
  final bool verifyTls;

  static const defaultRemoteDir = 'DDNovelReader';
  static const userAgent = 'DDNovelReader-Android-WebDAVSync/1';

  WebDavClient({
    required String server,
    this.username = '',
    this.password = '',
    String? remoteDir,
    this.timeout = const Duration(seconds: 20),
    this.verifyTls = true,
  })  : baseUrl = _normalize(server),
        remoteDir = ((remoteDir ?? defaultRemoteDir).trim()).replaceAll(
              RegExp(r'^/+|/+$'),
              '',
            );

  static String _normalize(String server) {
    var url = server.trim();
    if (url.isEmpty) {
      throw WebDavException('服务器地址为空');
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
      url = 'https://$url';
    }
    return url.replaceAll(RegExp(r'/+$'), '') + '/';
  }

  /// 拼远端 URL；rel 用 / 分隔、逐段转义（兼容中文目录名）。
  String urlOf([String rel = '']) {
    final parts = <String>[];
    if (remoteDir.isNotEmpty) {
      parts.add(remoteDir
          .split('/')
          .where((s) => s.isNotEmpty)
          .map(Uri.encodeComponent)
          .join('/'));
    }
    if (rel.isNotEmpty) {
      parts.add(rel
          .split('/')
          .where((s) => s.isNotEmpty)
          .map(Uri.encodeComponent)
          .join('/'));
    }
    final tail = parts.where((p) => p.isNotEmpty).join('/');
    if (tail.isEmpty) return baseUrl;
    // 目录本身以 / 结尾
    return baseUrl + tail + (rel.isEmpty ? '/' : '');
  }

  Map<String, String> get _baseHeaders {
    final h = <String, String>{'User-Agent': userAgent};
    if (username.isNotEmpty) {
      final token = base64.encode(utf8.encode('$username:$password'));
      h['Authorization'] = 'Basic $token';
    }
    return h;
  }

  Future<WebDavResponse> _request(
    String method,
    String rel, {
    List<int>? body,
    Map<String, String>? headers,
    Set<int> allow = const {},
    String? targetUrl,
    bool followRedirects = true,
  }) async {
    final http = HttpClient()..connectionTimeout = timeout;
    if (!verifyTls) {
      http.badCertificateCallback = (cert, host, port) => true;
    }
    try {
      final req = await http.openUrl(method, Uri.parse(targetUrl ?? urlOf(rel)))
          .timeout(timeout);
      req.followRedirects = followRedirects;
      _baseHeaders.forEach((k, v) {
        req.headers.set(k, v, preserveHeaderCase: true);
      });
      if (headers != null) {
        headers.forEach((k, v) {
          req.headers.set(k, v, preserveHeaderCase: true);
        });
      }
      // 显式声明长度：清空/不设 contentLength 时部分服务端会收不到 body
      req.contentLength = body?.length ?? 0;
      if (body != null && body.isNotEmpty) {
        req.add(body);
      }
      final resp = await req.close().timeout(timeout);
      final bytes = await resp.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      ).timeout(timeout);
      if (resp.statusCode >= 400 && !allow.contains(resp.statusCode)) {
        throw WebDavException(
          'HTTP ${resp.statusCode} $method：${httpHint(resp.statusCode)}',
          resp.statusCode,
        );
      }
      return WebDavResponse(resp.statusCode, bytes,
        etag: resp.headers.value(HttpHeaders.etagHeader) ?? '');
    } on WebDavException {
      rethrow;
    } on TimeoutException {
      throw WebDavException('连接超时');
    } on SocketException catch (e) {
      throw WebDavException('连接失败：${e.message}');
    } on HandshakeException catch (e) {
      throw WebDavException('证书校验失败：${e.message}');
    } catch (e) {
      throw WebDavException('请求失败：$e');
    } finally {
      http.close(force: true);
    }
  }

  static String httpHint(int code) {
    switch (code) {
      case 401:
        return '账号或密码错误，或服务器未开启 Basic 鉴权';
      case 403:
        return '账号无权限或服务器要求其他鉴权方式';
      case 404:
        return '远端路径不存在';
      case 405:
        return '服务器不支持该 WebDAV 方法';
      case 412:
        return '远端记录已更改，请重新读取后合并';
      case 507:
        return '远端空间不足';
      case 509:
        return '远端配额已满';
      default:
        return '服务器返回错误';
    }
  }

  // ---------- 目录 ----------

  /// A missing collection is empty; unreadable/malformed listings stop sync.
  Future<List<WebDavEntry>> propfind([String rel = '', String depth = '1']) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:"><D:prop>'
        '<D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getetag/>'
        '</D:prop></D:propfind>';
    final resp = await _request(
      'PROPFIND',
      rel,
      body: utf8.encode(body),
      headers: {
        'Depth': depth,
        'Content-Type': 'application/xml; charset=utf-8',
      },
      allow: {404, 405},
    );
    if (resp.status == 404) return [];
    if (resp.status == 405) throw WebDavException('服务器不支持读取 WebDAV 目录，已停止同步', 405);
    final xml = utf8.decode(resp.body);
    if (!RegExp(r'<(?:[A-Za-z0-9_.-]+:)?multistatus\b').hasMatch(xml)) {
      throw WebDavException('WebDAV 目录响应无效，已停止同步');
    }
    final requestUrl = urlOf(rel);
    return parsePropfind(xml, urlOf(''), requestUrl: requestUrl.endsWith('/') ? requestUrl : '$requestUrl/');
  }

  /// 解析 PROPFIND 响应体（正则实现，命名空间前缀任意）。
  static List<WebDavEntry> parsePropfind(String xml, String selfUrl, {String? requestUrl}) {
    final self = Uri.parse(selfUrl);
    // pathSegments decodes exactly once on both sides. Decoding href alone
    // duplicates encoded roots, while decodeFull leaves escaped '%' ambiguous.
    final base = self.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final out = <WebDavEntry>[];
    final respRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?response\b[^>]*>([\s\S]*?)'
        r'</(?:[A-Za-z0-9_.-]+:)?response>');
    final hrefRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?href[^>]*>([\s\S]*?)'
        r'</(?:[A-Za-z0-9_.-]+:)?href>');
    final isDirRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?collection\b');
    final lenRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?getcontentlength[^>]*>'
        r'\s*([0-9]+)?\s*</(?:[A-Za-z0-9_.-]+:)?getcontentlength>');
    final lmRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?getlastmodified[^>]*>'
        r'\s*([^<]*)\s*</(?:[A-Za-z0-9_.-]+:)?getlastmodified>');
    final etRe = RegExp(r'<(?:[A-Za-z0-9_.-]+:)?getetag[^>]*>'
        r'\s*([^<]*)\s*</(?:[A-Za-z0-9_.-]+:)?getetag>');

    for (final m in respRe.allMatches(xml)) {
      final chunk = m.group(1) ?? '';
      final hm = hrefRe.firstMatch(chunk);
      if (hm == null) throw WebDavException('WebDAV 目录项缺少路径，已停止同步');
      final href = _unescapeXml((hm.group(1) ?? '').trim());
      if (href.isEmpty) throw WebDavException('WebDAV 目录项路径为空，已停止同步');
      List<String> segments;
      try {
        final resolved = Uri.parse(requestUrl ?? selfUrl).resolve(href);
        if (resolved.origin != self.origin) throw const FormatException('Different WebDAV origin');
        segments = resolved.pathSegments.where((part) => part.isNotEmpty).toList();
        if (segments.any((part) => part.contains('/') || part == '.' || part == '..')) {
          throw const FormatException('Invalid WebDAV path segment');
        }
      } catch (_) {
        throw WebDavException('WebDAV 返回了无法解析的目录路径，已停止同步');
      }
      if (segments.length < base.length ||
          List.generate(base.length, (i) => segments[i] == base[i]).contains(false)) {
        throw WebDavException('WebDAV 返回了同步根目录以外的路径，已停止同步');
      }
      if (segments.length == base.length) continue;
      final name = segments.last;
      final rel = segments.skip(base.length).join('/');
      final isDir = isDirRe.hasMatch(chunk);
      int size = 0;
      final lm2 = lenRe.firstMatch(chunk);
      if (lm2 != null) {
        size = int.tryParse(lm2.group(1) ?? '') ?? 0;
      }
      double mtime = 0;
      final lmm = lmRe.firstMatch(chunk);
      if (lmm != null) {
        mtime = parseHttpDate(lmm.group(1) ?? '');
      }
      final etm = etRe.firstMatch(chunk);
      final etag = etm == null ? '' : _unescapeXml((etm.group(1) ?? '').trim());
      out.add(WebDavEntry(name: name, rel: rel, isDir: isDir, size: size,
        mtime: mtime, etag: etag));
    }
    return out;
  }

  static String _unescapeXml(String value) => value.replaceAllMapped(
    RegExp(r'&(amp|lt|gt|quot|apos);'),
    (match) => const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}[match[1]]!);

  static double parseHttpDate(String s) {
    final t = s.trim();
    if (t.isEmpty) return 0;
    try {
      return HttpDate.parse(t).millisecondsSinceEpoch / 1000.0;
    } catch (_) {
      return 0;
    }
  }

  /// 创建单级目录；已存在（405）视为成功。
  Future<bool> mkdir(String rel) async {
    final resp = await _request(
      'MKCOL',
      rel,
      body: const <int>[],
      headers: {'Content-Type': 'text/plain'},
      allow: {301, 405, 409},
    );
    return const {200, 201, 204, 301, 405}.contains(resp.status);
  }

  /// 逐级创建目录（已存在跳过）。
  Future<void> mkdirs(String rel) async {
    var root = baseUrl;
    for (final segment in remoteDir.split('/').where((part) => part.isNotEmpty)) {
      root += '${Uri.encodeComponent(segment)}/';
      await _request('MKCOL', '', targetUrl: root, body: const <int>[], allow: {301, 405});
    }
    var cur = '';
    for (final seg in rel.split('/').where((s) => s.isNotEmpty)) {
      cur = cur.isEmpty ? seg : '$cur/$seg';
      if (!await mkdir(cur)) throw WebDavException('无法创建远端目录：$cur', 409);
    }
  }

  // ---------- 文件 ----------

  /// Fetch the complete resource and its validator in one response. Metadata
  /// consumers must distinguish a true 404 from a failed or partial read.
  Future<WebDavResponse> getWithMetadata(String rel) async {
    final response = await _request('GET', rel, allow: {404}, followRedirects: false);
    if (response.status != 200 && response.status != 404) {
      throw WebDavException('HTTP ${response.status} GET：未返回完整远端记录', response.status);
    }
    return response;
  }

  /// If-Match uses strong comparison. Missing, weak, unquoted and injected
  /// validators cannot protect a read/merge/write transaction.
  static bool isStrongEtag(String value) =>
    RegExp(r'^"[\x21\x23-\x7E\x80-\xFF]*"$').stringMatch(value) == value;

  Future<List<int>?> get(String rel) async {
    final resp = await _request('GET', rel, allow: {404});
    if (resp.status == 404) return null;
    return resp.body;
  }

  /// 写文件；优先 .part + MOVE，避免中途失败留下半截 JSON。
  /// 书源文件传 `contentType: 'application/octet-stream'` 且 `atomic: false`（大文件不必走 MOVE）。
  Future<bool> put(String rel, List<int> data,
      {bool atomic = true,
      String? etag,
      bool ifNoneMatch = false,
      String contentType = 'application/json; charset=utf-8'}) async {
    if (etag != null && ifNoneMatch) {
      throw WebDavException('If-Match与If-None-Match不能同时使用');
    }
    if (etag != null && !isStrongEtag(etag)) {
      throw WebDavException('远端缺少有效的强ETag，不能安全覆盖记录');
    }
    if (etag != null || ifNoneMatch) {
      // A target precondition cannot be transferred safely to a shared .part
      // file and unconditional MOVE. Never fall back after a failed CAS.
      final response = await _request('PUT', rel, body: data, followRedirects: false,
        headers: {'Content-Type': contentType,
          if (etag != null) 'If-Match': etag,
          if (ifNoneMatch) 'If-None-Match': '*'}, allow: {200, 201, 204});
      if (!const {200, 201, 204}.contains(response.status)) {
        throw WebDavException('HTTP ${response.status} PUT：条件写入未完成', response.status);
      }
      return true;
    }
    if (!atomic) {
      await _request('PUT', rel, body: data,
          headers: {'Content-Type': contentType}, allow: {200, 201, 204});
      return true;
    }
    final tmp = '$rel.part';
    await _request('PUT', tmp, body: data,
        headers: {'Content-Type': contentType}, allow: {200, 201, 204, 207});
    try {
      await _request('MOVE', tmp, body: const <int>[], headers: {
        'Destination': urlOf(rel),
        'Overwrite': 'T',
      }, allow: {200, 201, 204, 207});
      return true;
    } on WebDavException {
      // 服务器不支持 MOVE 时退回普通 PUT
      try {
        await _request('DELETE', tmp, allow: {200, 204, 207, 404});
      } on WebDavException {
        // 忽略清理失败
      }
      return put(rel, data, atomic: false, contentType: contentType);
    }
  }

  Future<bool> delete(String rel, {String? etag}) async {
    if (etag != null) {
      if (!isStrongEtag(etag)) {
        throw WebDavException('远端缺少有效的强ETag，不能安全删除记录');
      }
      final response = await _request('DELETE', rel, followRedirects: false,
        headers: {'If-Match': etag}, allow: {200, 204, 404});
      if (!const {200, 204, 404}.contains(response.status)) {
        throw WebDavException('HTTP ${response.status} DELETE：条件删除未完成', response.status);
      }
      return true;
    }
    try {
      await _request('DELETE', rel, allow: {200, 204, 207, 404});
      return true;
    } on WebDavException {
      return false;
    }
  }

  /// 只做连接与权限检测，返回 (ok, message, 远端书数)。
  Future<(bool, String, int)> testConnection() async {
    try {
      await mkdirs('v1/books');
      final entries = await propfind('v1/books');
      final n = entries
          .where((e) => !e.isDir && e.name.toLowerCase().endsWith('.json'))
          .length;
      return (true, '连接成功，远端已有 $n 本书记录', n);
    } on WebDavException catch (e) {
      return (false, e.message, 0);
    } catch (e) {
      return (false, '连接失败：$e', 0);
    }
  }
}
