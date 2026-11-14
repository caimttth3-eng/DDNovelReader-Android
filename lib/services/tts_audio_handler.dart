import 'package:audio_service/audio_service.dart';
import '../i18n.dart';

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
  Future<void>? _pauseRequest;
  ({String bookId, String bookTitle, String chapterTitle, int? chapterIndex})? _book;
  String? _spokenText;

  TtsAudioHandler() {
    mediaItem.add(const MediaItem(id: 'duoduo_langdu', title: '多多朗读'));
    _broadcast(playing: false, processingState: AudioProcessingState.idle);
  }

  /// Updates the media card without changing playback or reopening the book.
  void updateBookChapter({required String bookId, required String bookTitle,
    required String chapterTitle, int? chapterIndex, String? spokenText}) {
    _book = (bookId: bookId, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex);
    final text = spokenText != null && spokenText.trim().isNotEmpty ? spokenText : null;
    _spokenText = text;
    mediaItem.add(MediaItem(id: '$bookId:${chapterIndex ?? chapterTitle}',
      title: bookTitle, album: bookTitle, artist: text ?? chapterTitle,
      displayTitle: text == null ? null : '$bookTitle · $chapterTitle',
      displaySubtitle: text, displayDescription: text == null ? null : chapterTitle,
      extras: {'bookId': bookId, if (chapterIndex != null) 'chapterIndex': chapterIndex,
        if (text != null) 'spokenText': text}));
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
    // The reader owns the actual engine state and makes this request idempotent.
    // A stale MediaSession playing bit must not swallow an explicit resume.
    await onPlayRequested?.call();
  });

  @override
  Future<void> pause() {
    if (_pauseRequest != null) return _pauseRequest!;
    // A play callback can be awaiting synthesis. Pause must reach the reader
    // now so that it can cancel that work, rather than queue behind it.
    _commandEpoch++; _requestSerial++;
    _lastCommand = null; _lastRequest = null;
    final request = Future<void>.sync(() async { await onPauseRequested?.call(); });
    _pauseRequest = request;
    _commands = request.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _commands.then<void>((_) { if (identical(_pauseRequest, request)) _pauseRequest = null; });
    return request;
  }

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
  void notifyStopped() {
    final book = _book;
    if (_spokenText != null && book != null) {
      updateBookChapter(bookId: book.bookId, bookTitle: book.bookTitle,
        chapterTitle: book.chapterTitle, chapterIndex: book.chapterIndex);
    }
    _broadcast(playing: false, processingState: AudioProcessingState.idle);
  }

  void _broadcast({required bool playing, required AudioProcessingState processingState}) {
    playbackState.add(playbackState.value.copyWith(
      playing: playing, processingState: processingState,
      controls: [MediaControl(androidIcon: 'drawable/ic_media_previous', label: T('prev'), action: MediaAction.skipToPrevious),
        playing ? MediaControl(androidIcon: 'drawable/ic_media_pause', label: T('autoPagePause'), action: MediaAction.pause)
          : MediaControl(androidIcon: 'drawable/ic_media_play', label: T('read'), action: MediaAction.play),
        MediaControl(androidIcon: 'drawable/ic_media_next', label: T('next'), action: MediaAction.skipToNext),
        MediaControl(androidIcon: 'drawable/ic_media_stop', label: T('autoPageStop'), action: MediaAction.stop)],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {MediaAction.playPause},
    ));
  }
}

/// Shared MediaSession handler, initialized before the application starts.
TtsAudioHandler? globalAudioHandler;
