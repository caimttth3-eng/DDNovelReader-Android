/// Edge TTS：调用微软 Edge 神经语音在线合成中文音频（MP3）。
/// 基于 edge-tts 7.2.8 协议逐项移植（已联网调研并核对 twn39/edgetts-dart 实现）。
///
/// 关键点（debug 排坑所得）：
/// - 必须手动 HttpClient upgrade 而非 WebSocket.connect（后者默认头被服务端 403）
/// - 握手请求头需完整（UA/Origin/Accept/Accept-Encoding/Accept-Language + Cookie: muid）
/// - SSML 消息必须带 X-RequestId 头，否则服务端 1002 关闭
/// - Sec-MS-GEC 为完整 64 位 SHA256 hex，且时钟偏差会导致 403，需 Date 头同步后重试
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String _secMsGecVersion = '1-143.0.3650.75';
const String _voiceList =
    'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=$_trustedClientToken';

/// 时钟偏差（秒），403 时通过服务器 Date 头校准
double _clockSkew = 0.0;

/// 可用中文音色
const List<String> edgeVoices = [
  'zh-CN-XiaoxiaoNeural', // 晓晓（女，温暖）
  'zh-CN-YunxiNeural', // 云希（男，阳光）
  'zh-CN-YunyangNeural', // 云扬（男，专业）
  'zh-CN-XiaoyiNeural', // 晓伊（女，活泼）
  'zh-CN-liaoning-XiaobeiNeural', // 东北话小北
  'zh-CN-shaanxi-XiaoniNeural', // 陕西话小妮
];

/// 当前 UTC Unix 时间戳 + 时钟偏差
double _nowUnix() =>
    (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0) + _clockSkew;

/// 生成 Sec-MS-GEC：完整 64 位 SHA256 hex（截断会导致 403）
String _generateSecMsGec() {
  var ticks = _nowUnix() + 11644473600.0; // 1601 epoch
  ticks -= ticks % 300.0; // 5 分钟块
  ticks *= 10000000.0; // 100ns
  final strToHash = '${ticks.toStringAsFixed(0)}$_trustedClientToken';
  return sha256.convert(utf8.encode(strToHash)).toString().toUpperCase();
}

/// 随机 MUID（握手 Cookie）
String _generateMuid() {
  final r = Random.secure();
  final values = List<int>.generate(16, (_) => r.nextInt(256));
  return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 32 位随机连接 ID
String _connectId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// JS 风格日期（speech.config 的 X-Timestamp）
String _jsDate() {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final t = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${weekdays[t.weekday - 1]} ${months[t.month - 1]} '
      '${two(t.day)} ${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}

/// ISO8601 毫秒 UTC（SSML 的 X-Timestamp，末尾由调用处补 Z）
String _isoTs() {
  final s = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${s.year}-${two(s.month)}-${two(s.day)}'
      'T${two(s.hour)}:${two(s.minute)}:${two(s.second)}.${three(s.millisecond)}';
}

/// 构建 WS 握手 headers
Map<String, String> _wssHeaders() {
  final headers = <String, String>{
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Sec-WebSocket-Version': '13',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
    'Accept': '*/*',
    'Accept-Encoding': 'gzip, deflate, br, zstd',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  headers['Cookie'] = 'muid=${_generateMuid()};';
  return headers;
}

/// 同步时钟偏差：GET voiceList 拿 Date 头
Future<void> _syncClock() async {
  try {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(_voiceList))
          .timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0');
      req.headers.set('Cookie', 'muid=${_generateMuid()};');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final date = res.headers.value(HttpHeaders.dateHeader);
      await res.drain<void>();
      if (date != null) {
        final server = HttpDate.parse(date).millisecondsSinceEpoch / 1000.0;
        _clockSkew = server - _nowUnix();
      }
    } finally {
      client.close();
    }
  } catch (_) {}
}

/// 合成单句文本为 MP3 字节。
/// 内部含一次 403 时钟同步重试。
Future<Uint8List> edgeSynth(String text,
    {String voice = 'zh-CN-XiaoxiaoNeural', String rate = '+0%'}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final result = await _synthOnce(text, voice: voice, rate: rate);
    if (result != null && result.isNotEmpty) return result;
    if (attempt == 0) {
      // 可能 403（时钟偏差）→ 同步时钟重试
      await _syncClock();
    }
  }
  return Uint8List(0);
}

/// 从音频二进制帧中提取 MP3 payload。
/// Edge TTS 音频帧格式：[2字节 big-endian headerLength][header 文本][音频数据]，
/// header 文本形如 "X-RequestId:...\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n\r\n"。
/// （与 twn39/edgetts-dart message_parser.parseBinaryMessage 一致；
///   注意二进制帧 payload 并非纯音频，之前按"纯音频"提取会把 header 混进 MP3 导致无声）
List<int> _extractAudioPayload(List<int> data) {
  if (data.length < 2) return data;
  final headerLength = (data[0] << 8) | data[1];
  if (data.length < headerLength + 2) return data;
  return data.sublist(2 + headerLength);
}

Future<Uint8List?> _synthOnce(String text,
    {required String voice, required String rate}) async {
  final connId = _connectId();
  final gec = _generateSecMsGec();
  final uri = Uri(
    scheme: 'https',
    host: 'speech.platform.bing.com',
    path: '/consumer/speech/synthesize/readaloud/edge/v1',
    queryParameters: {
      'TrustedClientToken': _trustedClientToken,
      'Sec-MS-GEC': gec,
      'Sec-MS-GEC-Version': _secMsGecVersion,
      'ConnectionId': connId,
    },
  );

  final client = HttpClient()..autoUncompress = false;
  client.connectionTimeout = const Duration(seconds: 15);
  WebSocket? ws;
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    _wssHeaders().forEach((k, v) {
      request.headers.set(k, v);
    });
    request.headers.set('Connection', 'Upgrade');
    request.headers.set('Upgrade', 'websocket');
    request.headers.set('Sec-WebSocket-Key',
        base64.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256))));

    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 101) {
      await response.drain<void>();
      return null;
    }
    final detached = await response.detachSocket();
    ws = WebSocket.fromUpgradedSocket(detached, serverSide: false);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }

  final audioBuf = BytesBuilder();
  var gotAudio = false;
  final done = Completer<Uint8List?>();
  final timer = Timer(const Duration(seconds: 20), () {
    if (!done.isCompleted) done.complete(null);
  });

  void finish() {
    if (!done.isCompleted) done.complete(gotAudio ? audioBuf.toBytes() : null);
  }

  ws.listen(
    (data) {
      if (data is List<int>) {
        // 服务端二进制帧为纯音频 payload（无文本头），直接全部作为音频
        final audio = _extractAudioPayload(data);
        if (audio.isNotEmpty) {
          audioBuf.add(audio);
          gotAudio = true;
        }
      } else if (data is String) {
        if (data.contains('Path:turn.end')) {
          finish();
        }
      }
    },
    onDone: () {
      finish();
    },
    onError: (Object e) {
      finish();
    },
  );

  // 发送 speech.config
  final config = 'X-Timestamp:$_jsDate\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n';
  ws.add(config);

  // 发送 SSML（带 X-RequestId，否则服务端 1002 关闭）
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  final ssml = 'X-RequestId:$connId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${_isoTs()}Z\r\n'
      'Path:ssml\r\n\r\n'
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
      "<voice name='$voice'><prosody pitch='+0Hz' rate='$rate' volume='+0%'>"
      '$escaped</prosody></voice></speak>';
  ws.add(ssml);

  final result = await done.future;
  timer.cancel();
  try {
    await ws.close();
  } catch (_) {}
  return result;
}
