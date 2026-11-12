import 'dart:async';
import 'package:flutter/services.dart';

class SystemTtsClient {
  static const voiceId = '__system_tts__';
  static const channel = MethodChannel('com.ddnovelreader/system_tts');
  static SystemTtsClient? _owner;
  Future<void>? _initialization;
  String? _request;
  int _serial = 0;
  int _epoch = 0;
  Completer<void>? _started;
  void Function()? _done;
  void Function(int, int)? _range;
  void Function(Object)? _error;

  SystemTtsClient() {
    if (_owner != null) unawaited(_owner!.stop());
    _owner = this;
    channel.setMethodCallHandler(_onEvent);
  }

  Future<void> initialize() => _initialization ??= channel.invokeMethod('initialize')
      .timeout(const Duration(seconds: 15)).then<void>((_) {}, onError: (Object error) {
        _initialization = null; throw error;
      });

  Future<void> speak(String text, double rate, {required void Function() onDone,
    required void Function(int, int) onRange, required void Function(Object) onError}) async {
    final epoch = _epoch;
    await initialize();
    if (epoch != _epoch || _owner != this) throw const SystemSpeechCancelled();
    final id = '${identityHashCode(this)}-${++_serial}';
    _request = id; _done = onDone; _range = onRange; _error = onError;
    final started = Completer<void>(); _started = started;
    try {
      await Future.wait<void>([
        channel.invokeMethod<void>('speak', {'id': id, 'text': text, 'rate': rate}),
        started.future.timeout(const Duration(seconds: 30)),
      ]);
    } catch (_) {
      if (_request == id) await stop();
      rethrow;
    }
  }

  Future<dynamic> _onEvent(MethodCall call) async {
    final data = call.arguments;
    if (data is! Map || data['id'] != _request) return;
    switch (call.method) {
      case 'start':
        if (!(_started?.isCompleted ?? true)) _started!.complete();
      case 'range':
        _range?.call(data['start'] as int, data['end'] as int);
      case 'done':
        if (!(_started?.isCompleted ?? true)) _started!.complete();
        _request = null; _done?.call();
      case 'error':
        final error = PlatformException(code: 'system_speech_${data['code']}', message: 'System speech failed');
        _request = null;
        if (!(_started?.isCompleted ?? true)) { _started!.completeError(error); }
        else { _error?.call(error); }
    }
  }

  Future<void> stop() async {
    _epoch++;
    final hadRequest = _request != null;
    _request = null; _done = null; _range = null; _error = null;
    if (!(_started?.isCompleted ?? true)) _started!.completeError(const SystemSpeechCancelled());
    _started = null;
    if (hadRequest && _owner == this) await channel.invokeMethod('stop');
  }

  Future<void> dispose() async {
    await stop();
    if (_owner == this) { _owner = null; channel.setMethodCallHandler(null); }
  }
}

class SystemSpeechCancelled implements Exception { const SystemSpeechCancelled(); }
