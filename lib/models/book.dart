import '../services/chapterizer.dart' show canonicalSourceOffsets;

/// 支持的书籍格式
enum BookFormat { txt, epub, pdf, docx }

extension BookFormatX on BookFormat {
  String get label {
    switch (this) {
      case BookFormat.txt:
        return 'TXT';
      case BookFormat.epub:
        return 'EPUB';
      case BookFormat.pdf:
        return 'PDF';
      case BookFormat.docx:
        return 'DOCX';
    }
  }

  static BookFormat fromExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.epub':
        return BookFormat.epub;
      case '.pdf':
        return BookFormat.pdf;
      case '.docx':
        return BookFormat.docx;
      default:
        return BookFormat.txt;
    }
  }
}

/// 一个句子：display 为显示文本，tts 为朗读文本
class Sentence {
  final String display;
  final String tts;
  /// 只影响朗读节奏（句末追加静音），不改动音频内容
  final int pauseAfterMilliseconds;

  /// 在所属段落的 display 文本中的起止偏移（用于高亮定位）
  final int displayStart;
  final int displayEnd;

  const Sentence(
    this.display,
    this.tts, {
    this.displayStart = 0,
    this.displayEnd = 0,
    this.pauseAfterMilliseconds = 0,
  });
}

/// 一个段落：包含显示文本与 TTS 文本，并切分为句子
class Paragraph {
  final String display;
  final String tts;
  final List<Sentence> sentences;

  /// tts 文本中每个句子起始的偏移（按 tts 字符偏移）
  final List<int> sentenceStartTts;

  const Paragraph({
    required this.display,
    required this.tts,
    required this.sentences,
    required this.sentenceStartTts,
  });

  /// 根据 tts 字符位置定位当前句子的索引
  int sentenceIndexAtTts(int ttsPos) {
    if (ttsPos < 0) return 0;
    var idx = 0;
    for (var i = 0; i < sentenceStartTts.length; i++) {
      if (sentenceStartTts[i] <= ttsPos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// 章节
class Chapter {
  final String title;
  final List<Paragraph> paragraphs;
  final List<int>? _providedCoordinates;
  static final _coordinates = Expando<List<int>>();
  List<int> get sourceCoordinates => _providedCoordinates ?? (_coordinates[this] ??=
    canonicalSourceOffsets(paragraphs.map((p) => p.display).join('\n')));

  /// 全章 display 文本总长度（用于百分比）
  int get displayLength =>
      paragraphs.fold(0, (s, p) => s + p.display.length);

  const Chapter({required this.title, required this.paragraphs, List<int>? sourceCoordinates}) :
    _providedCoordinates = sourceCoordinates;
}

/// 书籍
class Book {
  final String id;
  final String title;
  final String filePath;
  final BookFormat format;
  final List<Chapter> chapters;
  final DateTime addedAt;

  /// 跨端稳定的内容指纹（与 PC 端 content_key 同一值）：
  /// 音频缓存目录一级键、WebDAV 同步键都用它，因此换设备也能命中同一批 mp3。
  final String contentKey;

  /// 是否解析完成（加载失败时显示但不可读）
  final bool parseOk;
  final String? parseError;

  int get totalDisplayLength =>
      chapters.fold(0, (s, c) => s + c.displayLength);

  int get chapterCount => chapters.length;

  const Book({
    required this.id,
    required this.title,
    required this.filePath,
    required this.format,
    required this.chapters,
    required this.addedAt,
    this.contentKey = '',
    this.parseOk = true,
    this.parseError,
  });

  /// 带上内容指纹的副本（解析完成后统一在 BookParser 里补上）
  Book withContentKey(String key) => Book(
        id: id,
        title: title,
        filePath: filePath,
        format: format,
        chapters: chapters,
        addedAt: addedAt,
        contentKey: key,
        parseOk: parseOk,
        parseError: parseError,
      );

  factory Book.failed({
    required String id,
    required String title,
    required String filePath,
    required BookFormat format,
    required DateTime addedAt,
    required String error,
  }) {
    return Book(
      id: id,
      title: title,
      filePath: filePath,
      format: format,
      chapters: const [],
      addedAt: addedAt,
      parseOk: false,
      parseError: error,
    );
  }

  /// 定位章节：返回 (chapterIndex, paragraphIndex)
  (int, int) locateProgress(int chapterIdx, int paraIdx) {
    var c = chapterIdx.clamp(0, chapters.length - 1);
    if (chapters.isEmpty) return (0, 0);
    var p = paraIdx.clamp(0, chapters[c].paragraphs.length - 1);
    return (c, p);
  }

  /// 按「章内 display 字符偏移」定位 (段落索引, 段内偏移)。
  ///
  /// 口径：与 PC 端 `char_offset` 对齐 —— PC 的章内偏移是在章正文（段间以
  /// 单个换行分隔）上数的，所以这里每跨一段补 +1 个换行字符。
  /// 段间为多空行的书会有 ≤ 段数的正向偏差，定位到相邻段，不影响续读。
  (int, int) locateByCharOffset(int chapterIdx, int charOffset) {
    if (chapters.isEmpty) return (0, 0);
    final c = chapterIdx.clamp(0, chapters.length - 1);
    final paras = chapters[c].paragraphs;
    if (paras.isEmpty) return (0, 0);
    final coordinates = chapters[c].sourceCoordinates;
    final target = charOffset.clamp(0, coordinates.last);
    var low = 0, high = coordinates.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (coordinates[middle] < target) { low = middle + 1; } else { high = middle; }
    }
    var remain = low;
    for (var i = 0; i < paras.length; i++) {
      final len = paras[i].display.length;
      if (remain <= len) return (i, remain);
      remain -= len + 1; // +1 = 段间换行
      if (remain < 0) remain = 0;
    }
    final last = paras.length - 1;
    return (last, paras[last].display.length);
  }

  /// 把 (段落, 段内偏移) 换成 PC 口径的章内字符偏移（用于推给 PC）。
  int charOffsetOf(int chapterIdx, int paragraphIndex, int offsetInParagraph) {
    if (chapters.isEmpty) return 0;
    final c = chapterIdx.clamp(0, chapters.length - 1);
    final paras = chapters[c].paragraphs;
    if (paras.isEmpty) return 0;
    final p = paragraphIndex.clamp(0, paras.length - 1);
    var sum = 0;
    for (var i = 0; i < p; i++) {
      sum += paras[i].display.length + 1; // +1 = 段间换行
    }
    final text = paras[p].display;
    var offset = offsetInParagraph.clamp(0, text.length);
    if (offset > 0 && offset < text.length && text.codeUnitAt(offset) >= 0xdc00 && text.codeUnitAt(offset) <= 0xdfff &&
        text.codeUnitAt(offset - 1) >= 0xd800 && text.codeUnitAt(offset - 1) <= 0xdbff) offset--;
    return chapters[c].sourceCoordinates[sum + offset];
  }

  /// 计算全局百分比：0~1，依据累计字符数
  double progressRatio(int chapterIdx, int paraIdx) {    if (chapters.isEmpty) return 0;
    var c = chapterIdx.clamp(0, chapters.length - 1);
    var p = paraIdx.clamp(0, chapters[c].paragraphs.length - 1);
    var before = 0;
    for (var i = 0; i < c; i++) {
      before += chapters[i].displayLength;
    }
    for (var i = 0; i < p; i++) {
      before += chapters[c].paragraphs[i].display.length;
    }
    final total = totalDisplayLength;
    if (total == 0) return 0;
    return (before / total).clamp(0.0, 1.0);
  }
}
