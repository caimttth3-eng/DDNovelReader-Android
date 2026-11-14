import 'dart:async';
import 'package:flutter/services.dart';

/// Reports whether Android has an Internet-capable default network. This does
/// not claim that a particular speech endpoint is reachable; its real requests
/// still determine that. Unknown platform state leaves the selected voice alone.
class NetworkConnectivity {
  static const channel = MethodChannel('com.ddnovelreader/network');
  static const events = EventChannel('com.ddnovelreader/network/events');
  static Stream<dynamic>? _events;

  Future<bool?> getAvailability() async {
    try {
      return await channel.invokeMethod<bool>('getAvailability');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Stream<bool> get availability => _watch().distinct();

  Stream<bool> _watch() {
    StreamSubscription<dynamic>? subscription;
    var cancelled = false;
    late final StreamController<bool> controller;
    void close() { if (!controller.isClosed) unawaited(controller.close()); }
    Future<void> start() async {
      final initial = await getAvailability();
      if (cancelled) return;
      // Unknown capabilities on a real Android host still need monitoring.
      // A missing native plugin must not start an unsupported EventChannel.
      if (initial == null) {
        try {
          if (await channel.invokeMethod<bool>('isSupported') != true) { close(); return; }
        } on MissingPluginException { close(); return; }
        on PlatformException { close(); return; }
      }
      if (cancelled) return;
      if (initial != null) controller.add(initial);
      // Share the native broadcast source while reader routes overlap. Use an
      // explicit subscription so cancellation never waits for another network
      // event, as an async generator awaiting its next event otherwise can.
      final stream = _events ??= events.receiveBroadcastStream();
      subscription = stream.listen((value) {
        if (!cancelled && !controller.isClosed && value is bool) controller.add(value);
      }, onError: (Object _, StackTrace __) {
        // Actual speech requests remain authoritative if monitoring detaches.
        close();
      }, onDone: close);
    }
    controller = StreamController<bool>(onListen: start, onCancel: () async {
      cancelled = true;
      await subscription?.cancel();
    });
    return controller.stream;
  }
}
