import 'dart:async';

import 'package:duoduo_langdu/screens/reader_screen.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // FakeAsync advances virtual frames without servicing a real isolate's IO.
  // Run the identical numerical callback deterministically in widget tests;
  // worker transport is exercised separately under runAsync.
  ReaderScreen.jointWorkerForTesting = (solve) async => solve();
  await testMain();
}
