import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../i18n.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/annotation_store.dart';
import '../services/app_storage.dart';
import '../services/book_cache_task.dart';
import '../services/book_parser.dart';
import '../services/sync_engine.dart';
import '../services/tts_cache_store.dart';
import '../services/cache_diagnostics.dart';
import '../services/updater.dart';
import '../widgets/book_card.dart';
import 'about_screen.dart';
import 'book_opening_screen.dart';
import 'reader_screen.dart';
import 'sync_screen.dart';

/// 书架首页：顶部「多多朗读」+ ⋮ 设置(添加书籍)，4 列木纹书架，无限下滑。
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  final AppStorage _storage = AppStorage();
  final BookParser _parser = BookParser();
  final AnnotationStore _annotations = AnnotationStore();

  List<BookMeta> _books = [];
  Map<String, BookProgress> _progress = {};
  bool _loading = true;
  Timer? _syncTimer;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // 加载书架 → 补齐历史书指纹 → 自动同步（顺序不能颠倒，同步依赖正确的 key）
    _bootstrap();
    // 启动后台检查更新（失败静默，不影响启动）
    Updater.checkAuto(context);
  }

  Future<void> _bootstrap() async {
    await _loadAll();
    await _backfillKeys();
    await _autoSync();
    _startPeriodicSync();
    await _restoreLastBook();
  }

  /// 与 PC 端对齐：启动同步一次 + 前台每 10 分钟一次，让删除/进度不必等手动点同步。
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _autoSync(silent: true);
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  static final RegExp _ck2Pattern = RegExp(r'^[0-9a-f]{16}$');

  /// 补齐历史书（v1.2.4 之前导入）缺失的 ck2 指纹：contentKey 为空时同步会退化成
  /// 用 book id 当 key，两端对不上。这里按与 PC 相同的算法重算并回填，
  /// 顺带补 totalChars / chapterCount（远端记录需要）。只对异常书解析一次。
  /// 解析放在后台 isolate，避免长书解析阻塞 UI（否则启动会 ANR）。
  Future<void> _backfillKeys() async {
    var changed = false;
    final list = <BookMeta>[];
    for (final meta in _books) {
      var m = meta;
      final keyOk = _ck2Pattern.hasMatch(m.contentKey);
      if (!keyOk || m.totalChars == 0 || m.chapterCount == 0) {
        final path = m.filePath;
        final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '';
        final fmt = BookFormatX.fromExt(ext);
        final bid = m.id;
        final btitle = m.title;
        final badded = m.addedAt;
        try {
          final r = await Isolate.run(() async {
            final b = await BookParser().parse(
              id: bid,
              filePath: path,
              title: btitle,
              format: fmt,
              addedAt: badded,
            );
            return <Object?>[b.parseOk, b.contentKey, b.totalDisplayLength, b.chapterCount];
          });
          final parseOk = r[0] as bool;
          final key = r[1] as String;
          final total = r[2] as int;
          final chapters = r[3] as int;
          if (parseOk && key.isNotEmpty &&
              (key != m.contentKey || total != m.totalChars || chapters != m.chapterCount)) {
            m = m.copyWith(contentKey: key, totalChars: total, chapterCount: chapters);
            changed = true;
          }
        } catch (_) {
          // 文件缺失/解析异常：保持原样，同步时仍以 id 兜底
        }
      }
      list.add(m);
    }
    if (!changed) return;
    await _storage.saveBooks(list);
    if (!mounted) return;
    setState(() => _books = list);
  }

  Future<void> _autoSync({bool silent = false}) async {
    if (_syncing) return;
    final eng = SyncEngine(storage: _storage, annotations: _annotations);
    final s = await eng.settings();
    final autoOn = (s[SyncEngine.cfgAuto] as bool?) ?? true;
    // 定时同步只在开启自动同步时跑；删除/手动这类明确操作即使关了自动同步也要推
    if (silent && !autoOn) return;
    if (!eng.configured(s)) return;
    _syncing = true;
    SyncReport report;
    try {
      report = await eng.sync();
    } finally {
      _syncing = false;
    }
    if (!mounted || !report.ok) return;
    if (report.pulled > 0 || report.imported > 0 || report.removed > 0) {
      await _loadAll();
    }
    if (!silent &&
        (report.pulled > 0 ||
            report.pushed > 0 ||
            report.imported > 0 ||
            report.removed > 0 ||
            report.deleted > 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(report.summary), duration: const Duration(seconds: 3)),
      );
    }
  }

  /// 同步回来后只刷新进度腰封，不重建书架（避免打断正在看的界面）
  Future<void> _reloadProgress() async {
    final cur = <String, BookProgress>{};
    for (final b in _books) {
      final p = await _storage.loadProgress(b.id);
      if (p != null) cur[b.id] = p;
    }
    if (!mounted) return;
    setState(() => _progress = cur);
  }

  Future<void> _openSync() async {
    await SyncScreen.show(
      context,
      storage: _storage,
      annotations: _annotations,
      onSynced: _reloadAfterSync,
    );
  }

  /// 同步回来：可能有新书（远端独有）被拉进来，整表重载
  Future<void> _reloadAfterSync() async {
    await _loadAll();
    await _reloadProgress();
  }

  Future<void> _loadAll() async {
    final books = await _storage.loadBooks();
    // 最近打开的书排最前（第一本 = 上次打开的书），其余按最近打开顺序
    final order = await _storage.loadOpenOrder();
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    final indexed = [for (var i = 0; i < books.length; i++) (i, books[i])];
    indexed.sort((a, b) {
      final ra = rank[a.$2.id] ?? 1 << 30;
      final rb = rank[b.$2.id] ?? 1 << 30;
      return ra != rb ? ra.compareTo(rb) : a.$1.compareTo(b.$1);
    });
    final ordered = [for (final e in indexed) e.$2];
    final progressMap = <String, BookProgress>{};
    for (final b in ordered) {
      final p = await _storage.loadProgress(b.id);
      if (p != null) progressMap[b.id] = p;
    }
    if (!mounted) return;
    setState(() {
      _books = ordered;
      _progress = progressMap;
      _loading = false;
    });
  }

  /// 启动恢复：若有最后阅读的书籍，直接进入阅读页（放在指纹回填/同步之后）
  Future<void> _restoreLastBook() async {
    final lastId = await _storage.loadLastBookId();
    if (lastId == null || !mounted) return;
    for (final b in _books) {
      if (b.id == lastId) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openBook(b);
        });
        break;
      }
    }
  }

  Future<void> _addBook() async {
    // ignore: deprecated_member_use
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'pdf', 'docx'],
    );
    if (result.isEmpty) return;

    for (final file in result) {
      final path = file.path;
      if (path == null) continue;
      final ext = path.contains('.')
          ? path.substring(path.lastIndexOf('.'))
          : '';
      final format = BookFormatX.fromExt(ext);
      final title = _titleFromPath(path);
      final id =
          '${DateTime.now().microsecondsSinceEpoch}_${title.hashCode}';

      // 解析
      final book = await _parser.parse(
        id: id,
        filePath: path,
        title: title,
        format: format,
        addedAt: DateTime.now(),
      );

      // 先复制到应用私有目录（iOS 系统选择器的临时路径重签后会失效）
      final privatePath = await _copyToPrivate(path, id, format);

      // 若解析失败但文件存在，仍加入书架以便提示
      final meta = BookMeta(
        id: id,
        title: title,
        filePath: privatePath ?? path,
        format: format.name,
        addedAt: DateTime.now(),
        parseOk: book.parseOk,
        parseError: book.parseError,
        contentKey: book.contentKey,
        totalChars: book.totalDisplayLength,
        chapterCount: book.chapterCount,
      );
      await _storage.addBook(meta);
    }
    await _loadAll();
  }

  Future<String?> _copyToPrivate(String srcPath, String bookId, BookFormat fmt) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final bookDir = Directory('${dir.path}/books');
      if (!await bookDir.exists()) await bookDir.create(recursive: true);
      final ext = srcPath.contains('.')
          ? srcPath.substring(srcPath.lastIndexOf('.'))
          : '.txt';
      final dst = '${bookDir.path}/$bookId$ext';
      await File(srcPath).copy(dst);
      return dst;
    } catch (_) {
      // 拷贝失败不影响书架显示
      return null;
    }
  }

  String _titleFromPath(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F0E8),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            const Divider(height: 1, thickness: 1, color: Color(0xFFB5A58A)),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _buildGrid(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '多多朗读',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF5D3A1A),
              ),
            ),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF5D3A1A)),
            onSelected: (v) {
              if (v == 'add') _addBook();
              if (v == 'about') AboutScreen.show(context);
              if (v == 'cache') _openCacheManager();
              if (v == 'sync') _openSync();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'add',
                child: Row(
                  children: [
                    const Icon(Icons.library_add_outlined),
                    const SizedBox(width: 8),
                    Text(T('addBook')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'cache',
                child: Row(
                  children: [
                    const Icon(Icons.storage_outlined),
                    const SizedBox(width: 8),
                    Text(T('cacheManage')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'sync',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_sync_outlined),
                    const SizedBox(width: 8),
                    Text(T('syncData')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    const Icon(Icons.info_outline),
                    const SizedBox(width: 8),
                    Text(T('about')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 110, // 控制每行 4 格左右
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 9 / 16,
      ),
      itemCount: _books.length + 1, // 首位固定"添加书籍"空白书
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return AddBookCard(onTap: _addBook);
        }
        final meta = _books[i - 1];
        final p = _progress[meta.id];
        final progress = p?.percent ?? 0.0;
        final fmt = BookFormat.values.firstWhere(
          (f) => f.name == meta.format,
          orElse: () => BookFormat.txt,
        );
        return BookCard(
          title: meta.title,
          format: fmt,
          progress: progress,
          onTap: () => _openBook(meta),
          onLongPress: () => _confirmDelete(meta),
        );
      },
    );
  }

  Future<void> _openBook(BookMeta meta) async {
    // 记录打开顺序：回到书架时这本书排最前
    await _storage.touchOpened(meta.id);
    // 先打开加载页（首帧立即出画面），解析/排版在页面出现后再跑：
    // 大书点开不再卡在书架上等，解析完成会原地切到阅读页，没有二次转场。
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookOpeningScreen(
          title: meta.title,
          storage: _storage,
          sourceMeta: meta,
          loadBook: () async {
            final book = await _parser.parse(
              id: meta.id,
              filePath: meta.filePath,
              title: meta.title,
              format: BookFormat.values.firstWhere(
                (f) => f.name == meta.format,
                orElse: () => BookFormat.txt,
              ),
              addedAt: meta.addedAt,
            );
            if (!book.parseOk) {
              throw StateError(book.parseError ?? 'parse failed');
            }
            // 缓存目录一级键以书架记录为准（历史书已存 contentKey，新书解析时算好）
            final bookForReader = meta.contentKey.isEmpty
                ? book
                : book.withContentKey(meta.contentKey);
            // 从 PC 拉来的进度只有章内字符偏移，这里按书内容换算成段落坐标
            final saved = await _storage.loadProgress(meta.id);
            var initial = saved;
            if (initial != null && initial.charOffsetInChapter != null) {
              final (p, off) = bookForReader.locateByCharOffset(
                initial.chapterIndex,
                initial.charOffsetInChapter!,
              );
              initial = initial.copyWith(paragraphIndex: p, offsetInParagraph: off);
            }
            return (bookForReader, initial);
          },
          onProgressChanged: (p) async {
            await _storage.saveProgress(p);
            // 同步书架腰封进度
            if (mounted) {
              setState(() => _progress[meta.id] = p);
            }
          },
        ),
      ),
    ).then((_) { if (mounted) _loadAll(); });
  }

  /// 缓存管理：语音缓存总占用 + 按书籍列出占用（清理单本/清空全部）
  Future<void> _openCacheManager() async {
    String fmtSize(int bytes) {
      if (bytes <= 0) return '0 B';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }

    String bookTitleOf(String safeId) {
      for (final b in _books) {
        if (TtsCacheStore.safeId(b.cacheDirName) == safeId ||
            TtsCacheStore.safeId(b.id) == safeId) {
          return b.title;
        }
      }
      return safeId;
    }

    // 清理一本书：若该书有运行中的缓存任务，先取消并从全局表移除
    Future<void> clearOne(String safeId) async {
      String? origId;
      for (final b in _books) {
        if (TtsCacheStore.safeId(b.cacheDirName) == safeId ||
            TtsCacheStore.safeId(b.id) == safeId) {
          origId = b.id;
          break;
        }
      }
      if (origId != null) {
        final t = activeBookCaches[origId];
        if (t != null) {
          t.cancel();
          activeBookCaches.remove(origId);
        }
      }
      await TtsCacheStore.clearBook(safeId);
    }

    var total = -1;
    var books = <(String, int)>[];
    var loaded = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // 状态在方法作用域（不随 rebuild 重置），只扫描一次
          if (!loaded) {
            loaded = true;
            () async {
              total = await TtsCacheStore.totalSize();
              books = await TtsCacheStore.listBookSizes();
              if (ctx.mounted) setSheetState(() {});
            }();
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.storage_outlined,
                          color: Color(0xFF8A5A2B)),
                      const SizedBox(width: 10),
                      Text(T('cacheManage'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      TextButton(
                        key: const ValueKey('cache-export-diag'),
                        onPressed: () async {
                          final path = await exportCacheDiagnostics(_storage);
                          if (!ctx.mounted) return;
                          await showDialog<void>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: const Text('缓存诊断'),
                              content: Text(path == null
                                  ? '导出失败，请重试'
                                  : '已导出到：\n$path\n\n可在「文件」App 的“多多朗读”文件夹里找到 cache_report.json'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dctx),
                                  child: Text(T('ok')),
                                ),
                              ],
                            ),
                          );
                        },
                        child: const Text('导出诊断', style: TextStyle(fontSize: 12)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: () async {
                          total = -1;
                          setSheetState(() {});
                          total = await TtsCacheStore.totalSize();
                          books = await TtsCacheStore.listBookSizes();
                          if (ctx.mounted) setSheetState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    total < 0
                        ? T('cacheScanning')
                        : T('cacheTotal', {'size': fmtSize(total)}),
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  if (total < 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (books.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(T('cacheEmpty'),
                            style: const TextStyle(
                                fontSize: 13, color: Colors.black45)),
                      ),
                    )
                  else
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: books.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, color: Color(0xFFE0D6C4)),
                          itemBuilder: (_, i) {
                            final (safeId, bytes) = books[i];
                            return Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    bookTitleOf(safeId),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                Text(fmtSize(bytes),
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.black54)),
                                TextButton(
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: ctx,
                                      builder: (dctx) => AlertDialog(
                                        title: Text(T('cacheClearBook')),
                                        content: Text(T('cacheClearConfirm')),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, false),
                                            child: Text(T('cancel')),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, true),
                                            child: Text(T('ok')),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    await clearOne(safeId);
                                    total = await TtsCacheStore.totalSize();
                                    books =
                                        await TtsCacheStore.listBookSizes();
                                    if (ctx.mounted) {
                                      setSheetState(() {});
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(
                                            content: Text(T('cacheCleared'))),
                                      );
                                    }
                                  },
                                  child: Text(T('cacheClear'),
                                      style: const TextStyle(
                                          fontSize: 12, color: Color(0xFF8A5A2B))),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (total > 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: Text(T('cacheClearAll')),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: Text(T('cacheClearAll')),
                              content: Text(T('cacheClearConfirm')),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dctx, false),
                                  child: Text(T('cancel')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  child: Text(T('ok')),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          for (final t in activeBookCaches.values.toList()) {
                            t.cancel();
                          }
                          activeBookCaches.clear();
                          await TtsCacheStore.clearAll();
                          total = 0;
                          books = [];
                          if (ctx.mounted) {
                            setSheetState(() {});
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text(T('cacheCleared'))),
                            );
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BookMeta meta) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(T('deleteTitle')),
        content: Text(T('deleteConfirm', {'title': meta.title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(T('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(T('delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _storage.removeBook(meta.id);
      await _loadAll();
      // 删完立刻把墓碑推上去（不等定时同步），否则另一端会一直留着这本书
      await _autoSync(silent: false);
    }
  }
}
