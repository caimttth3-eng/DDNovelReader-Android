import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/book.dart';
import 'chapterizer.dart';
import 'text_cleaner.dart';

/// 书籍解析器：支持 TXT / EPUB / PDF / DOCX，并自动分章。
class BookParser {
  final TextCleaner _cleaner;

  BookParser({TextCleaner? cleaner}) : _cleaner = cleaner ?? const TextCleaner();

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
      final raw = await _readRawText(filePath, format);
      final chapters = _autoChapter(raw);
      return Book(
        id: id,
        title: title,
        filePath: filePath,
        format: format,
        chapters: chapters,
        addedAt: addedAt,
      );
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

  String _decodeTxt(List<int> bytes) {
    // 先尝试严格 UTF-8
    try {
      final s = const Utf8Decoder(allowMalformed: false).convert(bytes);
      if (!s.contains('\uFFFD')) return s;
    } catch (_) {}
    // UTF-16 LE/BE 探测（带 BOM）
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), endian: Endian.little);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), endian: Endian.big);
    }
    // 退化为宽松 UTF-8（GBK 文本会得到替换符，但至少不崩溃）
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  String _decodeUtf16(List<int> bytes, {required Endian endian}) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final code = endian == Endian.little
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      sb.writeCharCode(code);
    }
    return sb.toString();
  }

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
      final paras = _toParagraphs(body);
      if (paras.isEmpty) continue;
      chapters.add(Chapter(title: title, paragraphs: paras));
    }
    if (chapters.isEmpty) {
      chapters.add(Chapter(title: '正文', paragraphs: _toParagraphs(raw.trim())));
    }
    return chapters;
  }

  List<Paragraph> _toParagraphs(String body) {
    final blocks = body
        .split(RegExp(r'\n\s*\n'))
        .map((b) => b.replaceAll('\n', ' ').trim())
        .where((b) => b.isNotEmpty)
        .toList();
    if (blocks.isEmpty) return const [];
    return blocks.map((b) => _buildParagraph(b)).toList();
  }

  /// 构建段落：切句 + 双文本
  Paragraph _buildParagraph(String display) {
    final cleaned = _cleaner.clean(display);
    // 在 tts 文本上按句子结束符切句
    final tts = cleaned.tts;
    final sentenceSplitRe = RegExp(r'[^。！？!?；;\n]+[。！？!?；;]?');
    final sentences = <Sentence>[];
    final starts = <int>[];
    var idx = 0;
    for (final m in sentenceSplitRe.allMatches(tts)) {
      final seg = m.group(0)!;
      if (seg.trim().isEmpty) continue;
      starts.add(idx);
      // 显示层取整段对应（简化：同段落内句子级别 display 用相同子串近似）
      final dStart = cleaned.displayOffsetOfTts(idx);
      var dEnd = cleaned.displayOffsetOfTts(idx + seg.length);
      // 若 tts 长度不足，回退到段末
      if (idx + seg.length > tts.length) dEnd = cleaned.display.length;
      final dSeg = cleaned.display.substring(
        dStart.clamp(0, cleaned.display.length),
        dEnd.clamp(dStart, cleaned.display.length),
      );
      sentences.add(Sentence(dSeg, seg,
          displayStart: dStart.clamp(0, cleaned.display.length),
          displayEnd: dEnd.clamp(dStart, cleaned.display.length)));
      idx += seg.length;
    }
    if (sentences.isEmpty && tts.trim().isNotEmpty) {
      starts.add(0);
      sentences.add(Sentence(
        cleaned.display.trim(),
        tts.trim(),
        displayStart: 0,
        displayEnd: cleaned.display.length,
      ));
    }
    return Paragraph(
      display: display,
      tts: tts,
      sentences: sentences,
      sentenceStartTts: starts,
    );
  }
}
