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

  /// 在所属段落的 display 文本中的起止偏移（用于高亮定位）
  final int displayStart;
  final int displayEnd;

  const Sentence(
    this.display,
    this.tts, {
    this.displayStart = 0,
    this.displayEnd = 0,
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

  /// 全章 display 文本总长度（用于百分比）
  int get displayLength =>
      paragraphs.fold(0, (s, p) => s + p.display.length);

  const Chapter({required this.title, required this.paragraphs});
}

/// 书籍
class Book {
  final String id;
  final String title;
  final String filePath;
  final BookFormat format;
  final List<Chapter> chapters;
  final DateTime addedAt;

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
    this.parseOk = true,
    this.parseError,
  });

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

  /// 计算全局百分比：0~1，依据累计字符数
  double progressRatio(int chapterIdx, int paraIdx) {
    if (chapters.isEmpty) return 0;
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
