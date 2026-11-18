/// 小说 txt 多编码解码：与 PC 端 novelreader/book_loader.py 的 `_decode` 逐条对齐
/// （BOM 优先、UTF-8/GB18030/Big5 质量打分选优、0.6 阈值、最后宽松 UTF-8 兜底）。
///
/// 为什么必须对齐：整本朗读缓存的一级目录键 content_key = 书名 + 章数 + 正文指纹，
/// 两端解码出的文本只要差一个字，key 就不同、缓存全部 miss。GBK 字节流常常
/// "碰巧"是合法 UTF-8（解出来全是乱码拉丁字符），所以不能只靠 try/except，
/// 必须按解码结果的 CJK 占比打分择优 —— 与 PC 完全同一套打分。
///
/// 已知边界：GB18030 四字节序列（CJK 扩展区生僻字）这里输出 U+FFFD，
/// PC 用 gb18030 codec 会解出真字符；中文网文正文几乎不含此类字符。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'enc_tables.dart';
import 'gb4_table.dart';

const int _bomUtf8 = 0xEF;
const int _bomUtf8b1 = 0xBB;
const int _bomUtf8b2 = 0xBF;

/// 解码质量打分（与 PC _text_quality 同一公式）。
double _textQuality(String s) {
  if (s.isEmpty) return -1.0;
  final total = s.length;
  var cjk = 0;
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) cjk++;
  }
  var repl = 0;
  var ctrl = 0;
  for (final r in s.runes) {
    if (r == 0xFFFD) {
      repl++;
    } else if (_isCc(r)) {
      ctrl++;
    }
  }
  return cjk / total * 2.0 - repl / total * 5.0 - ctrl / total * 3.0;
}

/// Unicode 类别 Cc（控制字符），排除 \n \r \t（PC 同样排除）
bool _isCc(int r) {
  if (r == 0x0A || r == 0x0D || r == 0x09) return false;
  return r <= 0x1F || (r >= 0x7F && r <= 0x9F);
}

/// GB18030 双字节查表（trail 0x40..0x7E 与 0x80..0xFE 两段连续排布）
int _gbkLookup(int lead, int trail) {
  if (lead < 0x81 || lead > 0xFE) return 0;
  int col;
  if (trail >= 0x40 && trail <= 0x7E) {
    col = trail - 0x40;
  } else if (trail >= 0x80 && trail <= 0xFE) {
    col = 63 + (trail - 0x80);
  } else {
    return 0;
  }
  if (col >= kGbkCols) return 0;
  final idx = (lead - 0x81) * kGbkCols + col;
  final hex = kGbkTable.substring(idx * 4, idx * 4 + 4);
  if (hex == '0000') return 0;
  return int.parse(hex, radix: 16);
}

/// Big5 双字节查表（trail 0x40..0x7E 与 0xA1..0xFE 两段）
int _big5Lookup(int lead, int trail) {
  if (lead < 0x81 || lead > 0xFE) return 0;
  int col;
  if (trail >= 0x40 && trail <= 0x7E) {
    col = trail - 0x40;
  } else if (trail >= 0xA1 && trail <= 0xFE) {
    col = 63 + (trail - 0xA1);
  } else {
    return 0;
  }
  if (col >= kBig5Cols) return 0;
  final idx = (lead - 0x81) * kBig5Cols + col;
  final hex = kBig5Table.substring(idx * 4, idx * 4 + 4);
  if (hex == '0000') return 0;
  return int.parse(hex, radix: 16);
}

String _decodeDbc(List<int> bytes, {required bool gbk}) {
  final sb = StringBuffer();
  final n = bytes.length;
  var i = 0;
  while (i < n) {
    final b0 = bytes[i];
    if (b0 < 0x80) {
      sb.writeCharCode(b0);
      i++;
      continue;
    }
    // GB18030 四字节序列：lead 0x81-0xFE + 0x30-0x39 + 0x81-0xFE + 0x30-0x39
    if (gbk &&
        i + 3 < n &&
        b0 >= 0x81 &&
        b0 <= 0xFE &&
        bytes[i + 1] >= 0x30 &&
        bytes[i + 1] <= 0x39 &&
        bytes[i + 2] >= 0x81 &&
        bytes[i + 2] <= 0xFE &&
        bytes[i + 3] >= 0x30 &&
        bytes[i + 3] <= 0x39) {
      final idx = ((b0 - 0x81) * 10 + (bytes[i + 1] - 0x30)) * 1260 +
          (bytes[i + 2] - 0x81) * 10 +
          (bytes[i + 3] - 0x30);
      final cp = gb4CodePoint(idx);
      sb.writeCharCode(cp >= 0 ? cp : 0xFFFD);
      i += 4;
      continue;
    }
    if (i + 1 < n) {
      final cp = gbk
          ? _gbkLookup(b0, bytes[i + 1])
          : _big5Lookup(b0, bytes[i + 1]);
      if (cp != 0) {
        sb.writeCharCode(cp);
        i += 2;
        continue;
      }
    }
    sb.writeCharCode(0xFFFD);
    i++;
  }
  return sb.toString();
}

/// 把 txt 字节流解码为字符串（PC `_decode` 的等价实现）。
String decodeTextBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == _bomUtf8 &&
      bytes[1] == _bomUtf8b1 &&
      bytes[2] == _bomUtf8b2) {
    return const Utf8Decoder(allowMalformed: true)
        .convert(Uint8List.fromList(bytes.sublist(3)));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), Endian.big);
  }

  String? best;
  var bestScore = -1e9;
  // 候选顺序与 PC 一致：utf-8 → gb18030 → big5
  try {
    final s = const Utf8Decoder(allowMalformed: false).convert(
        Uint8List.fromList(bytes));
    final sc = _textQuality(s);
    if (sc > bestScore) {
      bestScore = sc;
      best = s;
    }
  } catch (_) {}
  for (final gbk in [true, false]) {
    final s = _decodeDbc(bytes, gbk: gbk);
    final sc = _textQuality(s);
    if (sc > bestScore) {
      bestScore = sc;
      best = s;
    }
  }
  if (best != null && bestScore >= 0.6) return best;
  return const Utf8Decoder(allowMalformed: true)
      .convert(Uint8List.fromList(bytes));
}

String _decodeUtf16(List<int> bytes, Endian endian) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(endian == Endian.little
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}
