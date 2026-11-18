/// 每本书的阅读进度
class BookProgress {
  final String bookId;
  int chapterIndex;
  int paragraphIndex;

  /// 段落内偏移（按 display 字符），用于续读精确定位
  int offsetInParagraph;
  double percent;

  BookProgress({
    required this.bookId,
    this.chapterIndex = 0,
    this.paragraphIndex = 0,
    this.offsetInParagraph = 0,
    this.percent = 0,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'offsetInParagraph': offsetInParagraph,
        'percent': percent,
      };

  factory BookProgress.fromJson(Map<String, dynamic> json) => BookProgress(
        bookId: json['bookId'] as String? ?? '',
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        paragraphIndex: json['paragraphIndex'] as int? ?? 0,
        offsetInParagraph: json['offsetInParagraph'] as int? ?? 0,
        percent: (json['percent'] as num?)?.toDouble() ?? 0,
      );

  BookProgress copyWith({
    int? chapterIndex,
    int? paragraphIndex,
    int? offsetInParagraph,
    double? percent,
  }) =>
      BookProgress(
        bookId: bookId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        paragraphIndex: paragraphIndex ?? this.paragraphIndex,
        offsetInParagraph: offsetInParagraph ?? this.offsetInParagraph,
        percent: percent ?? this.percent,
      );
}

/// 书籍元信息（书架列表持久化用）
class BookMeta {
  final String id;
  final String title;
  final String filePath;
  final String format;
  final DateTime addedAt;
  final bool parseOk;
  final String? parseError;

  /// 跨端稳定的内容指纹（= 音频缓存目录一级键 = WebDAV 同步键）
  final String contentKey;

  const BookMeta({
    required this.id,
    required this.title,
    required this.filePath,
    required this.format,
    required this.addedAt,
    this.parseOk = true,
    this.parseError,
    this.contentKey = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'filePath': filePath,
        'format': format,
        'addedAt': addedAt.toIso8601String(),
        'parseOk': parseOk,
        'parseError': parseError,
        'contentKey': contentKey,
      };

  factory BookMeta.fromJson(Map<String, dynamic> json) => BookMeta(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        filePath: json['filePath'] as String? ?? '',
        format: json['format'] as String? ?? 'txt',
        addedAt:
            DateTime.tryParse(json['addedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        parseOk: json['parseOk'] as bool? ?? true,
        parseError: json['parseError'] as String?,
        contentKey: json['contentKey'] as String? ?? '',
      );

  /// 缓存目录名：优先用 contentKey，历史数据（无 key）回退到 safeId(id)
  String get cacheDirName => contentKey.isNotEmpty ? contentKey : id;
}
