// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
/// 每本书的阅读进度
class BookProgress {
  final String bookId;
  int chapterIndex;
  int paragraphIndex;

  /// 段落内偏移（按 display 字符），用于续读精确定位
  int offsetInParagraph;
  double percent;

  /// 最后更新时间（epoch 秒）。WebDAV 同步按此值判"谁更新"，
  /// 与 PC 端 `last_read_at` / 记录里的 `updated_at` 同一口径。
  double updatedAt;

  /// PC 端进度只有"章内字符偏移"（char_offset），没有段落坐标；
  /// 从远端拉下这种进度时先原样存着，打开书时再换算成 (段落, 段内偏移)。
  /// 若记录里同时带段落坐标，则清空本字段（不需要换算），但保留 [pcCharOffset]
  /// 以便原样推回 PC。
  int? charOffsetInChapter;

  /// 最近一次从 PC 结构收到的 char_offset（只用于回写，不参与定位）
  int? pcCharOffset;

  // ---------- 排版/视口定位（PR2 引入，用于完整行分页的精确续读） ----------
  int? chapterAnchor;
  int? viewportItem;
  double viewportAlignment;
  String layoutSignature;
  bool atChapterTitle;
  int? flowChapter;
  int? flowAnchor;

  BookProgress({
    required this.bookId,
    this.chapterIndex = 0,
    this.paragraphIndex = 0,
    this.offsetInParagraph = 0,
    this.percent = 0,
    double? updatedAt,
    this.charOffsetInChapter,
    this.pcCharOffset,
    this.chapterAnchor,
    this.viewportItem,
    this.viewportAlignment = 0,
    this.layoutSignature = '',
    this.atChapterTitle = false,
    this.flowChapter,
    this.flowAnchor,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch / 1000.0;

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'paragraphIndex': paragraphIndex,
        'offsetInParagraph': offsetInParagraph,
        'percent': percent,
        'updatedAt': updatedAt,
        if (charOffsetInChapter != null)
          'charOffsetInChapter': charOffsetInChapter,
        if (pcCharOffset != null) 'pcCharOffset': pcCharOffset,
        'chapterAnchor': chapterAnchor,
        'viewportItem': viewportItem,
        'viewportAlignment': viewportAlignment,
        'layoutSignature': layoutSignature,
        'atChapterTitle': atChapterTitle,
        'flowChapter': flowChapter,
        'flowAnchor': flowAnchor,
      };

  factory BookProgress.fromJson(Map<String, dynamic> json) => BookProgress(
        bookId: json['bookId'] as String? ?? '',
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        paragraphIndex: json['paragraphIndex'] as int? ?? 0,
        offsetInParagraph: json['offsetInParagraph'] as int? ?? 0,
        percent: (json['percent'] as num?)?.toDouble() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toDouble(),
        charOffsetInChapter: (json['charOffsetInChapter'] as num?)?.toInt(),
        pcCharOffset: (json['pcCharOffset'] as num?)?.toInt(),
        chapterAnchor: json['chapterAnchor'] as int?,
        viewportItem: json['viewportItem'] as int?,
        viewportAlignment: (json['viewportAlignment'] as num?)?.toDouble() ?? 0,
        layoutSignature: json['layoutSignature'] as String? ?? '',
        atChapterTitle: json['atChapterTitle'] as bool? ?? false,
        flowChapter: json['flowChapter'] as int?,
        flowAnchor: json['flowAnchor'] as int?,
      );

  /// PC 兼容结构：`{chapter_idx, char_offset, percent}`。
  /// 段落坐标缺失时 char_offset 只能由调用方按书籍内容补齐。
  Map<String, dynamic> toPcJson() => {
        'chapter_idx': chapterIndex,
        'char_offset': charOffsetInChapter ?? pcCharOffset ?? 0,
        'percent': percent,
        // 安卓自有坐标，PC 端忽略未知字段，但换回安卓时可直接用
        'paragraph_index': paragraphIndex,
        'offset_in_paragraph': offsetInParagraph,
      };

  /// 从 PC 结构还原：有段落坐标时直接用，否则留 charOffset 待打开书换算。
  static BookProgress fromPcJson(String bookId, Map<String, dynamic> json) {
    final hasPara = json['paragraph_index'] != null;
    final charOffset = (json['char_offset'] as num?)?.toInt();
    return BookProgress(
      bookId: bookId,
      chapterIndex: (json['chapter_idx'] as num?)?.toInt() ?? 0,
      paragraphIndex: (json['paragraph_index'] as num?)?.toInt() ?? 0,
      offsetInParagraph: (json['offset_in_paragraph'] as num?)?.toInt() ?? 0,
      percent: (json['percent'] as num?)?.toDouble() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toDouble(),
      charOffsetInChapter: hasPara ? null : charOffset,
      pcCharOffset: charOffset,
    );
  }

  BookProgress copyWith({
    int? chapterIndex,
    int? paragraphIndex,
    int? offsetInParagraph,
    double? percent,
    double? updatedAt,
    int? charOffsetInChapter,
    int? chapterAnchor,
    int? viewportItem,
    double? viewportAlignment,
    String? layoutSignature,
    bool? atChapterTitle,
    int? flowChapter,
    int? flowAnchor,
  }) =>
      BookProgress(
        bookId: bookId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        paragraphIndex: paragraphIndex ?? this.paragraphIndex,
        offsetInParagraph: offsetInParagraph ?? this.offsetInParagraph,
        percent: percent ?? this.percent,
        updatedAt: updatedAt ?? this.updatedAt,
        charOffsetInChapter: charOffsetInChapter ?? this.charOffsetInChapter,
        pcCharOffset: pcCharOffset,
        chapterAnchor: chapterAnchor ?? this.chapterAnchor,
        viewportItem: viewportItem ?? this.viewportItem,
        viewportAlignment: viewportAlignment ?? this.viewportAlignment,
        layoutSignature: layoutSignature ?? this.layoutSignature,
        atChapterTitle: atChapterTitle ?? this.atChapterTitle,
        flowChapter: flowChapter ?? this.flowChapter,
        flowAnchor: flowAnchor ?? this.flowAnchor,
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

  /// 全书正文字数（PC 记录里的 total_chars；用于跨端对账，可缺省 0）
  final int totalChars;

  /// 章节数（PC 记录里的 chapter_count；可缺省 0）
  final int chapterCount;

  const BookMeta({
    required this.id,
    required this.title,
    required this.filePath,
    required this.format,
    required this.addedAt,
    this.parseOk = true,
    this.parseError,
    this.contentKey = '',
    this.totalChars = 0,
    this.chapterCount = 0,
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
        'totalChars': totalChars,
        'chapterCount': chapterCount,
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
        totalChars: (json['totalChars'] as num?)?.toInt() ?? 0,
        chapterCount: (json['chapterCount'] as num?)?.toInt() ?? 0,
      );

  /// 缓存目录名：优先用 contentKey，历史数据（无 key）回退到 safeId(id)
  String get cacheDirName => contentKey.isNotEmpty ? contentKey : id;

  BookMeta copyWith({
    String? filePath,
    String? contentKey,
    int? totalChars,
    int? chapterCount,
  }) =>
      BookMeta(
        id: id,
        title: title,
        filePath: filePath ?? this.filePath,
        format: format,
        addedAt: addedAt,
        parseOk: parseOk,
        parseError: parseError,
        contentKey: contentKey ?? this.contentKey,
        totalChars: totalChars ?? this.totalChars,
        chapterCount: chapterCount ?? this.chapterCount,
      );
}
