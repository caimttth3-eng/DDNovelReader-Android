import 'dart:async';
import 'package:flutter/services.dart';

/// One writer for the selected reading or speech inactivity policy.
/// Expiration releases Android's override; Android decides when to lock.
class ReaderScreenAwake {
  static final Set<ReaderScreenAwake> _instances = {};
  /// The application listener also sees touches inside Navigator overlays.
  static void notifyUserInteraction() {
    for (final instance in _instances.toList()) { instance.interaction(); }
  }
  final Future<void> Function(bool) _write;
  Duration? _timeout;
  bool _active = false, _foreground = false;
  Object? _scope;
  bool _expired = true, _disposed = false;
  bool? _requested;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  ReaderScreenAwake({Future<void> Function(bool)? write}) : _write = write ?? _nativeWrite {
    _instances.add(this);
  }
  static Future<void> _nativeWrite(bool enabled) => const MethodChannel('com.ddnovelreader/volume_keys')
    .invokeMethod<void>('setKeepScreenOn', enabled);
  Future<void> get settled => _writes;

  void configure({required Duration? timeout, required bool active, required bool foreground, Object? scope}) {
    if (_disposed) return;
    final value = timeout != null && timeout > Duration.zero ? timeout : null;
    final restart = value != _timeout || active != _active || foreground != _foreground || scope != _scope;
    _timeout = value; _active = active; _foreground = foreground; _scope = scope;
    if (restart) _arm();
    _sync();
  }

  void interaction() {
    if (_disposed || !_active || !_foreground || _timeout == null) return;
    _arm(); _sync();
  }

  void _arm() {
    _timer?.cancel(); _timer = null; _expired = true;
    if (!_active || !_foreground || _timeout == null) return;
    _expired = false;
    _timer = Timer(_timeout!, () { _timer = null; _expired = true; _sync(); });
  }

  void _sync() {
    final hold = !_disposed && _foreground && _active && !_expired && _timeout != null;
    if (_requested == hold) return;
    _requested = hold;
    final value = hold;
    _writes = _writes.then((_) => _write(value)).then<void>((_) {}, onError: (Object _, StackTrace __) {
      // A detached Activity or engine must not block subsequent release calls.
      if (_requested == value) _requested = null;
    });
  }

  Future<void> dispose() {
    if (_disposed) return _writes;
    _disposed = true; _instances.remove(this); _timer?.cancel(); _timer = null;
    _sync();
    return _writes;
  }
}
