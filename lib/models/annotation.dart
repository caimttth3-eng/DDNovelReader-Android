/// 书签：定位到 (chapter, paragraph, sentence)
class Bookmark {
  final String id;
  final String bookId;
  final int chapterIndex;
  final int paragraphIndex;
  final int sentenceIndex;
  final int? chapterAnchor;
  final String chapterTitle; // 冗余，列表直接显示
  final String snippet; // 句子预览
  final DateTime createdAt;

  /// 章内 display 字符偏移（PC 端 `offset` 口径），跨端同步时给 PC 定位用。
  final int charOffset;

  /// 章内 display 字符偏移结束（PC 端 `offset_end`）
  final int charOffsetEnd;

  const Bookmark({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.sentenceIndex,
    this.chapterAnchor,
    required this.chapterTitle,
    required this.snippet,
    required this.createdAt,
    this.charOffset = 0,
    this.charOffsetEnd = 0,
  });

  /// 安卓自有字段 + PC 兼容字段一起写，PC 端能直接读这条记录。
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'bookmark',
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'sentenceIndex': sentenceIndex,
        'chapterAnchor': chapterAnchor,
        'chapterTitle': chapterTitle,
        'snippet': snippet,
        'createdAt': createdAt.toIso8601String(),
        'charOffset': charOffset,
        'charOffsetEnd': charOffsetEnd,
        // ---- PC 端字段（novelreader/bookmark_ui.py）----
        'chapter_idx': chapterIndex,
        'offset': charOffset,
        'offset_end': charOffsetEnd,
        'text': snippet,
        'note': snippet,
        'created_at': createdAt.millisecondsSinceEpoch / 1000.0,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: (json['id'] ?? '').toString(),
        bookId: json['bookId'] as String? ?? '',
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ??
            (json['chapter_idx'] as num?)?.toInt() ??
            0,
        paragraphIndex: (json['paragraphIndex'] as num?)?.toInt() ?? 0,
        sentenceIndex: (json['sentenceIndex'] as num?)?.toInt() ?? 0,
        chapterAnchor: (json['chapterAnchor'] as num?)?.toInt(),
        chapterTitle: json['chapterTitle'] as String? ?? '',
        snippet: json['snippet'] as String? ??
            json['text'] as String? ??
            json['note'] as String? ??
            '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            _secondsToDate(json['created_at']) ??
            DateTime.now(),
        charOffset: (json['charOffset'] as num?)?.toInt() ??
            (json['offset'] as num?)?.toInt() ??
            0,
        charOffsetEnd: (json['charOffsetEnd'] as num?)?.toInt() ??
            (json['offset_end'] as num?)?.toInt() ??
            0,
      );

  static DateTime? _secondsToDate(Object? v) {
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round());
    }
    return null;
  }
}

/// 划线：段内 display 字符区间（与 BookProgress.offsetInParagraph 同坐标系）
class Highlight {
  final String id;
  final String bookId;
  final int chapterIndex;
  final int paragraphIndex;
  final int charStart; // 段内 display 字符偏移（含）
  final int charEnd; // 段内 display 字符偏移（不含）
  final int? anchorStart;
  final int? anchorEnd;
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
    this.anchorStart,
    this.anchorEnd,
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
        'type': 'highlight',
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'charStart': charStart,
        'charEnd': charEnd,
        'anchorStart': anchorStart,
        'anchorEnd': anchorEnd,
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
        anchorStart: json['anchorStart'] as int?,
        anchorEnd: json['anchorEnd'] as int?,
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
        anchorStart: anchorStart,
        anchorEnd: anchorEnd,
        color: color ?? this.color,
        note: note ?? this.note,
        createdAt: createdAt,
      );
}
