import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/network_connectivity.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final streamChannel = MethodChannel(NetworkConnectivity.events.name);
  tearDown(() {
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, null);
    messenger.setMockMethodCallHandler(streamChannel, null);
  });

  test('unknown network status does not subscribe or claim that the device is offline', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(streamChannel, (call) async { calls.add(call.method); return null; });
    final network = NetworkConnectivity();
    expect(await network.getAvailability(), isNull);
    expect(await network.availability.toList(), isEmpty);
    expect(calls, isEmpty);
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => throw PlatformException(code: 'detached'));
    expect(await network.getAvailability(), isNull);
    expect(await network.availability.toList(), isEmpty);
  });

  test('live network transitions deduplicate state and release monitoring on cancel', () async {
    final listening = Completer<void>();
    final calls = <String>[], states = <bool>[];
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => false);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'listen') listening.complete();
      return null;
    });
    Future<void> emit(Object? value) {
      final done = Completer<void>();
      messenger.handlePlatformMessage(NetworkConnectivity.events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(value), (_) => done.complete());
      return done.future;
    }
    final subscription = NetworkConnectivity().availability.listen(states.add);
    await listening.future.timeout(const Duration(seconds: 1));
    await emit(false); await emit(null); await emit(true); await emit(true); await emit(false);
    await Future<void>.delayed(Duration.zero);
    expect(states, [false, true, false]);
    await subscription.cancel();
    expect(calls, ['listen', 'cancel']);
  });

  test('native monitoring failures close the stream without overriding the last real state', () async {
    final listening = Completer<void>(), closed = Completer<void>();
    final states = <bool>[];
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => true);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final subscription = NetworkConnectivity().availability.listen(states.add, onDone: closed.complete);
    await listening.future.timeout(const Duration(seconds: 1));
    final sent = Completer<void>();
    messenger.handlePlatformMessage(NetworkConnectivity.events.name,
      const StandardMethodCodec().encodeErrorEnvelope(code: 'network_monitor_unavailable'), (_) => sent.complete());
    await sent.future; await closed.future.timeout(const Duration(seconds: 1));
    expect(states, [true]);
    await subscription.cancel();
  });

  test('overlapping readers keep monitoring until the final listener leaves', () async {
    final listening = Completer<void>();
    final calls = <String>[], first = <bool>[], second = <bool>[];
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (_) async => true);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final a = NetworkConnectivity().availability.listen(first.add);
    await listening.future.timeout(const Duration(seconds: 1));
    final b = NetworkConnectivity().availability.listen(second.add);
    await Future<void>.delayed(Duration.zero);
    await a.cancel();
    expect(calls, ['listen']);
    final sent = Completer<void>();
    messenger.handlePlatformMessage(NetworkConnectivity.events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(false), (_) => sent.complete());
    await sent.future; await Future<void>.delayed(Duration.zero);
    expect(second, [true, false]);
    await b.cancel();
    expect(calls, ['listen', 'cancel']);
  });

  test('a temporarily unknown native network still subscribes to later availability', () async {
    final listening = Completer<void>();
    final states = <bool>[];
    messenger.setMockMethodCallHandler(NetworkConnectivity.channel, (call) async =>
      call.method == 'isSupported' ? true : null);
    messenger.setMockMethodCallHandler(streamChannel, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final subscription = NetworkConnectivity().availability.listen(states.add);
    await listening.future.timeout(const Duration(seconds: 1));
    expect(states, isEmpty);
    final sent = Completer<void>();
    messenger.handlePlatformMessage(NetworkConnectivity.events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(false), (_) => sent.complete());
    await sent.future; await Future<void>.delayed(Duration.zero);
    expect(states, [false]);
    await subscription.cancel();
  });
}
