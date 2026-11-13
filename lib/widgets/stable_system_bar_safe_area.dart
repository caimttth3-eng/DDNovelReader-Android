import 'package:flutter/material.dart';

import '../services/display_cutout.dart';

/// Keeps the covered bookshelf at its normal system-bar insets while a
/// fullscreen route enters or leaves. Live insets resume after the bars return.
class StableSystemBarSafeArea extends StatefulWidget {
  final bool holdInsets;
  final Widget child;

  const StableSystemBarSafeArea({super.key, required this.holdInsets, required this.child});

  @override
  State<StableSystemBarSafeArea> createState() => _StableSystemBarSafeAreaState();
}

class _StableSystemBarSafeAreaState extends State<StableSystemBarSafeArea> with WidgetsBindingObserver {
  final Map<(Size, double), EdgeInsets> _normalInsets = {};
  bool _waitingForBars = false;
  int _revision = 0;
  bool _refreshScheduled = false;
  (Size, double, EdgeInsets)? _lastMedia;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(StableSystemBarSafeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.holdInsets && !widget.holdInsets) _waitingForBars = true;
    if (oldWidget.holdInsets != widget.holdInsets) _scheduleRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final current = (media.size, media.devicePixelRatio, media.viewPadding);
    if (_lastMedia != current && (widget.holdInsets || _waitingForBars)) _scheduleRefresh();
    _lastMedia = current;
  }

  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refreshNormalInsets();
    });
  }

  @override
  void didChangeMetrics() {
    if (widget.holdInsets || _waitingForBars) {
      _scheduleRefresh();
    }
  }

  Future<void> _refreshNormalInsets() async {
    final requestedMedia = MediaQuery.of(context);
    final requestedKey = (requestedMedia.size, requestedMedia.devicePixelRatio);
    final revision = ++_revision;
    final geometry = await DisplayCutoutService.read();
    if (!mounted || revision != _revision || geometry?.systemBarInsets == null) return;
    final media = MediaQuery.of(context);
    final key = (media.size, media.devicePixelRatio);
    if (key != requestedKey || !geometry!.matches(media.size)) return;
    if (!widget.holdInsets && _waitingForBars && geometry.statusBarVisible &&
        _sameInsets(media.viewPadding, geometry.systemBarInsets!)) {
      // Navigation mode may have changed while the reader was open. Accept
      // the restored configuration, including smaller insets, rather than
      // waiting forever for the previous snapshot to return.
      setState(() {
        _waitingForBars = false;
        _normalInsets[key] = media.viewPadding;
      });
      return;
    }
    // A new orientation/window size may first be seen while the bars are
    // hidden. Use visibility-independent native insets for that case.
    // Do not replace an existing visible snapshot with a later async result.
    if ((widget.holdInsets || _waitingForBars) && !_normalInsets.containsKey(key)) {
      setState(() => _normalInsets[key] = geometry.systemBarInsets!);
    }
  }

  bool _sameInsets(EdgeInsets a, EdgeInsets b) =>
    (a.left - b.left).abs() < 0.5 && (a.top - b.top).abs() < 0.5 &&
    (a.right - b.right).abs() < 0.5 && (a.bottom - b.bottom).abs() < 0.5;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final key = (media.size, media.devicePixelRatio);
    final saved = _normalInsets[key];
    if (_waitingForBars && saved != null && _sameInsets(media.viewPadding, saved)) {
      _waitingForBars = false;
    }
    final frozen = widget.holdInsets || _waitingForBars;
    if (!frozen) _normalInsets[key] = media.viewPadding;
    final insets = frozen ? saved ?? media.viewPadding : media.viewPadding;
    return MediaQuery.removePadding(
      context: context, removeLeft: true, removeTop: true, removeRight: true, removeBottom: true,
      child: Padding(
        padding: insets.copyWith(bottom: media.viewInsets.bottom > 0 ? 0 : insets.bottom),
        child: widget.child,
      ),
    );
  }

  @override
  void dispose() {
    ++_revision;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
