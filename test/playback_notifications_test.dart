import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/playback_notifications.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final calls = <String>[];
  var enabled = false, asked = false, canRequest = true, grant = false;
  Map<String, bool> status() => {'supported': true, 'enabled': enabled, 'canRequest': canRequest, 'asked': asked};
  setUp(() {
    calls.clear(); enabled = false; asked = false; canRequest = true; grant = false;
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'requestNotificationPermission') { asked = true; enabled = grant; }
      if (call.method == 'openNotificationSettings') return true;
      return status();
    });
  });
  tearDown(() { messenger.setMockMethodCallHandler(PlaybackNotifications.channel, null); });

  test('foreground request grants once and subsequent checks only read status', () async {
    grant = true;
    final notifications = PlaybackNotifications();
    final result = await notifications.checkForPlayback(foregroundUserAction: true);
    expect(result.requested, isTrue); expect(result.status.enabled, isTrue);
    expect((await notifications.checkForPlayback(foregroundUserAction: true)).requested, isFalse);
    expect(calls.where((method) => method == 'requestNotificationPermission'), hasLength(1));
  });

  test('denial never blocks and native asked survives another reader instance', () async {
    final notifications = PlaybackNotifications();
    final result = await notifications.checkForPlayback(foregroundUserAction: true);
    expect(result.requested, isTrue); expect(result.status.enabled, isFalse); expect(result.status.asked, isTrue);
    await notifications.checkForPlayback(foregroundUserAction: true);
    await PlaybackNotifications().checkForPlayback(foregroundUserAction: true);
    expect(calls.where((method) => method == 'requestNotificationPermission'), hasLength(1));
    expect(await notifications.openSettings(), isTrue);
    enabled = true;
    expect((await notifications.getStatus()).enabled, isTrue, reason: 'Settings return reads fresh system state');
  });

  test('background media and pre33 never request permission', () async {
    final notifications = PlaybackNotifications();
    await notifications.checkForPlayback(foregroundUserAction: false);
    expect(calls, ['getNotificationStatus']);
    canRequest = false;
    expect((await notifications.checkForPlayback(foregroundUserAction: true)).requested, isFalse);
    expect(calls.where((method) => method == 'requestNotificationPermission'), isEmpty);
    expect(await notifications.openSettings(), isTrue);
  });

  test('concurrent foreground gestures share one permission prompt', () async {
    final pending = Completer<Map<String, bool>>();
    var requests = 0;
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
      if (call.method == 'requestNotificationPermission') { requests++; return pending.future; }
      return status();
    });
    final notifications = PlaybackNotifications();
    final first = notifications.checkForPlayback(foregroundUserAction: true);
    final second = notifications.checkForPlayback(foregroundUserAction: true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    enabled = true; asked = true; pending.complete(status());
    expect((await first).status.enabled, isTrue); expect((await second).status.enabled, isTrue);
  });

  test('missing plugin and platform failures are compatible and do not loop requests', () async {
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, null);
    final missing = PlaybackNotifications();
    expect((await missing.checkForPlayback(foregroundUserAction: true)).status.supported, isFalse);
    expect(await missing.openSettings(), isFalse);
    var requests = 0;
    messenger.setMockMethodCallHandler(PlaybackNotifications.channel, (call) async {
      if (call.method == 'getNotificationStatus') return status();
      if (call.method == 'requestNotificationPermission') requests++;
      throw PlatformException(code: 'not_available');
    });
    final failing = PlaybackNotifications();
    expect((await failing.checkForPlayback(foregroundUserAction: true)).status.enabled, isFalse);
    await failing.checkForPlayback(foregroundUserAction: true);
    expect(requests, 1); expect(await failing.openSettings(), isFalse);
  });
}
