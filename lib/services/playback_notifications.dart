import 'package:flutter/services.dart';

class PlaybackNotificationStatus {
  final bool supported, enabled, canRequest, asked;
  const PlaybackNotificationStatus({required this.supported, required this.enabled,
    required this.canRequest, required this.asked});
  static const unavailable = PlaybackNotificationStatus(supported: false, enabled: false,
    canRequest: false, asked: false);

  factory PlaybackNotificationStatus.fromMap(Map<dynamic, dynamic> map) => PlaybackNotificationStatus(
    supported: map['supported'] == true, enabled: map['enabled'] == true,
    canRequest: map['canRequest'] == true, asked: map['asked'] == true);
}

class PlaybackNotificationCheck {
  final PlaybackNotificationStatus status;
  final bool requested;
  const PlaybackNotificationCheck(this.status, {this.requested = false});
}

/// Permission requests are reserved for a foreground screen gesture. Media
/// commands and lifecycle changes only read status, and never open a prompt.
class PlaybackNotifications {
  static const channel = MethodChannel('com.ddnovelreader/notifications');
  bool _attempted = false;
  Future<PlaybackNotificationCheck>? _request;

  Future<PlaybackNotificationStatus> getStatus() async {
    try {
      final map = await channel.invokeMapMethod<dynamic, dynamic>('getNotificationStatus');
      return map == null ? PlaybackNotificationStatus.unavailable : PlaybackNotificationStatus.fromMap(map);
    } on MissingPluginException {
      return PlaybackNotificationStatus.unavailable;
    } on PlatformException {
      return PlaybackNotificationStatus.unavailable;
    }
  }

  Future<PlaybackNotificationCheck> checkForPlayback({required bool foregroundUserAction}) {
    if (!foregroundUserAction) return getStatus().then((status) => PlaybackNotificationCheck(status));
    return _request ??= _checkAndRequest().whenComplete(() { _request = null; });
  }

  Future<PlaybackNotificationCheck> _checkAndRequest() async {
    final status = await getStatus();
    // Native persists `asked`, so opening another book or restarting the app
    // never asks again. This latch also protects errors and concurrent taps.
    if (!status.supported || status.enabled || !status.canRequest || status.asked || _attempted) {
      return PlaybackNotificationCheck(status);
    }
    _attempted = true;
    try {
      final map = await channel.invokeMapMethod<dynamic, dynamic>('requestNotificationPermission');
      if (map != null) return PlaybackNotificationCheck(PlaybackNotificationStatus.fromMap(map), requested: true);
    } on MissingPluginException {
      // An older native build can still read status without this method.
    } on PlatformException {
      // Permission failure never blocks reading or starts another prompt.
    }
    return PlaybackNotificationCheck(PlaybackNotificationStatus(supported: status.supported,
      enabled: status.enabled, canRequest: false, asked: true), requested: true);
  }

  Future<bool> openSettings() async {
    try {
      return await channel.invokeMethod<bool>('openNotificationSettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
