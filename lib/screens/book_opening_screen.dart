import 'dart:async';
import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/book.dart';
import '../models/progress.dart';
import '../services/app_storage.dart';
import '../services/app_appearance.dart';
import '../services/display_cutout.dart';
import '../services/reader_preparation.dart';
import '../services/book_snapshot_cache.dart';
import '../services/book_parser.dart';
import 'reader_screen.dart';

/// Opens the route immediately; file decoding and preparation run afterwards.
/// Reuses this route for the reader, so loading adds no second transition.
class BookOpeningScreen extends StatefulWidget {
  final String title;
  final Future<(Book, BookProgress?)> Function() loadBook;
  final AppStorage storage;
  final BookMeta? sourceMeta;
  @visibleForTesting
  final BookSnapshotCache? snapshotCache;
  final Future<void> Function(BookProgress)? onProgressChanged;

  const BookOpeningScreen({super.key, required this.title, required this.loadBook,
    required this.storage, this.onProgressChanged, this.sourceMeta, this.snapshotCache});

  @override
  State<BookOpeningScreen> createState() => _BookOpeningScreenState();
}

class _BookOpeningScreenState extends State<BookOpeningScreen> {
  late final Future<(Book, ReaderInitialData)> _book;
  ReadingSettings? _loadingSettings;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // Starting after the first route frame makes the tap visible before even
    // launching the background parser. The result never navigates by itself.
    _book = _load();
  }

  Future<(Book, ReaderInitialData)> _load() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _leaving) throw StateError('Book opening cancelled');
    final settingsFuture = widget.storage.loadSettings().then((raw) {
      if (mounted && !_leaving) setState(() => _loadingSettings = ReadingSettings.fromJson(raw));
      return raw;
    });
    final geometryFuture = DisplayCutoutService.read().catchError((Object _) => null);
    final dpr = WidgetsBinding.instance.platformDispatcher.implicitView?.devicePixelRatio ?? 1.0;
    var settings = ReadingSettings.fromJson(await settingsFuture);
    if (!mounted || _leaving) throw StateError('Book opening cancelled');
    final meta = widget.sourceMeta;
    final snapshots = widget.snapshotCache ?? BookSnapshotCache.shared;
    final lookup = meta == null ? null : await snapshots.lookup(meta, settings);
    if (!mounted || _leaving) throw StateError('Book opening cancelled');
    if (lookup?.snapshot != null) {
      BookParser.clearMemoryCache();
      ReaderPreparation.clearMemoryCache();
    }
    var cached = lookup?.snapshot?.prepared;
    final result = lookup?.snapshot != null ? (lookup!.snapshot!.source, null as BookProgress?) : await widget.loadBook();
    if (!mounted || _leaving) throw StateError('Book opening cancelled');
    if (!result.$1.parseOk) throw StateError(result.$1.parseError ?? 'Unknown');
    while (mounted && !_leaving) {
      setState(() => _loadingSettings = settings);
      final key = (settings.mergeNonSentenceBreaks, settings.firstLineIndent,
        settings.informationFilter ? settings.informationFilterLevel : 'none', settings.autoExtractToc, settings.speechPauses.cacheKey);
      final prepared = cached ?? await ReaderPreparation.prepare(ReaderPreparationRequest(result.$1,
        merge: key.$1, indent: key.$2, filter: key.$3, autoExtractToc: key.$4, pauseSettings: settings.speechPauses));
      cached = null;
      if (!mounted || _leaving) throw StateError('Book opening cancelled');
      final geometry = await geometryFuture;
      if (!mounted || _leaving) throw StateError('Book opening cancelled');
      final latest = ReadingSettings.fromJson(await widget.storage.loadSettings());
      if (!mounted || _leaving) throw StateError('Book opening cancelled');
      final latestKey = (latest.mergeNonSentenceBreaks, latest.firstLineIndent,
        latest.informationFilter ? latest.informationFilterLevel : 'none', latest.autoExtractToc, latest.speechPauses.cacheKey);
      if (latestKey != key) { settings = latest; continue; }
      final progress = meta == null ? result.$2 : await widget.storage.loadProgress(meta.id);
      if (!mounted || _leaving) throw StateError('Book opening cancelled');
      if (lookup != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(snapshots.save(lookup, result.$1, prepared, settings: latest));
        });
      }
      return (result.$1, ReaderInitialData(prepared: prepared, settings: latest, progress: progress,
        geometry: geometry, devicePixelRatio: dpr));
    }
    throw StateError('Book opening cancelled');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, result) { if (didPop) _leaving = true; },
    child: FutureBuilder<(Book, ReaderInitialData)>(
    future: _book,
    builder: (context, snapshot) {
      final result = snapshot.data;
      if (!_leaving && result != null) {
        return ReaderScreen(book: result.$1, storage: widget.storage,
          initialData: result.$2, onProgressChanged: widget.onProgressChanged);
      }
      final error = _leaving ? null : snapshot.error;
      if (error == null) {
        final settings = AppAppearance.applyCurrentMode(_loadingSettings ?? ReadingSettings());
        return Scaffold(backgroundColor: ReaderScreen.backgroundFor(settings), body: Stack(children: [
          Center(child: Semantics(label: widget.title, child: const CircularProgressIndicator())),
          const Positioned(left: 0, top: 0, child: SafeArea(child: BackButton())),
        ]));
      }
      return Scaffold(
        appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(T('parseFail', {'err': error.toString()})))),
      );
    },
  ));
}
