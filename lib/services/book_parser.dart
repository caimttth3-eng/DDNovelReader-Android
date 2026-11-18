import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/book.dart';
import 'chapterizer.dart';
import 'content_key.dart';
import 'text_decoder.dart';
import 'tts_text.dart';

/// 书籍解析器：支持 TXT / EPUB / PDF / DOCX，并自动分章。
class BookParser {
  BookParser();

  /// 阅读页会缓存格式化后的整本书；上限用来避免长期驻留超大书。
  static const maxCachedDisplayCharacters = 4000000;

  static bool fitsMemoryCache(Book book) =>
      book.totalDisplayLength <= maxCachedDisplayCharacters;

  static void clearMemoryCache() {}

  /// 目录索引：默认一章一条（我们的分章已经把标题切成章），
  /// autoExtractToc=false 时退化为每 5000 字一条的兜底目录。
  static List<BookTocEntry> extractToc(Book source, {bool autoExtractToc = true}) {
    final entries = <BookTocEntry>[];
    if (!autoExtractToc) {
      final whitespace = RegExp(r'\s');
      var count = 0, next = 0;
      for (var c = 0; c < source.chapters.length; c++) {
        final paragraphs = source.chapters[c].paragraphs;
        for (var p = 0; p < paragraphs.length; p++) {
          final text = paragraphs[p].display;
          for (var offset = 0; offset < text.length; offset++) {
            if (whitespace.hasMatch(text[offset])) continue;
            if (count >= next) {
              entries.add(BookTocEntry(
                  title: '第 ${entries.length + 1} 节',
                  chapterIndex: c,
                  paragraphIndex: p,
                  displayOffset: offset));
              next = count + 5000;
            }
            count++;
          }
        }
      }
      return entries;
    }
    for (var c = 0; c < source.chapters.length; c++) {
      final ch = source.chapters[c];
      if (ch.paragraphs.isEmpty) continue;
      entries.add(BookTocEntry(
          title: ch.title, chapterIndex: c, paragraphIndex: 0));
    }
    return entries;
  }

  /// 章节标题匹配：中文「第X章/节/回/卷」或英文 Chapter N
  static final RegExp chapterTitleRe = RegExp(
    r'^\s*(第\s*[0-9零一二三四五六七八九十百千万两0-9]+\s*[章章节回卷部篇]|Chapter\s+\d+|CHAPTER\s+\d+)[^\S\n]*.*$',
  );

  /// 解析文件
  Future<Book> parse({
    required String id,
    required String filePath,
    required String title,
    required BookFormat format,
    required DateTime addedAt,
  }) async {
    try {
      // 解析结果按「路径+大小+修改时间」缓存一份：同一本书再次打开不必重读重分章
      final stat = await File(filePath).stat();
      final cacheKey = '$filePath|${stat.size}|${stat.modified.millisecondsSinceEpoch}|$id';
      final cached = _parsedCache[cacheKey];
      if (cached != null) return cached;
      final raw = await _readRawText(filePath, format);
      final chapters = _autoChapter(raw);
      final book = Book(
        id: id,
        title: title,
        filePath: filePath,
        format: format,
        chapters: chapters,
        addedAt: addedAt,
      );
      // content_key 与音频缓存目录一级键同一值，跨端（PC/安卓）可命中
      final result = book.withContentKey(
        computeContentKey(title, book.chapters.length, bookFullText(book)),
      );
      _parsedCache[cacheKey] = result;
      if (_parsedCache.length > 2) {
        _parsedCache.remove(_parsedCache.keys.first);
      }
      return result;
    } catch (e) {
      return Book.failed(
        id: id,
        title: title,
        filePath: filePath,
        format: format,
        addedAt: addedAt,
        error: e.toString(),
      );
    }
  }

  /// 最近解析过的书籍（最多 2 本），避免重复打开同一本书时重新分章
  static final Map<String, Book> _parsedCache = {};


  /// 读取各格式原始文本
  Future<String> _readRawText(String path, BookFormat format) async {
    switch (format) {
      case BookFormat.txt:
        return _readTxt(path);
      case BookFormat.epub:
        return _readEpub(path);
      case BookFormat.pdf:
        return _readPdf(path);
      case BookFormat.docx:
        return _readDocx(path);
    }
  }

  Future<String> _readTxt(String path) async {
    final bytes = await File(path).readAsBytes();
    return _decodeTxt(bytes);
  }

  /// txt 解码统一走 text_decoder（与 PC _decode 同口径：BOM → 严格 UTF-8 →
  /// GB18030 / Big5 质量打分择优 → 宽松 UTF-8 兜底）
  String _decodeTxt(List<int> bytes) => decodeTextBytes(bytes);

  Future<String> _readEpub(String path) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    // 找 content.opf
    final opfName = archive.files
        .firstWhere(
          (f) => f.name.endsWith('.opf') && f.isFile,
          orElse: () => throw Exception('未找到 EPUB 目录文件 (content.opf)'),
        )
        .name;
    final opfXml = XmlDocument.parse(
      utf8.decode((archive.find(opfName)?.content as List<int>?) ?? []),
    );
    // 提取 spine 顺序 idref
    final manifest = <String, String>{};
    for (final item in opfXml.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final media = item.getAttribute('media-type') ?? '';
      if (id != null && href != null && (media.contains('html') || media.contains('xhtml') || href.endsWith('.html') || href.endsWith('.xhtml'))) {
        manifest[id] = href;
      }
    }
    final spineOrder = <String>[];
    for (final itemref in opfXml.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null) spineOrder.add(idref);
    }
    if (spineOrder.isEmpty) {
      spineOrder.addAll(manifest.keys);
    }
    final baseDir = opfName.contains('/')
        ? opfName.substring(0, opfName.lastIndexOf('/') + 1)
        : '';
    final sb = StringBuffer();
    for (final id in spineOrder) {
      final href = manifest[id];
      if (href == null) continue;
      final resolved = _resolveHref(baseDir, href);
      final f = archive.find(resolved);
      if (f == null || !f.isFile) continue;
      final htmlBytes = f.content as List<int>;
      final html = utf8.decode(htmlBytes, allowMalformed: true);
      sb.write(_htmlToText(html));
      sb.write('\n\n');
    }
    return sb.toString();
  }

  String _resolveHref(String baseDir, String href) {
    final clean = href.split('#').first.split('?').first;
    // 简单处理相对路径
    var segments = <String>[];
    if (baseDir.isNotEmpty) {
      segments = baseDir.split('/');
      if (segments.last.isEmpty) segments.removeLast();
    }
    final parts = clean.split('/');
    for (final p in parts) {
      if (p == '.' || p.isEmpty) continue;
      if (p == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else {
        segments.add(p);
      }
    }
    return segments.join('/');
  }

  String _htmlToText(String html) {
    var s = html;
    // 移除 script/style
    s = s.replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), ' ');
    // 段落与换行标签 -> 换行
    s = s.replaceAll(
        RegExp(r'<(p|div|br|h[1-6]|li|tr|section)[^>]*>', caseSensitive: false),
        '\n');
    // 移除其余标签
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    // 实体解码
    s = _decodeEntities(s);
    return s.trim();
  }

  String _decodeEntities(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!) ?? 63;
          return String.fromCharCode(code);
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16) ?? 63;
          return String.fromCharCode(code);
        });
  }

  Future<String> _readPdf(String path) async {
    final bytes = await File(path).readAsBytes();
    return _extractPdfText(bytes);
  }

  /// PDF 文本提取：解 Flate 流 + 解析 Tj/TJ 操作符，按 Td/TD/T* 换行。
  String _extractPdfText(List<int> bytes) {
    final s = latin1.decode(bytes);
    final streams = <Uint8List>[];
    final re = RegExp(r'stream\r?\n([\s\S]*?)endstream');
    for (final m in re.allMatches(s)) {
      try {
        final raw = m.group(1)!;
        final compressed = raw.codeUnits.where((c) => c < 256).toList();
        final inflated = Inflate(compressed).getBytes();
        streams.add(inflated);
      } catch (_) {}
    }
    final sb = StringBuffer();
    for (final st in streams) {
      sb.write(_parseContentStream(st));
      sb.write('\n');
    }
    return sb.toString();
  }

  String _parseContentStream(List<int> bytes) {
    final s = latin1.decode(bytes);
    final out = StringBuffer();
    // 用正则切出文本操作与定位操作，按出现顺序处理
    final opRe = RegExp(
        r'\((?:[^()\\]|\\.)*\)\s*Tj|\[(?:[^\[\]])*\]\s*TJ|TD|Td|T\*|Tj|TJ');
    var lineBuf = StringBuffer();
    void flushLine() {
      if (lineBuf.isNotEmpty) {
        out.write(lineBuf.toString().trim());
        out.write('\n');
        lineBuf.clear();
      }
    }

    for (final m in opRe.allMatches(s)) {
      final op = m.group(0)!;
      if (op.endsWith('Tj')) {
        final str = _parsePdfString(op.substring(0, op.lastIndexOf(')') + 1));
        if (str.isNotEmpty) lineBuf.write(str);
      } else if (op.endsWith('TJ')) {
        final arr = op.substring(1, op.lastIndexOf(']'));
        for (final tm in RegExp(r'\((?:[^()\\]|\\.)*\)').allMatches(arr)) {
          lineBuf.write(_parsePdfString(tm.group(0)!));
        }
      } else {
        // Td / TD / T*
        flushLine();
      }
    }
    flushLine();
    return out.toString();
  }

  String _parsePdfString(String s) {
    var inner = s.substring(1, s.length - 1);
    final sb = StringBuffer();
    for (var i = 0; i < inner.length; i++) {
      final c = inner[i];
      if (c == '\\' && i + 1 < inner.length) {
        final n = inner[i + 1];
        switch (n) {
          case 'n':
            sb.write('\n');
            break;
          case 'r':
            sb.write('\r');
            break;
          case 't':
            sb.write('\t');
            break;
          case '(':
            sb.write('(');
            break;
          case ')':
            sb.write(')');
            break;
          case '\\':
            sb.write('\\');
            break;
          default:
            sb.write(n);
        }
        i++;
      } else {
        sb.write(c);
      }
    }
    return sb.toString();
  }

  Future<String> _readDocx(String path) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final doc = archive.find('word/document.xml');
    if (doc == null || !doc.isFile) return '';
    final xml = utf8.decode(doc.content as List<int>, allowMalformed: true);
    return _docxXmlToText(xml);
  }

  String _docxXmlToText(String xml) {
    final doc = XmlDocument.parse(xml);
    final sb = StringBuffer();
    void walk(XmlNode node) {
      if (node is XmlElement) {
        final name = node.name.local;
        if (name == 'p') {
          if (sb.isNotEmpty && !sb.toString().endsWith('\n')) sb.write('\n');
          for (final child in node.children) {
            if (child is XmlElement && child.name.local == 't') {
              sb.write(child.innerText);
            }
          }
          sb.write('\n');
          return;
        }
        if (name == 't') return;
        for (final child in node.children) {
          walk(child);
        }
      }
    }

    walk(doc);
    return sb.toString();
  }

  /// 自动分章：优先用智能分章引擎（支持「第X卷/第X章/Chapter N/序章/楔子」及分隔线、
  /// 书名前缀等三重检测，简介单独成章）；无可靠标题时按自然段落聚合成约 5000 字小节。
  List<Chapter> _autoChapter(String raw) {
    final chapters = <Chapter>[];
    for (final (title, body) in makeChapters(raw)) {
      final ch = _buildChapter(title, body);
      if (ch != null) chapters.add(ch);
    }
    if (chapters.isEmpty) {
      final ch = _buildChapter('正文', raw.trim());
      if (ch != null) chapters.add(ch);
    }
    return chapters;
  }

  /// 构建整章：清洗与切句必须按**整章原始正文**做（与 PC 端 ch.tts_content() 同口径）。
  ///
  /// 两个必须对齐的点：
  /// 1) 喂给清洗的是 body 原文（保留行结构），不能是"段落折成空格后的拼接"——
  ///    PC 的 _strip_decor_lines 是行级过滤（`------` 整行丢弃、行尾装饰截断），
  ///    折平行结构会让它失效，两端 tts 文本与偏移随之不同。
  /// 2) 切句按整章做：段落间 '\n' 在清洗时被删，段末无句末标点时句子会跨段合并。
  ///    这里把章级句子按「起点所在块」归属，显示区间在该块内裁剪。
  Chapter? _buildChapter(String title, String body) {
    final text = body;
    if (text.trim().isEmpty) return null;

    // 段落块（按空行切；normalizeBody 已把空行折成单换行，通常整章一块）
    final blocks = <(int, int)>[];
    var pos = 0;
    for (final m in RegExp(r'\n\s*\n').allMatches(text)) {
      blocks.add((pos, m.start));
      pos = m.end;
    }
    blocks.add((pos, text.length));
    final kept = <(int, int)>[];
    final displays = <String>[];
    for (final b in blocks) {
      final seg = text.substring(b.$1, b.$2);
      if (seg.trim().isEmpty) continue;
      kept.add(b);
      // 块内换行折成空格（渲染单位）；'\n'→' ' 一对一，块内偏移不变
      displays.add(seg.replaceAll('\n', ' ').trim());
    }
    if (kept.isEmpty) return null;

    final clean = preprocessForTts(text);
    final ranges = splitSentenceRanges(clean.clean);
    final byPara = List.generate(kept.length, (_) => <Sentence>[]);

    var pIdx = 0;
    for (final (s, e) in ranges) {
      final tts = clean.clean.substring(s, e);
      if (tts.trim().isEmpty) continue;
      final u16s = s < clean.cmap.length ? clean.cmap[s] : text.length;
      final u16e = (e > s && e - 1 < clean.cmap.length)
          ? clean.cmap[e - 1] + 1
          : text.length;

      while (pIdx + 1 < kept.length && u16s >= kept[pIdx + 1].$1) {
        pIdx++;
      }
      final ps = kept[pIdx].$1;
      final pe = kept[pIdx].$2;
      final ds = (u16s - ps).clamp(0, displays[pIdx].length);
      final de = (min(u16e, pe) - ps).clamp(ds, displays[pIdx].length);
      byPara[pIdx].add(Sentence(
        displays[pIdx].substring(ds, de),
        tts,
        displayStart: ds,
        displayEnd: de,
      ));
    }

    final paragraphs = <Paragraph>[];
    for (var i = 0; i < kept.length; i++) {
      final seg = byPara[i];
      final segStarts = <int>[];
      var acc = 0;
      for (final s in seg) {
        segStarts.add(acc);
        acc += s.tts.length;
      }
      paragraphs.add(Paragraph(
        display: displays[i],
        tts: seg.map((s) => s.tts).join(),
        sentences: seg,
        sentenceStartTts: segStarts,
      ));
    }
    return Chapter(title: title, paragraphs: paragraphs);
  }
}

// ---------- 目录索引（PR2 引入，阅读页目录与自动目录共用） ----------

class BookTocEntry {
  final String title;
  final int chapterIndex;
  final int paragraphIndex;
  final int displayOffset;
  const BookTocEntry(
      {required this.title,
      required this.chapterIndex,
      required this.paragraphIndex,
      this.displayOffset = 0});
}
