import 'package:audio_service/audio_service.dart';

typedef MediaPlaybackRequest = Future<void> Function();

/// Bridges standard Android notification, lock-screen and headset commands to
/// the reader. Only the reader reports actual playback state via notify methods;
/// a requested play that fails must never make the MediaSession look playing.
class TtsAudioHandler extends BaseAudioHandler {
  MediaPlaybackRequest? onPlayRequested;
  MediaPlaybackRequest? onPauseRequested;
  MediaPlaybackRequest? onStopRequested;
  MediaPlaybackRequest? onPreviousRequested;
  MediaPlaybackRequest? onNextRequested;

  Future<void> _commands = Future<void>.value();
  Future<void>? _lastRequest;
  String? _lastCommand;
  int _requestSerial = 0;
  int _commandEpoch = 0;
  Future<void>? _stopRequest;

  TtsAudioHandler() {
    mediaItem.add(const MediaItem(id: 'duoduo_langdu', title: '多多朗读'));
    _broadcast(playing: false, processingState: AudioProcessingState.idle);
  }

  /// Updates the media card without changing playback or reopening the book.
  void updateBookChapter({required String bookId, required String bookTitle,
    required String chapterTitle, int? chapterIndex}) {
    mediaItem.add(MediaItem(id: '$bookId:${chapterIndex ?? chapterTitle}',
      title: bookTitle, album: bookTitle, artist: chapterTitle,
      extras: {'bookId': bookId, if (chapterIndex != null) 'chapterIndex': chapterIndex}));
  }

  /// Commands are ordered, and identical consecutive in-flight requests share
  /// one operation. An error is returned to its caller without poisoning later
  /// media commands.
  Future<void> _enqueue(String name, Future<void> Function() operation) {
    if (_lastCommand == name && _lastRequest != null) return _lastRequest!;
    final serial = ++_requestSerial;
    final epoch = _commandEpoch;
    _lastCommand = name;
    final request = _commands.then((_) async {
      try { if (epoch == _commandEpoch) await operation(); }
      finally {
        if (_requestSerial == serial) { _lastCommand = null; _lastRequest = null; }
      }
    });
    _lastRequest = request;
    _commands = request.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return request;
  }

  @override
  Future<void> play() => _enqueue('play', () async {
    if (!playbackState.value.playing) await onPlayRequested?.call();
  });

  @override
  Future<void> pause() => _enqueue('pause', () async {
    if (playbackState.value.playing) await onPauseRequested?.call();
  });

  @override
  Future<void> stop() {
    if (_stopRequest != null) return _stopRequest!;
    final hadPendingCommand = _lastRequest != null;
    _commandEpoch++; _requestSerial++;
    _lastCommand = null; _lastRequest = null;
    // Stop must cancel a pending synthesis immediately, rather than wait behind
    // a play callback whose network request may take many seconds to finish.
    final request = Future<void>.sync(() async {
      if (hadPendingCommand || playbackState.value.processingState != AudioProcessingState.idle || playbackState.value.playing) {
        await onStopRequested?.call();
      }
    });
    _stopRequest = request;
    _commands = request.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _commands.then<void>((_) { if (identical(_stopRequest, request)) _stopRequest = null; });
    return request;
  }

  @override
  Future<void> skipToPrevious() => _enqueue('previous', () async { await onPreviousRequested?.call(); });

  @override
  Future<void> skipToNext() => _enqueue('next', () async { await onNextRequested?.call(); });

  void notifyPlaying() => _broadcast(playing: true, processingState: AudioProcessingState.ready);
  void notifyPaused() => _broadcast(playing: false, processingState: AudioProcessingState.ready);
  void notifyStopped() => _broadcast(playing: false, processingState: AudioProcessingState.idle);

  void _broadcast({required bool playing, required AudioProcessingState processingState}) {
    playbackState.add(playbackState.value.copyWith(
      playing: playing, processingState: processingState,
      controls: [MediaControl.skipToPrevious, playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext, MediaControl.stop],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {MediaAction.playPause},
    ));
  }
}

/// Shared MediaSession handler, initialized before the application starts.
TtsAudioHandler? globalAudioHandler;
