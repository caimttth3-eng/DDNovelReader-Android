/// 章节切分：把整本小说的纯文本按章节标题切分为章节列表。
/// 移植自 Windows 版 chapterizer.py 的三重检测逻辑。
library;

/// A heading index over the unchanged source, not a request to split its text.
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

final RegExp _numRe = RegExp(r'[0-9０-９零〇○一二三四五六七八九十百千万两]+');
final String _unit = '[章节回卷部集篇]';

// 严格匹配：行首就是第N章 / Chapter N / 楔子等
final RegExp _headLine = RegExp(
  r'^\s{0,4}(?:'
  r'第' +
      _numRe.pattern +
      r'[章节回卷部集篇](?:\s*[：:、.\-—]?.*)?'
          r'|(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+[：:.\s]?.*'
          r'|(?:楔子|序章|序言|前言|引子|引言|尾声|后记|番外|终章|大结局|完结篇)(?:[ \t　]*[^。！？!?；;\n]{0,24})?'
          r')\s*$',
);

// 宽松匹配：行尾是第N章（可能带书名前缀），用于匹配"书名 第1章"格式

// 分隔线：连续的破折号/等号/星号/波浪号（>=10个）
final RegExp _sepLine = RegExp(r'^[\s\-=*~—–]{10,}$');

// 非标题标记
const List<String> _nonTitleMarkers = [
  'http', '来源', '作者', '简介', '目录', '更新', '下载', '更多', '推荐', '收藏', '点击',
];

final List<String> _specialKws = [
  '楔子', '序章', '序言', '前言', '引子', '引言', '尾声', '后记', '番外', '终章', '大结局', '完结篇',
];

bool _looksLikeTitle(String line) {
  if (line.length > 60) return false;
  final low = line.toLowerCase();
  for (final m in _nonTitleMarkers) {
    if (low.contains(m)) return false;
  }
  if (RegExp(r'第' + _numRe.pattern + _unit).hasMatch(line)) return true;
  if (RegExp(r'(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+').hasMatch(line)) {
    return true;
  }
  for (final kw in _specialKws) {
    if (line.contains(kw)) return true;
  }
  // 纯短标题（< 20字，不以句末标点结尾）：可能是"001 初入江湖"或"初入江湖"格式
  if (line.length <= 20 &&
      !RegExp(r'[。！？!?；;…]$').hasMatch(line) &&
      !RegExp(r'[，,、：:]').hasMatch(line)) {
    return true;
  }
  return false;
}

String _extractTitle(String line) {
  line = line.trim();
  // 尝试从"第N章"位置开始截取
  final m = RegExp(r'第' + _numRe.pattern + _unit).firstMatch(line);
  if (m != null) {
    // 行首就是章节号：整行作为标题（如"第三十三章 大结局"）
    if (m.start == 0) return line;
    // 带书名前缀："凡人修仙传 第1章 xxx" → 从章节号开始
    return line.substring(m.start).trim();
  }
  // 尝试从 Chapter 开始截取
  final m2 = RegExp(r'(?:[Cc]hapter|CHAPTER)\s+[0-9IVXLCivxl]+').firstMatch(line);
  if (m2 != null) {
    if (m2.start == 0) return line;
    return line.substring(m2.start).trim();
  }
  // 尝试从特殊章节名开始截取
  for (final kw in _specialKws) {
    final idx = line.indexOf(kw);
    if (idx == 0) return line; // 行首就是特殊章节词：整行作为标题（如"序章 引子"）
    if (idx > 0) return line.substring(idx).trim();
  }
  return line;
}

/// 检测所有章节标题行，返回 [(line_index, title)]。
List<(int, String)> _detectHeads(List<String> lines) {
  final heads = <(int, String)>[];
  final seen = <int>{};

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.length > 200) continue;
    if (seen.contains(i)) continue;

    var isHead = false;

    // 方式1：严格匹配（行首就是第N章）
    if (_headLine.hasMatch(line)) {
      isHead = true;
    }
    // 方式2：下一行是分隔线，且当前行看起来像标题
    else if (i + 1 < lines.length) {
      final nextLine = lines[i + 1].trim();
      if (_sepLine.hasMatch(nextLine) && _looksLikeTitle(line)) {
        isHead = true;
      }
    }
    // 方式3：宽松匹配（行尾是第N章，带书名前缀）
    if (!isHead && line.length <= 80) {
      final m = RegExp(r'第' + _numRe.pattern + _unit).firstMatch(line);
      if (m != null) {
        final prefixRaw = line.substring(0, m.start);
        final prefix = prefixRaw.trimRight();
        final hasSep = prefixRaw.length != prefix.length;
        if (prefix.isEmpty ||
            hasSep ||
            (prefix.isNotEmpty &&
                '!！?？》]】)）.。、,，'.contains(prefix[prefix.length - 1]))) {
          isHead = true;
        }
      }
    }

    if (isHead) {
      seen.add(i);
      heads.add((i, _extractTitle(line)));
    }
  }
  return heads;
}

/// 尝试按章节标题切分。成功返回 [(title, content), ...]；无法可靠切分返回 null。
List<(String, String)>? splitChapters(String text) {
  final lines = text.split('\n');
  final heads = _detectHeads(lines);

  // 至少 2 个标题才认为是已带章节的文本
  if (heads.length < 2) return null;

  final chapters = <(String, String)>[];
  // 第一章标题之前的文字归入"简介"章
  final intro =
      lines.sublist(0, heads[0].$1).join('\n').trimRight();
  if (intro.isNotEmpty) {
    chapters.add(('简介', intro));
  }

  for (var k = 0; k < heads.length; k++) {
    var start = heads[k].$1 + 1;
    // 跳过标题下方的分隔线
    if (start < lines.length && _sepLine.hasMatch(lines[start].trim())) {
      start++;
    }
    final end = (k + 1 < heads.length) ? heads[k + 1].$1 : lines.length;
    final body = lines.sublist(start, end).join('\n').trimRight();
    if (body.isNotEmpty) {
      chapters.add((heads[k].$2, body));
    }
  }

  if (chapters.length < 2) return null;
  return chapters;
}

/// 文本没有章节标题时，按自然段落聚合成小节（约 5000 字一段）。
List<(String, String)> fallbackSplit(String text, {int paraTarget = 5000}) {
  var paras = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trimRight())
      .where((p) => p.isNotEmpty)
      .toList();
  if (paras.length <= 1) {
    // 没有空行分隔段落时，退化为按每行聚合
    paras = text
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
  }
  final chapters = <(String, String)>[];
  final cur = <String>[];
  var curLen = 0;
  for (final p in paras) {
    if (cur.isNotEmpty && curLen + p.length > paraTarget) {
      chapters.add(('第 ${chapters.length + 1} 节', cur.join('\n\n')));
      cur.clear();
      cur.add(p);
      curLen = p.length;
    } else {
      cur.add(p);
      curLen += p.length;
    }
  }
  if (cur.isNotEmpty) {
    chapters.add(('第 ${chapters.length + 1} 节', cur.join('\n\n')));
  }
  // 兜底：若仍只有 1 章且文本超过 1.5 倍目标，按字符硬切（针对无换行的超长单段）
  if (chapters.length == 1 && text.length > paraTarget * 1.5) {
    final single = text.trim();
    final hard = <(String, String)>[];
    var i = 0;
    var idx = 1;
    while (i < single.length) {
      final end = i + paraTarget > single.length ? single.length : i + paraTarget;
      hard.add(('第 $idx 节', single.substring(i, end)));
      i = end;
      idx++;
    }
    return hard;
  }
  if (chapters.isEmpty) {
    return [('正文', text.trim())];
  }
  return chapters;
}

/// 规范化正文：统一换行、折叠空行，段落间以单个换行分隔。
String normalizeBody(String text) {
  if (text.isEmpty) return '';
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll('\ufeff', '');
  final lines = text.split('\n').map((line) => line.trimRight()).toList();
  while (lines.isNotEmpty && lines.first.trim().isEmpty) { lines.removeAt(0); }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) { lines.removeLast(); }
  return lines.join('\n');
}

/// 生成章节列表（先尝试标题切分，失败则按段落分节）。
List<(String, String)> makeChapters(String text) {
  final spl = splitChapters(text);
  if (spl != null) {
    return spl.map((c) => (c.$1, normalizeBody(c.$2))).toList();
  }
  final fb = fallbackSplit(text);
  return fb.map((c) => (c.$1, normalizeBody(c.$2))).toList();
}
