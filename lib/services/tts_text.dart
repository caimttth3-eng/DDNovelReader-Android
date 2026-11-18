/// TTS 朗读文本预处理 + 切句（逐字节对齐 PC 端 novelreader/textproc.py 与
/// tts_engine.split_sentences）。
///
/// 为什么必须逐字节对齐：音频缓存文件名是「章号 + 章内原文偏移」，且 mp3 与
/// 朗读文本一一对应。只要清洗规则或切句规则差一个字符，两端算出的偏移就不同，
/// 缓存全部 miss（且不报错）。所以这里不采用「更聪明」的自己的规则，
/// 而是把 PC 的规则原样搬过来：
///
///  1. 删除所有空白（不是压缩成空格）；
///  2. 删除 emoji / 颜文字 / 装饰符号；
///  3. 连续标点折叠为一个，优先保留「最后一个句子终止符」，否则保留第一个；
///  4. 按句末标点 。！？；!?; 切句，>160 字再按「，」「,」回退硬切。
library;

import 'dart:math';

import 'unicode_symbols.dart';

/// 清洗结果：纯净朗读文本 + 「纯净下标 → 原文 UTF-16 下标」映射
class TtsClean {
  final String clean;
  final List<int> cmap;

  const TtsClean(this.clean, this.cmap);
}

/// 需要删除的空白字符（与 PC _WS 同集合）
const Set<String> _kWs = {
  ' ', '\t', '\n', '\r', '\v', '\f', '\u3000', '\u00a0', '\u200b',
  '\u200c', '\u200d', '\u200e', '\u200f', '\u2060', '\ufeff',
};

/// 标点（TTS 停顿点）：保留单个，折叠连续多个（与 PC _PUNCT 同集合）
const Set<String> _kPunct = {
  '，', '。', '！', '？', '；', '：', '、', ',', '.', '!', '?', ';', ':',
  '…', '·', '—', '～', '~', '‘', '’', '“', '”', '"', "'",
  '(', ')', '（', '）', '[', ']', '【', '】', '{', '}', '《', '》', '〈', '〉',
};

/// 句子终止符：折叠时优先保留（与 PC _SENT_END 同集合）
const Set<String> _kSentEnd = {'。', '！', '？', '；', '!', '?', ';'};

/// 切句上限（与 PC _MAX_CHUNK 一致）
const int _maxChunk = 160;

/// emoji / 装饰符号（与 PC _is_emoji 同范围）
bool _isEmojiCp(int cp) {
  return (cp >= 0x1F000 && cp <= 0x1FAFF) ||
      (cp >= 0x2600 && cp <= 0x27BF) ||
      (cp >= 0x2190 && cp <= 0x21FF) ||
      (cp >= 0x2B00 && cp <= 0x2BFF) ||
      cp == 0xFE0F ||
      cp == 0xFE0E ||
      cp == 0x200D;
}

/// 颜文字 / 装饰符号：与 PC unicodedata 类别 Sk/So/Pc 完全一致
/// （区间表由 Python unicodedata 生成，见 unicode_symbols.dart）
bool _isDecorCp(int cp) => isDecorSymbolCp(cp);

/// 行尾连续装饰符号（与 PC _TAIL_DECOR_RE 一致）：如 -------------、====、***
final RegExp _tailDecorRe = RegExp(r'[=\-_~*#·—]{3,}\s*$');

/// 有朗读价值的最小字符集（与 PC _READABLE_RE 一致）
final RegExp _readableRe =
    RegExp(r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7afA-Za-z0-9]');

/// 过滤装饰行（与 PC _strip_decor_lines 同逻辑）：
/// 1) 截掉行尾连续装饰符号（保留行首正文）；
/// 2) 整行没有任何可读字符（如纯 `----------`）则整行丢弃。
///
/// 返回 (过滤文本, 过滤文本 UTF-16 下标 → 原文 UTF-16 下标)。
/// 这些行若不丢，会各自切出一句「------」送去合成，既浪费一次网络往返，
/// 又让两端句子数与偏移对不上。
(String, List<int>) _stripDecorLines(String content) {
  final out = StringBuffer();
  final idx = <int>[];
  final n = content.length;
  var pos = 0;
  while (pos < n) {
    final nl = content.indexOf('\n', pos);
    final end = nl < 0 ? n : nl;
    final line = content.substring(pos, end);
    final m = _tailDecorRe.firstMatch(line);
    final keepLen = m != null ? m.start : line.length;
    if (_readableRe.hasMatch(line.substring(0, keepLen))) {
      out.write(line.substring(0, keepLen));
      for (var k = pos; k < pos + keepLen; k++) {
        idx.add(k);
      }
    }
    pos = end + 1;
  }
  return (out.toString(), idx);
}

/// 把原文清洗为朗读文本，并返回「纯净下标 → 原文下标」映射。
///
/// 输入应是**整章**正文（段落用 '\n' 连接）；与 PC 端 ch.tts_content() 同口径。
TtsClean preprocessForTts(String content) {
  // 0. 行级过滤装饰行（PC _strip_decor_lines），保持与原文的下标映射
  final (filtered, base) = _stripDecorLines(content);

  // 先按 Unicode 码点拆字符，并记录每个字符在**原文**中的 UTF-16 起点
  final chars = <String>[];
  final u16 = <int>[];
  var i16 = 0;
  for (final r in filtered.runes) {
    final s = String.fromCharCode(r);
    chars.add(s);
    u16.add(i16 < base.length ? base[i16] : content.length);
    i16 += s.length;
  }

  final n = chars.length;
  final out = StringBuffer();
  final cmap = <int>[];
  var i = 0;
  while (i < n) {
    final ch = chars[i];
    final cp = ch.runes.first;
    // 1. 空白 → 删除（PC 是删除，不是压缩成空格）
    if (_kWs.contains(ch)) {
      i++;
      continue;
    }
    // 2. emoji / 颜文字 / 装饰符号 → 删除
    if (_isEmojiCp(cp) || _isDecorCp(cp)) {
      i++;
      continue;
    }
    // 3. 连续标点折叠为一个
    if (_kPunct.contains(ch)) {
      var j = i + 1;
      while (j < n) {
        final c2 = chars[j];
        final cp2 = c2.runes.first;
        if (_kPunct.contains(c2) ||
            _kWs.contains(c2) ||
            _isEmojiCp(cp2) ||
            _isDecorCp(cp2)) {
          j++;
        } else {
          break;
        }
      }
      // 优先保留最后一个句子终止符，否则保留第一个标点
      var keep = -1;
      for (var k = j - 1; k >= i; k--) {
        if (_kSentEnd.contains(chars[k])) {
          keep = k;
          break;
        }
      }
      if (keep < 0) keep = i;
      out.write(chars[keep]);
      cmap.add(u16[keep]);
      i = j;
      continue;
    }
    // 普通字符保留
    out.write(ch);
    cmap.add(u16[i]);
    i++;
  }
  return TtsClean(out.toString(), cmap);
}

/// 切句：返回 [(起始纯净下标, 结束纯净下标)) 列表，顺序即朗读顺序。
///
/// 与 PC split_sentences 一致：先按句末标点切（标点归前句），
/// 再对超长句按「，」→「,」→ 硬切 160 三级回退。纯净文本没有空白，
/// 因此 PC 的 strip / '\n' 二次切在这里天然不产生额外切点。
List<(int, int)> splitSentenceRanges(String clean) {
  final parts = <(int, int)>[];
  var start = 0;
  for (var i = 0; i < clean.length; i++) {
    if (_kSentEnd.contains(clean[i])) {
      parts.add((start, i + 1));
      start = i + 1;
    }
  }
  if (start < clean.length) parts.add((start, clean.length));

  final out = <(int, int)>[];
  for (final (s, e) in parts) {
    out.addAll(_hardSplit(clean, s, e));
  }
  return out;
}

/// 超长句硬切（与 PC _hard_split 同逻辑，含 80 字半程阈值）
List<(int, int)> _hardSplit(String s, int start, int end) {
  final out = <(int, int)>[];
  var a = start;
  while (end - a > _maxChunk) {
    final hi = a + _maxChunk - 1;
    var cut = s.lastIndexOf('，', hi);
    if (cut < a + _maxChunk ~/ 2) cut = s.lastIndexOf(',', hi);
    if (cut < a + _maxChunk ~/ 2) cut = a + _maxChunk;
    out.add((a, cut));
    a = cut;
  }
  out.add((a, end));
  return out;
}

/// UTF-16 下标 → 码点下标映射（长度 = s.length + 1）
///
/// PC 端偏移按 Unicode 码点计（Python 字符串下标），安卓字符串是 UTF-16；
/// 含 emoji 的书两者会差几个数，缓存文件名必须换成码点口径才能跨端一致。
List<int> utf16ToCodePointMap(String s) {
  final map = List<int>.filled(s.length + 1, 0);
  var cp = 0;
  var i = 0;
  while (i < s.length) {
    map[i] = cp;
    final c = s.codeUnitAt(i);
    final isHigh = c >= 0xD800 && c <= 0xDBFF;
    if (isHigh && i + 1 < s.length) {
      final c2 = s.codeUnitAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        map[i + 1] = cp;
        i += 2;
        cp += 1;
        continue;
      }
    }
    i += 1;
    cp += 1;
  }
  map[s.length] = cp;
  return map;
}

/// 码点长度（PC len() 的口径）
int codePointLength(String s) {
  var cp = 0;
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      final c2 = s.codeUnitAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        i += 2;
        cp++;
        continue;
      }
    }
    i++;
    cp++;
  }
  return max(cp, 0);
}

