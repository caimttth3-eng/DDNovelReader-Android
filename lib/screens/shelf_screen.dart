import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/progress.dart';
import '../services/app_storage.dart';
import '../services/book_parser.dart';
import '../widgets/book_card.dart';
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

  @override
  void initState() {
    super.initState();
    _loadAll();
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
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'add',
                child: Row(
                  children: [
                    Icon(Icons.library_add_outlined),
                    SizedBox(width: 8),
                    Text('添加书籍'),
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
        SnackBar(content: Text('书籍解析失败：${book.parseError ?? '未知错误'}')),
      );
      return;
    }
    final saved = await _storage.loadProgress(meta.id);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          storage: _storage,
          initialProgress: saved,
          onProgressChanged: (p) async {
            await _storage.saveProgress(p);
            // 同步书架腰封进度
            if (mounted) {
              setState(() => _progress[meta.id] = p);
            }
          },
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BookMeta meta) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定从书架移除《${meta.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
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
