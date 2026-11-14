import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/tts_audio_handler.dart';

void main() {
  test('media cards expose standard sentence, play/pause and stop actions', () {
    final handler = TtsAudioHandler();
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
    handler.notifyPlaying();
    expect(handler.playbackState.value.controls.map((c) => c.action),
      [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.skipToNext, MediaAction.stop]);
    expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);
    expect(handler.playbackState.value.controls.map((c) => c.androidIcon),
      ['drawable/ic_media_previous', 'drawable/ic_media_pause', 'drawable/ic_media_next', 'drawable/ic_media_stop']);
    handler.notifyPaused();
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1].action, MediaAction.play);
    expect(handler.playbackState.value.controls[1].androidIcon, 'drawable/ic_media_play');
    expect(handler.playbackState.value.processingState, AudioProcessingState.ready);
    handler.notifyStopped();
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('metadata changes book and chapter without starting playback', () {
    final handler = TtsAudioHandler();
    handler.updateBookChapter(bookId: 'book-a', bookTitle: '书名', chapterTitle: '第一章', chapterIndex: 0);
    expect(handler.mediaItem.value!.title, '书名');
    expect(handler.mediaItem.value!.artist, '第一章');
    expect(handler.mediaItem.value!.displaySubtitle, isNull);
    expect(handler.mediaItem.value!.extras!.containsKey('spokenText'), isFalse);
    final firstId = handler.mediaItem.value!.id;
    handler.updateBookChapter(bookId: 'book-a', bookTitle: '书名', chapterTitle: '第二章', chapterIndex: 1);
    expect(handler.mediaItem.value!.id, isNot(firstId));
    expect(handler.mediaItem.value!.artist, '第二章');
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('spoken display text updates each sentence and is removed on disable or stop', () {
    final handler = TtsAudioHandler();
    void update([String? spokenText]) => handler.updateBookChapter(bookId: 'book-a', bookTitle: '书名',
      chapterTitle: '第一章', chapterIndex: 0, spokenText: spokenText);
    update('“你好——世界。”');
    expect(handler.mediaItem.value!.title, '书名'); expect(handler.mediaItem.value!.album, '书名');
    expect(handler.mediaItem.value!.artist, '“你好——世界。”');
    expect(handler.mediaItem.value!.displayTitle, '书名 · 第一章');
    expect(handler.mediaItem.value!.displaySubtitle, '“你好——世界。”');
    expect(handler.mediaItem.value!.displayDescription, '第一章');
    update('下一句，保留标点。');
    expect(handler.mediaItem.value!.artist, '下一句，保留标点。');
    expect(handler.mediaItem.value!.extras!['spokenText'], '下一句，保留标点。');
    update();
    expect(handler.mediaItem.value!.artist, '第一章');
    expect(handler.mediaItem.value!.displayTitle, isNull); expect(handler.mediaItem.value!.displaySubtitle, isNull);
    expect(handler.mediaItem.value!.displayDescription, isNull);
    expect(handler.mediaItem.value!.extras!.containsKey('spokenText'), isFalse);
    update('停止前的原句。'); handler.notifyStopped();
    expect(handler.mediaItem.value!.title, '书名'); expect(handler.mediaItem.value!.artist, '第一章');
    expect(handler.mediaItem.value!.displaySubtitle, isNull);
    expect(handler.mediaItem.value!.extras!.containsKey('spokenText'), isFalse);
  });

  test('play and pause await actual playback and coalesce repeated requests', () async {
    final handler = TtsAudioHandler();
    final started = Completer<void>(), resume = Completer<void>();
    var plays = 0, pauses = 0;
    handler.onPlayRequested = () async {
      if (handler.playbackState.value.playing) return;
      plays++; started.complete(); await resume.future; handler.notifyPlaying();
    };
    handler.onPauseRequested = () async {
      if (!handler.playbackState.value.playing) return;
      pauses++; handler.notifyPaused();
    };
    final first = handler.play();
    final repeated = handler.play();
    expect(identical(first, repeated), isTrue);
    await started.future;
    expect(handler.playbackState.value.playing, isFalse, reason: 'A request is not proof that audio started');
    resume.complete(); await first; await repeated;
    await handler.play();
    expect(plays, 1);
    await Future.wait([handler.pause(), handler.pause()]);
    await handler.pause();
    expect(pauses, 1);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('explicit play and pause reach the reader even when media state is stale', () async {
    final handler = TtsAudioHandler();
    var plays = 0, pauses = 0;
    handler.onPlayRequested = () async { plays++; };
    handler.onPauseRequested = () async { pauses++; };
    handler.notifyPlaying(); await handler.play();
    handler.notifyPaused(); await handler.pause();
    expect(plays, 1); expect(pauses, 1);
  });

  test('failed playback leaves the actual state and does not poison later commands', () async {
    final handler = TtsAudioHandler();
    handler.notifyPaused();
    handler.onPlayRequested = () async { throw StateError('Playback failed'); };
    await expectLater(handler.play(), throwsStateError);
    expect(handler.playbackState.value.playing, isFalse);
    handler.onPlayRequested = () async { handler.notifyPlaying(); };
    await handler.play();
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('sentence controls await their callbacks and notify does not invoke requests', () async {
    final handler = TtsAudioHandler();
    final called = <String>[];
    handler.onPreviousRequested = () async { called.add('previous'); };
    handler.onNextRequested = () async { called.add('next'); };
    handler.onStopRequested = () async { called.add('stop'); handler.notifyStopped(); };
    handler.notifyPlaying(); handler.notifyPaused(); handler.notifyPlaying();
    expect(called, isEmpty);
    await handler.skipToPrevious(); await handler.skipToNext(); await handler.stop();
    expect(called, ['previous', 'next', 'stop']);
    await handler.stop();
    expect(called, ['previous', 'next', 'stop']);
  });

  test('stop preempts a pending play and cancels queued commands', () async {
    final handler = TtsAudioHandler();
    final started = Completer<void>(), cancelled = Completer<void>();
    var stopped = false, nexts = 0;
    handler.onPlayRequested = () async {
      started.complete(); await cancelled.future;
      // The reader's generation check likewise prevents a cancelled play from
      // announcing playback after its stop request has completed.
      if (!stopped) handler.notifyPlaying();
    };
    handler.onNextRequested = () async { nexts++; };
    handler.onStopRequested = () async {
      stopped = true; handler.notifyStopped(); cancelled.complete();
    };
    final playing = handler.play(); await started.future;
    final queuedNext = handler.skipToNext();
    await handler.stop().timeout(const Duration(seconds: 1));
    await playing; await queuedNext;
    expect(stopped, isTrue);
    expect(nexts, 0);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('pause reaches a pending play and a later play can resume', () async {
    final handler = TtsAudioHandler();
    final started = Completer<void>(), cancelled = Completer<void>();
    var plays = 0, pauses = 0;
    handler.onPlayRequested = () async {
      plays++;
      if (plays == 1) { started.complete(); await cancelled.future; }
      else { handler.notifyPlaying(); }
    };
    handler.onPauseRequested = () async {
      pauses++; handler.notifyPaused(); cancelled.complete();
    };
    final firstPlay = handler.play(); await started.future;
    await handler.pause().timeout(const Duration(seconds: 1));
    await firstPlay;
    expect(pauses, 1); expect(handler.playbackState.value.playing, isFalse);
    await handler.play();
    expect(plays, 2); expect(handler.playbackState.value.playing, isTrue);
  });
}
