import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_screen_awake.dart';

void main() {
  testWidgets('global overlay interactions reset only active foreground timers and ignore disposed controllers', (tester) async {
    final visibleWrites = <bool>[], backgroundWrites = <bool>[];
    final visible = ReaderScreenAwake(write: (v) async { visibleWrites.add(v); });
    final background = ReaderScreenAwake(write: (v) async { backgroundWrites.add(v); });
    visible.configure(timeout: const Duration(seconds: 60), active: true, foreground: true, scope: 'reading');
    background.configure(timeout: const Duration(seconds: 60), active: true, foreground: false, scope: 'voice');
    await tester.pump(const Duration(seconds: 50));
    ReaderScreenAwake.notifyUserInteraction();
    await tester.pump(const Duration(seconds: 50));
    expect(visibleWrites, [true]); expect(backgroundWrites, [false]);
    await tester.pump(const Duration(seconds: 10));
    expect(visibleWrites, [true, false]); expect(backgroundWrites, [false]);
    await visible.dispose();
    ReaderScreenAwake.notifyUserInteraction(); await tester.pump(const Duration(minutes: 2));
    expect(visibleWrites, [true, false]); expect(backgroundWrites, [false]);
    // The same registered controller remains eligible after entering foreground.
    background.configure(timeout: const Duration(seconds: 60), active: false, foreground: true, scope: 'voice');
    ReaderScreenAwake.notifyUserInteraction(); await tester.pump(const Duration(minutes: 2));
    expect(backgroundWrites, [false], reason: 'An inactive visible reader also ignores global touches');
    await background.dispose();
  });
  testWidgets('system mode adds no timeout override', (tester) async {
    final writes = <bool>[];
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); });
    awake.configure(timeout: null, active: true, foreground: true);
    awake.interaction(); await tester.pump(const Duration(hours: 2));
    await awake.settled; expect(writes, [false]);
    await awake.dispose();
  });
  testWidgets('touch resets the inactivity deadline and expiration only releases the hold', (tester) async {
    final writes = <bool>[];
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); });
    awake.configure(timeout: const Duration(minutes: 15), active: true, foreground: true);
    await tester.pump(const Duration(minutes: 10)); awake.interaction();
    await tester.pump(const Duration(minutes: 14)); expect(writes, [true]);
    await tester.pump(const Duration(minutes: 1)); await awake.settled;
    expect(writes, [true, false]);
    awake.interaction(); await tester.pump(); expect(writes, [true, false, true]);
    await awake.dispose(); expect(writes.last, false);
  });
  testWidgets('background cancels its timer and unlock starts a complete fresh visible deadline', (tester) async {
    final writes = <bool>[];
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); });
    awake.configure(timeout: const Duration(minutes: 15), active: true, foreground: true);
    await tester.pump(const Duration(minutes: 10));
    awake.configure(timeout: const Duration(minutes: 15), active: true, foreground: false);
    await tester.pump(); expect(writes, [true, false]);
    awake.interaction(); await tester.pump(const Duration(minutes: 60));
    awake.configure(timeout: const Duration(minutes: 15), active: true, foreground: true);
    await tester.pump(); expect(writes, [true, false, true]);
    await tester.pump(const Duration(minutes: 14)); expect(writes, [true, false, true]);
    await tester.pump(const Duration(minutes: 1)); expect(writes, [true, false, true, false]);
    await awake.dispose();
  });
  testWidgets('switching reading and voice scopes restarts even an equal timeout without sharing their deadlines', (tester) async {
    final writes = <bool>[];
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); });
    awake.configure(timeout: const Duration(minutes: 1), active: true, foreground: true, scope: 'reading');
    await tester.pump(const Duration(seconds: 50));
    awake.configure(timeout: const Duration(minutes: 1), active: true, foreground: true, scope: 'voice');
    await tester.pump(const Duration(seconds: 50)); expect(writes, [true]);
    await tester.pump(const Duration(seconds: 10)); expect(writes, [true, false]);
    awake.configure(timeout: null, active: true, foreground: true, scope: 'reading');
    await tester.pump(); expect(writes, [true, false]);
    await awake.dispose(); expect(writes, [true, false]);
  });
  testWidgets('a sixty-second reading hold expires and a voice pause uses system policy', (tester) async {
    final writes = <bool>[];
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); });
    awake.configure(timeout: const Duration(seconds: 60), active: true, foreground: true, scope: 'reading');
    await tester.pump(const Duration(seconds: 60)); expect(writes, [true, false]);
    awake.configure(timeout: const Duration(minutes: 15), active: true, foreground: true, scope: 'voice');
    await tester.pump(); expect(writes.last, true);
    awake.configure(timeout: null, active: true, foreground: true, scope: 'voice');
    await tester.pump(); expect(writes.last, false);
    await awake.dispose();
  });
  testWidgets('a release is serialized after an in-flight native write', (tester) async {
    final writes = <bool>[], first = Completer<void>();
    final awake = ReaderScreenAwake(write: (v) async { writes.add(v); if (v) await first.future; });
    awake.configure(timeout: const Duration(minutes: 1), active: true, foreground: true);
    await tester.pump(); final disposed = awake.dispose();
    expect(writes, [true]); first.complete(); await disposed;
    expect(writes, [true, false]);
  });
}
