// 来源：NayGnehz/DDNovelReader-Android 的 PR #2（commit 27b6a1e，部分代码，已修改适配本项目的缓存/同步架构）。
/// 每本书的阅读进度
class BookProgress {
  final String bookId;
  int chapterIndex;
  int paragraphIndex;

  /// 段落内偏移（按 display 字符），用于续读精确定位
  int offsetInParagraph;
  double percent;

  /// Unlabelled pre-schema-2 percentages cannot safely be interpreted by value.
  /// Keep the original value until a real reader update supplies a known ratio.
  double? ambiguousPercent;

  /// 最后更新时间（epoch 秒）。WebDAV 同步按此值判"谁更新"，
  /// 与 PC 端 `last_read_at` / 记录里的 `updated_at` 同一口径。
  double updatedAt;

  /// PC 端进度只有"章内字符偏移"（char_offset），没有段落坐标；
  /// 从远端拉下这种进度时先原样存着，打开书时再换算成 (段落, 段内偏移)。
  /// 远端即使附带 Android 坐标，也优先使用规范 char_offset。
  int? charOffsetInChapter;

  /// 最近一次从 PC 结构收到的 char_offset，保留以便回写。
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
    this.ambiguousPercent,
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
        if (ambiguousPercent != null) 'ambiguousPercent': ambiguousPercent,
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
        ambiguousPercent: (json['ambiguousPercent'] as num?)?.toDouble(),
        updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
        charOffsetInChapter: (json['charOffsetInChapter'] as num?)?.toInt() ??
            (json['chapterAnchor'] == null && json['viewportItem'] == null &&
                    (json['layoutSignature'] as String? ?? '').isEmpty
                ? (json['pcCharOffset'] as num?)?.toInt() : null),
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
        'coordinate_authority': charOffsetInChapter != null || pcCharOffset != null
            ? 'canonical' : 'android_legacy',
        'percent': ambiguousPercent ?? percent,
        'percent_unit': ambiguousPercent == null ? 'ratio' : 'unknown',
        if (ambiguousPercent != null) 'percent_ambiguous': true,
        // 安卓自有坐标，PC 端忽略未知字段，但换回安卓时可直接用
        'paragraph_index': paragraphIndex,
        'offset_in_paragraph': offsetInParagraph,
      };

  /// Canonical wire offsets win; paragraph coordinates are legacy fallback only.
  static BookProgress fromPcJson(String bookId, Map<String, dynamic> json) {
    final charOffset = json['coordinate_authority'] == 'android_legacy'
        ? null : (json['char_offset'] as num?)?.toInt();
    return BookProgress(
      bookId: bookId,
      chapterIndex: (json['chapter_idx'] as num?)?.toInt() ?? 0,
      paragraphIndex: (json['paragraph_index'] as num?)?.toInt() ?? 0,
      offsetInParagraph: (json['offset_in_paragraph'] as num?)?.toInt() ?? 0,
      percent: (json['percent'] as num?)?.toDouble() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toDouble() ?? 0,
      charOffsetInChapter: charOffset,
      pcCharOffset: charOffset,
    );
  }

  BookProgress copyWith({
    String? bookId,
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
        bookId: bookId ?? this.bookId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        paragraphIndex: paragraphIndex ?? this.paragraphIndex,
        offsetInParagraph: offsetInParagraph ?? this.offsetInParagraph,
        percent: percent ?? this.percent,
        ambiguousPercent: percent == null ? ambiguousPercent : null,
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

  /// User import/metadata version, or a real version received from sync.
  /// Parsing/receiving and display addedAt never manufacture a new timestamp.
  final double activityAt;
  final List<String> aliases;
  final List<String> sourcePaths;

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
    this.activityAt = 0,
    this.aliases = const [],
    this.sourcePaths = const [],
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
        'activityAt': activityAt,
        'aliases': aliases,
        'sourcePaths': sourcePaths,
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
        activityAt: (json['activityAt'] as num?)?.toDouble() ?? 0,
        aliases: (json['aliases'] as List?)?.whereType<String>().toList() ?? const [],
        sourcePaths: (json['sourcePaths'] as List?)?.whereType<String>().toList() ?? const [],
      );

  /// 缓存目录名：优先用 contentKey，历史数据（无 key）回退到 safeId(id)
  String get cacheDirName => contentKey.isNotEmpty ? contentKey : id;

  BookMeta copyWith({
    String? title,
    String? filePath,
    String? format,
    bool? parseOk,
    String? contentKey,
    int? totalChars,
    int? chapterCount,
    double? activityAt,
    List<String>? aliases,
    List<String>? sourcePaths,
  }) =>
      BookMeta(
        id: id,
        title: title ?? this.title,
        filePath: filePath ?? this.filePath,
        format: format ?? this.format,
        addedAt: addedAt,
        parseOk: parseOk ?? this.parseOk,
        parseError: parseError,
        contentKey: contentKey ?? this.contentKey,
        totalChars: totalChars ?? this.totalChars,
        chapterCount: chapterCount ?? this.chapterCount,
        activityAt: activityAt ?? this.activityAt,
        aliases: aliases ?? this.aliases,
        sourcePaths: sourcePaths ?? this.sourcePaths,
      );
}
