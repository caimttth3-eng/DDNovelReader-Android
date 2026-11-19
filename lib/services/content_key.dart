/// 跨端稳定的书籍指纹（与 PC 端 novelreader/content_key.py 逐字节等价）。
///
/// 协议（ck2）：
///   raw = "ck2|" + 去空白书名 + "|" + 章节数 + "|" + 去空白全文前 2000 字
///   key = sha1(raw)[:16]
///
/// 「全文」= 所有章节正文首尾相接，不含章节标题行。
/// 样本先去空白，所以段落数量、换行、缩进、全角空格都不影响结果——
/// 这正是两端能算出同一个 key 的前提：PC 端喂「各章 content 首尾相接」，
/// 安卓端喂「各段落 display 首尾相接」。
///
/// 为什么是「章节数 + 开头样本」而不是「全文总字数」：
/// 两端解码器不同（PC 会对 UTF-8/GB18030/big5 打分，安卓只有 UTF-8），
/// 源文件里夹一段非法字节就会让「全书总字数」差几个数，整本 key 漂移、
/// 跨端缓存永远不命中。开头样本 + 章数对这类脏数据不敏感。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/book.dart';

/// 当前指纹协议版本（改动算法必须两端同步升版本）
const String ckVersion = 'ck2';

/// 旧协议版本（只用于匹配历史 WebDAV 记录，不用于新目录命名）
const String ckVersionLegacy = 'ck1';

/// 参与指纹的开头正文字符数上限（去空白之后）
const int ckSampleLimit = 2000;

/// ck1 口径的样本长度（历史记录匹配专用）
const int ckLegacySampleLimit = 1000;

/// Python `\s` 与 Dart `\s` 的差集：Python 把 0x1C-0x1F 也当作空白，
/// Dart 的正则不认（源文件里夹的二进制脏数据会因此多出几个字符，
/// 让两端「去空白后长度」对不上）。
final RegExp _wsRe = RegExp(r'[\s\u001c\u001d\u001e\u001f]+');

/// 去掉所有空白（与 PC norm_text 一致：覆盖半角/全角空格、换行、制表、BOM）
String ckNorm(String? s) => (s ?? '').replaceAll(_wsRe, '');

String _digest(String version, String title, int number, String sample,
    {int limit = ckSampleLimit}) {
  final titleN = ckNorm(title);
  final sampleN = ckNorm(sample);
  // 截断必须按 Unicode 码点（Python 的 str 下标就是码点），
  // 用 UTF-16 下标会在含 emoji 的书上截出半个代理对，两端样本从此不同。
  final runes = sampleN.runes;
  final cut = runes.length > limit
      ? String.fromCharCodes(runes.take(limit))
      : sampleN;
  final raw = '$version|$titleN|$number|$cut';
  final bytes = utf8.encode(raw);
  return sha1.convert(bytes).toString().substring(0, 16);
}

/// 书名 + 章节数 + 全文正文 → 16 位指纹（ck2）。全文请传 [bookFullText] 的结果。
String computeContentKey(String title, int chapterCount, String fullText) =>
    _digest(ckVersion, title, chapterCount, fullText);

/// ck1 指纹：仅供匹配历史记录，不要用于新目录命名。
String computeLegacyKey(String title, int totalChars, String sampleText) =>
    _digest(ckVersionLegacy, title, totalChars, sampleText,
        limit: ckLegacySampleLimit);

/// 书籍全文正文：各段落 display 首尾相接，段落间补一个 '\n'（对齐 PC content）。
String bookFullText(Book book) {
  final b = StringBuffer();
  for (final c in book.chapters) {
    for (var i = 0; i < c.paragraphs.length; i++) {
      if (i > 0) b.write('\n');
      b.write(c.paragraphs[i].display);
    }
    if (c.paragraphs.isNotEmpty) b.write('\n');
  }
  return b.toString();
}
