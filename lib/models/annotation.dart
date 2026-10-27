/// 书签：定位到 (chapter, paragraph, sentence)
class Bookmark {
  final String id;
  final String bookId;
  final int chapterIndex;
  final int paragraphIndex;
  final int sentenceIndex;
  final String chapterTitle; // 冗余，列表直接显示
  final String snippet; // 句子预览
  final DateTime createdAt;

  const Bookmark({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.sentenceIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'sentenceIndex': sentenceIndex,
        'chapterTitle': chapterTitle,
        'snippet': snippet,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        paragraphIndex: json['paragraphIndex'] as int? ?? 0,
        sentenceIndex: json['sentenceIndex'] as int? ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 划线：段内 display 字符区间（与 BookProgress.offsetInParagraph 同坐标系）
class Highlight {
  final String id;
  final String bookId;
  final int chapterIndex;
  final int paragraphIndex;
  final int charStart; // 段内 display 字符偏移（含）
  final int charEnd; // 段内 display 字符偏移（不含）
  final int color; // ARGB
  final String note;
  final DateTime createdAt;

  const Highlight({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.charStart,
    required this.charEnd,
    required this.color,
    required this.note,
    required this.createdAt,
  });

  /// 是否命中 (chapter, paragraph) 下的某个句子区间
  bool hits(int chapter, int para, int sStart, int sEnd) =>
      chapterIndex == chapter &&
      paragraphIndex == para &&
      charEnd > sStart &&
      charStart < sEnd;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'charStart': charStart,
        'charEnd': charEnd,
        'color': color,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Highlight.fromJson(Map<String, dynamic> json) => Highlight(
        id: json['id'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        paragraphIndex: json['paragraphIndex'] as int? ?? 0,
        charStart: json['charStart'] as int? ?? 0,
        charEnd: json['charEnd'] as int? ?? 0,
        color: json['color'] as int? ?? 0x3385B5FF,
        note: json['note'] as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );

  Highlight copyWith({String? note, int? color}) => Highlight(
        id: id,
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: paragraphIndex,
        charStart: charStart,
        charEnd: charEnd,
        color: color ?? this.color,
        note: note ?? this.note,
        createdAt: createdAt,
      );
}
