import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/app_storage.dart';
import 'reader_screen.dart';

/// Opens the route immediately; file decoding and preparation run afterwards.
/// Reuses this route for the reader, so loading adds no second transition.
class BookOpeningScreen extends StatefulWidget {
  final String title;
  final Future<(Book, BookProgress?)> Function() loadBook;
  final AppStorage storage;
  final Future<void> Function(BookProgress)? onProgressChanged;

  const BookOpeningScreen({super.key, required this.title, required this.loadBook,
    required this.storage, this.onProgressChanged});

  @override
  State<BookOpeningScreen> createState() => _BookOpeningScreenState();
}

class _BookOpeningScreenState extends State<BookOpeningScreen> {
  late final Future<(Book, BookProgress?)> _book;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // Starting after the first route frame makes the tap visible before even
    // launching the background parser. The result never navigates by itself.
    _book = _load();
  }

  Future<(Book, BookProgress?)> _load() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _leaving) throw StateError('Book opening cancelled');
    return widget.loadBook();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, result) { if (didPop) _leaving = true; },
    child: FutureBuilder<(Book, BookProgress?)>(
    future: _book,
    builder: (context, snapshot) {
      final result = snapshot.data;
      if (!_leaving && result != null && result.$1.parseOk) {
        return ReaderScreen(book: result.$1, storage: widget.storage,
          initialProgress: result.$2, onProgressChanged: widget.onProgressChanged);
      }
      final error = _leaving ? null : snapshot.error ??
        (result == null || result.$1.parseOk ? null : result.$1.parseError ?? 'Unknown');
      return Scaffold(
        appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: Center(child: error == null ? const CircularProgressIndicator()
          : Padding(padding: const EdgeInsets.all(24), child: Text(T('parseFail', {'err': error.toString()})))),
      );
    },
  ));
}
