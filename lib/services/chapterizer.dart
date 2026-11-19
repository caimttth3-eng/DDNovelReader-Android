// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
/// 章节切分：移植 Windows 版 novelreader/chapterizer.py 的 split_chapters。
///
/// 为什么必须逐规则照搬而不是自己写一套更聪明的：两端共用音频缓存，
/// 缓存文件名是「章号 + 章内原文偏移」，章号来自分章结果。分章差一章，
/// 全书缓存全部错位，且不会报错——表现就是「另一端下好的缓存一个都不命中」。
/// 所以这里不做任何"优化"，只把 PC 的判断顺序原样复现：
///   1. 内层标题（正文中穿插的「第X章 章节名」）在编号连续且不少于行首标题数时优先；
///   2. 否则按行首标题（严格/分隔线/宽松）切；
///   3. 切出的章数 <= 15 但有大量候选标题（trxs.cc「1.标题」等格式）→ 按候选重切；
///   4. 已切出但存在大量"强编号"数字标题 → 合并两类标题重切；
///   5. 标题不足 2 个 → 返回 null（调用方走 fallbackSplit）。
library;

/// 中文数字/阿拉伯数字/全角数字
const String _numSrc = '[\u0030-\u0039\uFF10-\uFF19零〇○一二三四五六七八九十百千万两]+';
const String _unitSrc = '[章节回卷部集篇]';

/// 严格匹配：行首就是第N章 / Chapter N / 楔子等
///
/// 注意最后那个 `\{...\}`：PC 端这段正则写在普通 raw 字符串里却用了 `{{1,40}}`，
/// 实际语义是"字面大括号 + 1~40 个非分隔字符 + 字面大括号"，于是「番外二·xxx」
/// 这类无分隔直连标题 PC 认不出来（只有「番外：xxx」「番外 xxx」能认）。
/// 这里照抄该行为，否则两端会差出章节，缓存全错位。
final RegExp _headLine = RegExp(
  r'^\s{0,4}(?:'
  '第' + _numSrc + _unitSrc +
  r'(?:\s*[：:、.\-—].*|\s+.*|[^\s、；;]{1,40}|\s*)'
  r'|(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+[：:.\s]?.*'
  r'|(?:楔子|序章|序言|前言|引子|引言|尾声|后记|番外|终章|大结局|完结篇)'
  r'(?:\s*[：:、.\-—].*|\s+.*|\{[^\s、；;]{1,40}\}|\s*)'
  r')\s*$'
);

/// 宽松匹配：行尾是第N章（可能带书名前缀）；特殊章节名分支同上（同样照抄 PC）
final RegExp _tailChapter = RegExp(
  '(?:第' + _numSrc + _unitSrc +
  r'(?:\s*[：:、.\-—].*|\s+.*|[^\s、；;]{1,40}|\s*)'
  r'|(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+[：:.\s]?.*'
  r'|(?:楔子|序章|序言|前言|引子|引言|尾声|后记|番外|终章|大结局|完结篇)'
  r'(?:\s*[：:、.\-—].*|\s+.*|\{[^\s、；;]{1,40}\}|\s*)'
  r')\s*$'
);

/// 分隔线：连续破折号/等号/星号/波浪号（>=10）
final RegExp _sepLine = RegExp(r'^[\s\-=*~—–]{10,}$');

const List<String> _nonTitleMarkers = [
  'http', '来源', '作者', '简介', '目录', '更新', '下载', '更多', '推荐', '收藏', '点击',
];

const List<String> _specialHeads = [
  '楔子', '序章', '序言', '前言', '引子', '引言', '尾声', '后记', '番外', '终章', '大结局', '完结篇',
];

final RegExp _innerNumRe = RegExp('第(' + _numSrc + ')章');
final RegExp _innerNameRe = RegExp(
    r'(?=[ \t\u3000：:])[ \t\u3000]*[：:]?[ \t\u3000]*([^\s，。；…,.!;:]{2,30})');

final Map<String, int> _cnNum = {
  '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
  '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '百': 100, '千': 1000, '万': 10000,
};

/// 正文噪音：数字直连标题时要排除的量词/单位/等级词/年份/日期开头
const String _numDirectBad = '年月日点分秒岁时块万元角楼层位名个次级倍‰％初末旬阶转品星境重线环层辰以费';
const String _numHeadCn = r'[\u4e00-\u9fff]';

/// 外层残留：书名 第N章 + 分隔线
final RegExp _outerResid = RegExp(
    r'(?:^|\n)[^\n]{0,26}?第' + _numSrc +
    r'章[ \t\u3000]*\n[ \t\u3000]*[-=—~*·]{10,}[ \t\u3000]*(?:\n|$)');

/// 正文开头行首的「第N章 章节名」
final RegExp _inlineTitleFull = RegExp(
    r'^第(\d+)章[\s\u3000]*[：:]?[\s\u3000]*([^\n]{1,40}?)(?=\u3000{2,}|\s{2,}|\n|$)');

const String _stripSet = ' \t\u3000\r\n';

String _strip(String s) {
  var a = 0, b = s.length;
  while (a < b && _stripSet.contains(s[a])) {
    a++;
  }
  while (b > a && _stripSet.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

String _rstrip(String s, [String set = ' \t\u3000']) {
  var b = s.length;
  while (b > 0 && set.contains(s[b - 1])) {
    b--;
  }
  return s.substring(0, b);
}

/// '第N章' 里的 N → int（支持阿拉伯/中文/全角数字）
int _parseOrd(String seg) {
  final normalized = seg.replaceAllMapped(
      RegExp('[\uFF10-\uFF19]'),
      (m) => '${'\uFF10\uFF11\uFF12\uFF13\uFF14\uFF15\uFF16\uFF17\uFF18\uFF19'.indexOf(m[0]!)}');
  if (RegExp(r'^\d+$').hasMatch(normalized)) {
    return int.parse(normalized);
  }
  var total = 0, cur = 0;
  for (final ch in normalized.split('')) {
    if (ch == '零' || ch == '〇') continue;
    final v = _cnNum[ch];
    if (v == null) continue;
    if (v >= 10) {
      if (cur == 0) cur = 1;
      total += cur * v;
      cur = 0;
    } else {
      cur += v;
    }
  }
  return total + cur;
}

/// 从一行里提取标题（带书名前缀时从「第N章」开始截）
String _extractTitle(String line) {
  line = _strip(line);
  final m = RegExp('第' + _numSrc + _unitSrc).firstMatch(line);
  if (m != null && m.start > 0) return _strip(line.substring(m.start));
  final m2 = RegExp(r'(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+').firstMatch(line);
  if (m2 != null && m2.start > 0) return _strip(line.substring(m2.start));
  for (final kw in _specialHeads) {
    final idx = line.indexOf(kw);
    if (idx > 0) return _strip(line.substring(idx));
  }
  return line;
}

/// 一行是否"看起来像"章节标题（分隔线匹配的二次过滤）
bool _looksLikeTitle(String line) {
  if (line.length > 60) return false;
  final low = line.toLowerCase();
  for (final marker in _nonTitleMarkers) {
    if (low.contains(marker)) return false;
  }
  if (RegExp('第' + _numSrc + _unitSrc).hasMatch(line)) return true;
  if (RegExp(r'(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+').hasMatch(line)) return true;
  for (final kw in _specialHeads) {
    if (line.contains(kw)) return true;
  }
  if (line.length <= 15 &&
      RegExp(r'^[0-9\uFF10-\uFF19]+[\s、.\-—]').hasMatch(line)) {
    return true;
  }
  return false;
}

/// 检测所有章节标题行 → [(行号, 标题)]
List<(int, String)> _detectHeads(List<String> lines) {
  final heads = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final line = _strip(lines[i].replaceAll('\r', ''));
    if (line.isEmpty || line.length > 200) continue;
    var isHead = false;
    if (_headLine.hasMatch(line)) {
      isHead = true;
    } else if (i + 1 < lines.length) {
      final next = _strip(lines[i + 1]);
      if (_sepLine.hasMatch(next) && _looksLikeTitle(line)) {
        isHead = true;
      }
    }
    if (!isHead && line.length <= 80 && _tailChapter.hasMatch(line)) {
      final m = RegExp('第' + _numSrc + _unitSrc).firstMatch(line);
      if (m != null) {
        final prefixRaw = line.substring(0, m.start);
        final prefix = _rstrip(prefixRaw, ' \t\u3000');
        final hasSep = prefixRaw != prefix;
        if (prefix.isEmpty ||
            hasSep ||
            '!！?？》]】)）.。、,，'.contains(prefix[prefix.length - 1])) {
          isHead = true;
        }
      }
    }
    if (isHead) heads.add((i, _extractTitle(line)));
  }
  return heads;
}

class _InnerHead {
  final int off;
  final String title;
  final int? num;
  _InnerHead(this.off, this.title, this.num);
}

/// 正文中穿插的「第X章 章节名」（内层真章节）
List<_InnerHead> _detectInnerHeads(List<String> lines) {
  final offsets = <int>[];
  var off = 0;
  for (var i = 0; i < lines.length; i++) {
    offsets.add(off);
    off += lines[i].length + 1;
  }
  final heads = <_InnerHead>[];
  const preOk = '。！？；…”’!?;】》〕）.!?;:：';
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].replaceAll('\r', '');
    for (final m in _innerNumRe.allMatches(line)) {
      final pre = line.substring(0, m.start);
      if (pre.isNotEmpty && !preOk.contains(pre[pre.length - 1])) continue;
      final after = line.substring(m.end);
      final m2 = _innerNameRe.firstMatch(after);
      if (m2 == null) continue;
      final name = m2.group(1)!;
      if (name.length > 30) continue;
      final title = '第${m.group(1)}章 $name';
      heads.add(_InnerHead(offsets[i] + m.start, title, _parseOrd(m.group(1)!)));
    }
  }
  return heads;
}

/// 内层标题是否可信（支持分卷编号重置）
bool _innerContinuous(List<_InnerHead> heads) {
  final nums = heads.where((h) => h.num != null && h.num! > 0).map((h) => h.num!).toList();
  if (nums.length < 2) return false;
  if (nums.length < 0.5 * heads.length) return false;
  if (nums.length >= 30) return true;
  final hi = nums.reduce((a, b) => a > b ? a : b);
  if (nums.toSet().length / nums.length < 0.85) return false;
  return (hi - nums.length).abs() / (hi > 1 ? hi : 1) <= 0.15;
}

String _stripOuterResid(String body) => body.replaceAll(_outerResid, '');

/// 识别正文开头行首的「第N章 章节名」并与标题合并
(String, String) _absorbInlineTitle(String title, String body) {
  final m = RegExp(r'^第(\d+)章').firstMatch(title);
  final num = m == null ? null : int.parse(m.group(1)!);
  final lines = body.split('\n');
  for (var i = 0; i < (lines.length < 2 ? lines.length : 2); i++) {
    final mm = _inlineTitleFull.firstMatch(lines[i]);
    if (mm == null) continue;
    final inum = int.parse(mm.group(1)!);
    final name = _strip(mm.group(2)!);
    final rest = _strip(lines[i].substring(mm.end));
    lines[i] = rest;
    if (num != null && inum == num && name.isNotEmpty) {
      title = '第$num章 $name';
    }
    break;
  }
  return (title, lines.join('\n').replaceAll(RegExp(r'^\n+|\n+$'), ''));
}

/// 按字符偏移切分（内层标题）
List<(String, String)> _splitByInner(String text, List<_InnerHead> heads) {
  heads.sort((a, b) => a.off.compareTo(b.off));
  final chapters = <(String, String)>[];
  final intro = _strip(_stripOuterResid(text.substring(0, heads[0].off)));
  if (intro.isNotEmpty) chapters.add(('简介', intro));
  for (var k = 0; k < heads.length; k++) {
    final start = heads[k].off + heads[k].title.length;
    final end = k + 1 < heads.length ? heads[k + 1].off : text.length;
    var body = _stripOuterResid(text.substring(start, end))
        .replaceAll(RegExp(r'^\n+|\n+$'), '');
    final (t, b) = _absorbInlineTitle(heads[k].title, body);
    body = b;
    if (_strip(body).isNotEmpty) chapters.add((t, body));
  }
  return chapters;
}

/// 数字编号标题：1.标题 / 0001：标题 / 1、标题 / 0001直连 / 一、标题 / 001 空格标题 / 卷名
bool _numHeadMatch(String line) {
  if (line.length < 6 || line.length > 45) return false;
  if (RegExp(r'^\d{1,4}[.．]\S').hasMatch(line)) return true;
  if (line.length <= 30 &&
      RegExp('^\\d{1,4}[:：]' + _numHeadCn).hasMatch(line)) return true;
  if (line.length <= 30 &&
      RegExp('^\\d{1,4}[、](?![甲乙丙丁])' + _numHeadCn).hasMatch(line)) return true;
  if (RegExp('^[一二三四五六七八九十]+[、](?![\\d一二三四五六七八九十百千])' + _numHeadCn)
      .hasMatch(line)) {
    return true;
  }
  if (line.length <= 20 &&
      RegExp('^\\d{1,4}(?![\\d' + _numDirectBad + '])' + _numHeadCn).hasMatch(line)) {
    return true;
  }
  if (line.length <= 45 &&
      RegExp('^\\d{1,4} (?![\\d' + _numDirectBad + '])' + _numHeadCn).hasMatch(line)) {
    return true;
  }
  if (RegExp(r'^[^【〔［\s].{1,13}[：:]\d{1,4}[.．]\S').hasMatch(line)) return true;
  return false;
}

/// 数字编号标题行（trxs.cc 等）
List<(int, String)> _detectNumHeads(List<String> lines) {
  final heads = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final line = _strip(lines[i]);
    if (line.isEmpty || line.length < 6 || line.length > 45) continue;
    final low = line.toLowerCase();
    if (_nonTitleMarkers.any((m) => low.contains(m))) continue;
    if (['点赞', '评论', '转发', '播放', '弹幕'].any((m) => low.contains(m))) continue;
    if (_numHeadMatch(line)) heads.add((i, line));
  }
  return heads;
}

const List<String> _candKw = [
  '楔子', '序章', '序言', '前言', '引子', '引言', '尾声', '后记', '番外', '终章', '大结局', '完结篇',
];

/// 粗筛"疑似章节标题"行（候选池）
List<(int, String)> collectCandidates(List<String> lines, {int maxLen = 60}) {
  final cands = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final line = _strip(lines[i]);
    if (line.isEmpty || line.length > maxLen) continue;
    final low = line.toLowerCase();
    if (_nonTitleMarkers.any((m) => low.contains(m))) continue;
    if (['点赞', '评论', '转发', '播放', '弹幕'].any((m) => low.contains(m))) continue;
    if (RegExp('第' + _numSrc + _unitSrc).hasMatch(line)) {
      cands.add((i, line));
    } else if (RegExp(r'(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+').hasMatch(line)) {
      cands.add((i, line));
    } else if (_candKw.any((k) => line.startsWith(k))) {
      cands.add((i, line));
    } else if (_numHeadMatch(line)) {
      cands.add((i, line));
    } else if (line.length >= 6 &&
        line.length <= 45 &&
        RegExp(r'^[^【〔［\s].{1,13}[：:]\d{1,4}[.．]\S').hasMatch(line)) {
      cands.add((i, line));
    } else if (line.length <= 60 &&
        !['“', '「', '『', '【', '〔', '［', '（'].any((p) => line.startsWith(p))) {
      final tm = RegExp('第' + _numSrc + _unitSrc +
              r'(?:\s*[：:、.\-—].*|\s+.*|[^\s。、；;]{1,40}|\s*)$')
          .firstMatch(line);
      if (tm != null && !line.contains('回合') && !line.contains('节课')) {
        cands.add((i, _extractTitle(line)));
      } else if (RegExp(
              r'^[^\s【〔［“「『].{1,15}[：:]\s*(?:楔子|序章|序言|前言|引子|引言|尾声|后记|番外|终章|大结局|完结篇)')
          .hasMatch(line)) {
        cands.add((i, line));
      }
    }
  }
  return cands;
}

/// 由标题行索引构建章节；标题不足时返回空列表
List<(String, String)> _chaptersFromHeads(List<String> lines, List<(int, String)> heads) {
  if (heads.length < 2) return [];
  final chapters = <(String, String)>[];
  final intro =
      _strip(lines.sublist(0, heads[0].$1).join('\n'));
  if (intro.isNotEmpty) chapters.add(('简介', intro));
  for (var k = 0; k < heads.length; k++) {
    var start = heads[k].$1 + 1;
    if (start < lines.length && _sepLine.hasMatch(_strip(lines[start]))) {
      start += 1;
    }
    final end = k + 1 < heads.length ? heads[k + 1].$1 : lines.length;
    var body = lines
        .sublist(start, end)
        .join('\n')
        .replaceAll(RegExp(r'^\n+|\n+$'), '');
    final (t, b) = _absorbInlineTitle(heads[k].$2, body);
    body = b;
    if (_strip(body).isNotEmpty) chapters.add((t, body));
  }
  return chapters;
}

/// 正文没有换行时按句末标点加换行（每行约 80 字；与 PC 一样只处理成对片段）
String _addLinebreaks(String text) {
  if (text.isEmpty || text.contains('\n')) return text;
  final parts = <String>[];
  var idx = 0;
  for (final m in RegExp(r'[。！？!?…；;]').allMatches(text)) {
    parts
      ..add(text.substring(idx, m.start))
      ..add(m[0]!);
    idx = m.end;
  }
  parts.add(text.substring(idx));
  // parts 形如 [seg0, seg1, seg2, ...]，每两段拼一句
  final lines = <String>[];
  var cur = '';
  for (var i = 0; i + 1 < parts.length; i += 2) {
    cur += parts[i] + parts[i + 1];
    if (cur.length >= 80) {
      lines.add(_strip(cur));
      cur = '';
    }
  }
  cur += parts.last;
  if (cur.isNotEmpty) lines.add(_strip(cur));
  return lines.join('\n');
}

/// 尝试按章节标题切分；无法可靠切分返回 null
List<(String, String)>? splitChapters(String text, {bool preserveLayout = false}) {
  final lines = text.split('\n');

  final inner = _detectInnerHeads(lines);
  final heads0 = _detectHeads(lines);
  if (_innerContinuous(inner) && inner.length >= heads0.length) {
    final chapters = _splitByInner(text, inner);
    if (chapters.length >= 2) {
      return [for (final c in chapters) (c.$1, preserveLayout ? c.$2 : _addLinebreaks(c.$2))];
    }
  }

  var heads = heads0;
  var chapters = _chaptersFromHeads(lines, heads);

  if (chapters.isEmpty || chapters.length <= 15) {
    final cands = collectCandidates(lines);
    final minCands = text.length ~/ 20000 < 20 ? 20 : text.length ~/ 20000;
    final maxCands = text.length ~/ 800;
    if (cands.length >= minCands &&
        cands.length <= maxCands &&
        cands.length > heads.length * 1.5) {
      final numChapters = _chaptersFromHeads(lines, cands);
      if (numChapters.length >= 2) chapters = numChapters;
    }
  } else {
    final numHeads = _detectNumHeads(lines);
    final strongNum = numHeads.where((h) =>
        RegExp(r'^\d{1,4}[.．]\S').hasMatch(h.$2) ||
        RegExp('^\\d{1,4}[:：]' + _numHeadCn).hasMatch(h.$2) ||
        RegExp('^\\d{1,4} ' + _numHeadCn).hasMatch(h.$2) ||
        RegExp(r'^[^【〔［\s].{1,13}[：:]\d{1,4}[.．]\S').hasMatch(h.$2)).toList();
    if (strongNum.length >= 20 && strongNum.length > heads.length * 1.5) {
      final merged = <(int, String)>[...strongNum, ...heads]
        ..sort((a, b) => a.$1.compareTo(b.$1));
      final mergedChapters = _chaptersFromHeads(lines, merged);
      if (mergedChapters.length > chapters.length) chapters = mergedChapters;
    }
  }

  if (chapters.length < 2) return null;

  // 目录密集 + 最后一个标题吞掉全部正文的病态格式 → 判不可靠
  if (chapters.length <= 3 && heads.length >= 3) {
    final bodies = [for (final c in chapters) c.$2.length];
    final total = bodies.fold(0, (a, b) => a + b);
    if (total > 0 && bodies.reduce((a, b) => a > b ? a : b) / total > 0.9) {
      final idxs = heads.map((h) => h.$1).toList()..sort();
      final gaps = [
        for (var i = 0; i < idxs.length - 1; i++) idxs[i + 1] - idxs[i]
      ]..sort();
      if (gaps[gaps.length ~/ 2] <= 5) return null;
    }
  }
  return [for (final c in chapters) (c.$1, preserveLayout ? c.$2 : _addLinebreaks(c.$2))];
}

/// 无标题书：按自然段落聚合成约 [paraTarget] 字一节
List<(String, String)> fallbackSplit(String text, {int paraTarget = 5000, bool preserveLayout = false}) {
  var paras = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => preserveLayout ? p.replaceAll(RegExp(r'^\n+|\n+$'), '').trimRight() : _strip(p))
      .where((p) => p.isNotEmpty)
      .toList();
  if (paras.isEmpty) {
    paras = text.split('\n').map(_strip).where((p) => p.isNotEmpty).toList();
  }
  final chapters = <(String, String)>[];
  final cur = <String>[];
  var curLen = 0;
  for (final p in paras) {
    final length = _strip(p).length;
    if (cur.isNotEmpty && curLen + length > paraTarget) {
      chapters.add(('第 ${chapters.length + 1} 节', cur.join('\n\n')));
      cur
        ..clear()
        ..add(p);
      curLen = length;
    } else {
      cur.add(p);
      curLen += length;
    }
  }
  if (cur.isNotEmpty) {
    chapters.add(('第 ${chapters.length + 1} 节', cur.join('\n\n')));
  }
  if (chapters.isEmpty) return [('正文', _strip(text))];
  return chapters;
}

/// 规范化正文：统一换行、折叠空行，段落间以单个换行分隔。
String normalizeBody(String text) {
  if (text.isEmpty) return '';
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // 网文常见的「全角空格分段」：段与段之间没有换行，只有两个全角空格。
  // 先还原成换行，再把剩余单个全角空格当作缩进（与 PC normalize_body 同序）。
  text = text.replaceAll('\u3000\u3000', '\n');
  text = text.replaceAll('\u3000', '  ');
  text = text.replaceAll('\ufeff', '');
  text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n'); // 行尾空格
  text = text.replaceAll(RegExp(r'\n{2,}'), '\n'); // 折叠空行
  text = _strip(text);
  if (text.contains('\n')) {
    final paras = text
        .split('\n')
        .map(_strip)
        .where((p) => p.isNotEmpty)
        .toList();
    return paras.join('\n');
  }
  final lines = text.split('\n').map(_rstrip).where((l) => _strip(l).isNotEmpty).toList();
  return lines.join('\n');
}

/// Original UTF16 boundaries to desktop-normalized Unicode scalar offsets.
/// Display keeps its physical lines/indentation; caches and sync share this map.
String canonicalChapterBody(String text, {required bool detectedHeading}) =>
  normalizeBody(detectedHeading ? _addLinebreaks(text) : text);

List<int> canonicalSourceOffsets(String original, {String? normalizedText}) {
  final normalized = normalizedText ?? normalizeBody(original);
  final whitespace = RegExp(r'\s');
  final positions = <int>[];
  var scalar = 0;
  for (final rune in normalized.runes) {
    if (!whitespace.hasMatch(String.fromCharCode(rune))) positions.add(scalar);
    scalar++;
  }
  final result = List<int>.filled(original.length + 1, scalar);
  var anchor = 0, raw = 0, gap = 0;
  for (final rune in original.runes) {
    final white = whitespace.hasMatch(String.fromCharCode(rune));
    final next = anchor < positions.length ? positions[anchor] : scalar;
    final previous = anchor == 0 ? 0 : positions[anchor - 1] + 1;
    final at = white ? (previous + gap).clamp(0, next) : next;
    final width = rune > 0xffff ? 2 : 1;
    for (var i = 0; i < width; i++) { result[raw++] = at; }
    if (white) { gap++; } else { anchor++; gap = 0; }
  }
  return result;
}

/// 分章诊断（对拍/排障用）：行首标题的「行号:标题」列表
List<String> debugHeadTitles(String text) {
  final lines = text.split('\n');
  return [for (final h in _detectHeads(lines)) '${h.$1}:${h.$2}'];
}

/// 分章诊断（对拍/排障用）：返回各分支的标题计数，便于定位两端分歧
Map<String, int> splitStats(String text) {
  final lines = text.split('\n');
  final inner = _detectInnerHeads(lines);
  final heads0 = _detectHeads(lines);
  return {
    'inner': inner.length,
    'heads0': heads0.length,
    'innerContinuous': _innerContinuous(inner) ? 1 : 0,
    'candidates': collectCandidates(lines).length,
    'numHeads': _detectNumHeads(lines).length,
  };
}

/// 生成章节列表（先尝试标题切分，失败则按段落分节），正文已规范化
List<(String, String)> makeChapters(String text) {
  final spl = splitChapters(text);
  final list = spl ?? fallbackSplit(text);
  return list.map((c) => (c.$1, normalizeBody(c.$2))).toList();
}

// ---------- 目录标题识别（PR2 引入，不改变既有分章结果） ----------
class DetectedChapterTitle {
  final String title;
  final int offset;
  const DetectedChapterTitle(this.title, this.offset);
}

/// Conservative line rules inspired by Legado's TXT TOC families. Ambiguous
/// numbered lists require multiple ascending entries separated by body text.
/// The legacy makeChapters pipeline stays unchanged for saved coordinates.
List<DetectedChapterTitle> detectChapterTitles(String text) {
  const numbers = r'0-9０-９零〇○一二三四五六七八九十百千万两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟';
  final chinese = RegExp('^第[ \\t　]{0,4}[$numbers]{1,12}[ \\t　]{0,4}(?:章|章節|章节|節(?!課)|节(?!课)|卷|集(?![合和])|部(?![分赛賽游])|篇(?!张)|回(?![合来來事去])|話|话)');
  final volume = RegExp('^[卷章][$numbers]{1,12}');
  final english = RegExp(r'^(?:chapter|section|part|episode)\s*(?:\d{1,5}|[IVXLCDM]{1,12})(?=$|[\s:：.\-—])', caseSensitive: false);
  final special = RegExp(r'^(?:楔子|序章|序言|前言|引子|引言|尾声|尾聲|后记|後記|番外|终章|終章|大结局|大結局|完结篇|完結篇)(?=$|[\s:：、\-—])');
  final numeric = RegExp(r'^(\d{1,5})[ \t　]*[、:：.．\-—_ ][ \t　]*\S.{0,29}$');
  final plainChinese = RegExp('^[$numbers]{1,8}[、:：．. ][ \\t　]*\\S.{0,29}\$');
  final result = <DetectedChapterTitle>[];
  final numbered = <(DetectedChapterTitle, int, int)>[];
  var lineIndex = 0;
  for (final line in RegExp(r'[^\r\n]+').allMatches(text)) {
    final original = line.group(0)!;
    final trimmed = original.trim();
    final offset = line.start + original.length - original.trimLeft().length;
    var title = trimmed.replaceFirst(RegExp(r'^\uFEFF'), '');
    if (title.startsWith('【') && title.endsWith('】')) title = title.substring(1, title.length - 1).trim();
    if (title.isEmpty || title.length > 60 || RegExp(r'https?://|www\.|[。；;“”]|\.{3,}|…{2,}', caseSensitive: false).hasMatch(title)) { lineIndex++; continue; }
    final head = chinese.firstMatch(title) ?? volume.firstMatch(title) ?? english.firstMatch(title) ?? special.firstMatch(title);
    if (head != null) {
      final suffix = title.substring(head.end);
      if (!RegExp(r'^(?:的|是|中|里|裡|讲述|講述|已经|已經|之后|之後|之前|的时候|的時候|结束了|結束了)').hasMatch(suffix)) {
        result.add(DetectedChapterTitle(title, offset));
      }
    } else {
      final match = numeric.firstMatch(title);
      if (match != null) numbered.add((DetectedChapterTitle(title, offset), int.parse(match.group(1)!), lineIndex));
      else if (plainChinese.hasMatch(title)) numbered.add((DetectedChapterTitle(title, offset), -1, lineIndex));
    }
    lineIndex++;
  }
  for (var i = 0; i < numbered.length; i++) {
    bool supports(int j) => j >= 0 && j < numbered.length &&
      (numbered[i].$3 - numbered[j].$3).abs() > 1 &&
      ((numbered[i].$2 == -1 && numbered[j].$2 == -1) ||
       (numbered[i].$2 >= 0 && numbered[j].$2 >= 0 &&
        (i < j ? numbered[i].$2 < numbered[j].$2 : numbered[i].$2 > numbered[j].$2)));
    if (supports(i - 1) || supports(i + 1)) result.add(numbered[i].$1);
  }
  result.sort((a, b) => a.offset.compareTo(b.offset));
  return result;
}
