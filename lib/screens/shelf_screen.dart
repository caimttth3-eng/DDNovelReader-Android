import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../i18n.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/app_storage.dart';
import '../services/book_cache_task.dart';
import '../services/book_parser.dart';
import '../services/tts_cache_store.dart';
import '../services/updater.dart';
import '../widgets/stable_system_bar_safe_area.dart';
import 'about_screen.dart';
import 'reader_screen.dart';

/// 书架首页：顶部「多多朗读」+ ⋮ 设置(添加书籍)，4 列木纹书架，无限下滑。
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  final AppStorage _storage = AppStorage();
  final BookParser _parser = BookParser();

  List<BookMeta> _books = [];
  Map<String, BookProgress> _progress = {};
  bool _loading = true;
  bool _readerRouteOpen = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
    // 启动后台检查更新（失败静默，不影响启动）
    Updater.checkAuto(context);
  }

  Future<void> _loadAll() async {
    final books = await _storage.loadBooks();
    final progressMap = <String, BookProgress>{};
    for (final b in books) {
      final p = await _storage.loadProgress(b.id);
      if (p != null) progressMap[b.id] = p;
    }
    if (!mounted) return;
    setState(() {
      _books = books;
      _progress = progressMap;
      _loading = false;
    });
    // 启动恢复：若有最后阅读的书籍，直接进入阅读页
    final lastId = await _storage.loadLastBookId();
    if (lastId != null && mounted) {
      for (final b in books) {
        if (b.id == lastId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openBook(b);
          });
          break;
        }
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

      // 若解析失败但文件存在，仍加入书架以便提示
      final meta = BookMeta(
        id: id,
        title: title,
        filePath: path,
        format: format.name,
        addedAt: DateTime.now(),
        parseOk: book.parseOk,
        parseError: book.parseError,
      );
      await _storage.addBook(meta);
      // 拷贝文件到应用私有目录（防止外部文件被清理/权限变化）
      await _copyToPrivate(path, id, format);
    }
    await _loadAll();
  }

  Future<void> _copyToPrivate(String srcPath, String bookId, BookFormat fmt) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final bookDir = Directory('${dir.path}/books');
      if (!await bookDir.exists()) await bookDir.create(recursive: true);
      final ext = srcPath.contains('.')
          ? srcPath.substring(srcPath.lastIndexOf('.'))
          : '.txt';
      final dst = '${bookDir.path}/$bookId$ext';
      await File(srcPath).copy(dst);
    } catch (_) {
      // 拷贝失败不影响书架显示
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
      body: StableSystemBarSafeArea(
        holdInsets: _readerRouteOpen,
        child: Column(
          children: [
            _buildTopBar(context),
            const Divider(height: 1, thickness: 1),
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
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            onSelected: (v) {
              if (v == 'add') _addBook();
              if (v == 'about') AboutScreen.show(context);
              if (v == 'cache') _openCacheManager();
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
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _books.length + 1,
      separatorBuilder: (_, index) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) {
        if (i == 0) return ListTile(
          leading: const Icon(Icons.note_add_outlined, color: Color(0xFF6498B5)),
          title: Text(T('addBook')), onTap: _addBook,
        );
        final meta = _books[i - 1];
        return ListTile(
          minVerticalPadding: 16,
          leading: const Icon(Icons.description_outlined, size: 36, color: Color(0xFF888888)),
          title: Text(meta.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(meta.format.toUpperCase(), style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
          trailing: Text('${((_progress[meta.id]?.percent ?? 0) * 100).toStringAsFixed(1)}%',
            style: const TextStyle(color: Color(0xFF777777))),
          onTap: () => _openBook(meta),
          onLongPress: () => _confirmDelete(meta),
        );
      },
    );
  }

  Future<void> _openBook(BookMeta meta) async {
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
    if (!mounted) return;
    if (!book.parseOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            T('parseFail', {'err': book.parseError ?? 'Unknown'}),
          ),
        ),
      );
      return;
    }
    final saved = await _storage.loadProgress(meta.id);
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          book: book,
          storage: _storage,
          initialProgress: saved,
          onProgressChanged: (p) async {
            // 同步书架腰封进度
            if (mounted) {
              setState(() => _progress[meta.id] = p);
            }
          },
        ),
      );
    setState(() => _readerRouteOpen = true);
    try {
      await Navigator.of(context).push(route);
      // The push future completes at pop, before the reverse transition does.
      await route.completed;
    } finally {
      if (mounted) setState(() => _readerRouteOpen = false);
    }
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
        if (TtsCacheStore.safeId(b.id) == safeId) return b.title;
      }
      return safeId;
    }

    // 清理一本书：若该书有运行中的缓存任务，先取消并从全局表移除
    Future<void> clearOne(String safeId) async {
      String? origId;
      for (final b in _books) {
        if (TtsCacheStore.safeId(b.id) == safeId) {
          origId = b.id;
          break;
        }
      }
      if (origId != null) {
        for (final entry in activeBookCaches.entries.toList()) {
          if (entry.value.bookId == origId) {
            entry.value.cancel();
            activeBookCaches.remove(entry.key);
          }
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
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                            style: TextStyle(
                                fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                                    style: TextStyle(
                                        fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
    }
  }
}
