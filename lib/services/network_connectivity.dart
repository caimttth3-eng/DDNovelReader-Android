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

  Stream<bool> _watch() async* {
    final initial = await getAvailability();
    // Do not subscribe to a missing native EventChannel on older builds or
    // non-Android platforms. EventChannel reports failed listen calls globally.
    if (initial == null) {
      try {
        if (await channel.invokeMethod<bool>('isSupported') != true) return;
      } on MissingPluginException { return; }
      on PlatformException { return; }
      // A supported native host can temporarily have no capability snapshot.
      // Keep listening rather than treating an undecided network as offline.
    } else {
      yield initial;
    }
    try {
      // Share one native subscription while reader routes overlap during a
      // transition. Disposing the old route must not stop the new monitor.
      final stream = _events ??= events.receiveBroadcastStream();
      await for (final value in stream) {
        if (value is bool) yield value;
      }
    } on MissingPluginException {
      // The host can detach during an activity or engine transition.
    } on PlatformException {
      // Actual speech errors remain authoritative if monitoring is unavailable.
    }
  }
}
