import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';

// Use the real HttpClient, WebSocket upgrade, masking and stream implementation.
// Only the destination is redirected: no credentials leave the loopback host.
class _LoopbackClient implements HttpClient {
  final HttpClient delegate;
  final Uri destination;
  final Completer<void>? closeGate;
  _HeldCloseSocket? heldSocket;
  _LoopbackClient(this.delegate, this.destination, {this.closeGate});
  @override bool get autoUncompress => delegate.autoUncompress;
  @override set autoUncompress(bool value) { delegate.autoUncompress = value; }
  @override Duration? get connectionTimeout => delegate.connectionTimeout;
  @override set connectionTimeout(Duration? value) { delegate.connectionTimeout = value; }
  @override Future<HttpClientRequest> getUrl(Uri url) async {
    final request = await delegate.getUrl(destination);
    if (closeGate == null) return request;
    return _HeldCloseRequest(request, closeGate!, (value) => heldSocket = value);
  }
  @override void close({bool force = false}) => delegate.close(force: force);
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected HTTP operation: ${invocation.memberName}');
}

class _HeldCloseRequest implements HttpClientRequest {
  final HttpClientRequest delegate;
  final Completer<void> gate;
  final void Function(_HeldCloseSocket) onSocket;
  _HeldCloseRequest(this.delegate, this.gate, this.onSocket);
  @override HttpHeaders get headers => delegate.headers;
  @override Future<HttpClientResponse> close() async =>
    _HeldCloseResponse(await delegate.close(), gate, onSocket);
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected held-close request operation: ${invocation.memberName}');
}

class _HeldCloseResponse implements HttpClientResponse {
  final HttpClientResponse delegate;
  final Completer<void> gate;
  final void Function(_HeldCloseSocket) onSocket;
  _HeldCloseResponse(this.delegate, this.gate, this.onSocket);
  @override int get statusCode => delegate.statusCode;
  @override Future<Socket> detachSocket() async {
    final socket = _HeldCloseSocket(await delegate.detachSocket(), gate);
    onSocket(socket); return socket;
  }
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected held-close response operation: ${invocation.memberName}');
}

// A real wire/socket and real WebSocket, with only the native close future held.
// This models delayed OS/TLS output shutdown independently of the peer's ACK:
// Dart versions need not wait for the peer ACK in WebSocket.close() itself.
class _HeldCloseSocket implements Socket {
  final Socket delegate;
  final Completer<void> gate;
  final closing = Completer<void>(), destroyed = Completer<void>();
  _HeldCloseSocket(this.delegate, this.gate);
  @override InternetAddress get address => delegate.address;
  @override InternetAddress get remoteAddress => delegate.remoteAddress;
  @override int get port => delegate.port;
  @override int get remotePort => delegate.remotePort;
  @override Encoding get encoding => delegate.encoding;
  @override set encoding(Encoding value) { delegate.encoding = value; }
  @override StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
    {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
    delegate.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override Future<void> addStream(Stream<List<int>> stream) => delegate.addStream(stream);
  @override void add(List<int> data) => delegate.add(data);
  @override void addError(Object error, [StackTrace? stackTrace]) => delegate.addError(error, stackTrace);
  @override Future<void> flush() => delegate.flush();
  @override Future<Socket> close() async {
    if (!closing.isCompleted) closing.complete();
    await gate.future; await delegate.close(); return this;
  }
  @override Future get done => delegate.done;
  @override void destroy() {
    delegate.destroy();
    if (!gate.isCompleted) gate.complete();
    if (!destroyed.isCompleted) destroyed.complete();
  }
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected held-close socket operation: ${invocation.memberName}');
}

class _TimedOutClient implements HttpClient {
  bool closed = false;
  @override bool autoUncompress = false;
  @override Duration? connectionTimeout;
  @override Future<HttpClientRequest> getUrl(Uri url) async => throw TimeoutException('test connection deadline');
  @override void close({bool force = false}) { closed = true; }
  @override dynamic noSuchMethod(Invocation invocation) =>
    throw StateError('Unexpected timeout HTTP operation: ${invocation.memberName}');
}

class _RawEdgeServer {
  final HttpServer server;
  final connected = Completer<void>();
  final ssmlReceived = Completer<void>();
  final closeRequested = Completer<void>();
  final disconnected = Completer<void>();
  final List<String> messages = [];
  final List<Socket> sockets = [];
  final List<StreamSubscription<dynamic>> subscriptions = [];
  FutureOr<void> Function(_RawEdgeServer server)? onSsml;
  late Socket socket;
  _RawEdgeServer._(this.server) {
    subscriptions.add(server.listen((request) { unawaited(_upgrade(request)); }));
  }
  static Future<_RawEdgeServer> create() async => _RawEdgeServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  Uri get uri => Uri(scheme: 'http', host: server.address.address, port: server.port, path: '/edge-test');

  Future<void> _upgrade(HttpRequest request) async {
    final key = request.headers.value('Sec-WebSocket-Key')!;
    request.response.statusCode = HttpStatus.switchingProtocols;
    request.response.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    request.response.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    request.response.headers.set('Sec-WebSocket-Accept', base64.encode(
      sha1.convert(utf8.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).bytes));
    socket = await request.response.detachSocket();
    sockets.add(socket);
    final buffered = <int>[];
    subscriptions.add(socket.listen((bytes) {
      buffered.addAll(bytes);
      while (buffered.length >= 2) {
        final opcode = buffered[0] & 0x0f;
        var length = buffered[1] & 0x7f, cursor = 2;
        if (length == 126) {
          if (buffered.length < 4) return;
          length = (buffered[2] << 8) | buffered[3]; cursor = 4;
        } else if (length == 127) {
          if (buffered.length < 10) return;
          length = 0;
          for (var i = 2; i < 10; i++) { length = (length << 8) | buffered[i]; }
          cursor = 10;
        }
        final masked = (buffered[1] & 0x80) != 0;
        if (buffered.length < cursor + (masked ? 4 : 0) + length) return;
        final mask = masked ? buffered.sublist(cursor, cursor + 4) : const <int>[];
        if (masked) cursor += 4;
        final payload = [for (var i = 0; i < length; i++) buffered[cursor + i] ^ (masked ? mask[i % 4] : 0)];
        buffered.removeRange(0, cursor + length);
        if (opcode == 8) {
          if (!closeRequested.isCompleted) closeRequested.complete();
          // Deliberately never acknowledge the WebSocket close frame.
        } else if (opcode == 1) {
          final message = utf8.decode(payload); messages.add(message);
          if (message.contains('Path:ssml') && !ssmlReceived.isCompleted) {
            ssmlReceived.complete();
            unawaited(Future<void>.sync(() => onSsml?.call(this)));
          }
        }
      }
    }, onDone: () { if (!disconnected.isCompleted) disconnected.complete(); },
      onError: (Object _) { if (!disconnected.isCompleted) disconnected.complete(); }));
    connected.complete();
  }

  void send(int opcode, List<int> payload) {
    final header = payload.length < 126 ? [0x80 | opcode, payload.length]
      : [0x80 | opcode, 126, payload.length >> 8, payload.length & 0xff];
    socket.add([...header, ...payload]);
  }
  void text(String value) => send(1, utf8.encode(value));
  void audio(List<int> bytes) {
    final header = utf8.encode('Path:audio\r\nContent-Type:audio/mpeg\r\n\r\n');
    send(2, [header.length >> 8, header.length & 0xff, ...header, ...bytes]);
  }
  Future<void> dispose() async {
    for (final socket in sockets) { socket.destroy(); }
    await server.close(force: true);
    await Future.wait(subscriptions.map((subscription) => subscription.cancel()));
  }
}

void main() {
  Future<Uint8List> speak(_RawEdgeServer server, {EdgeSynthCancelToken? token,
      void Function(List<SpeechWord>)? onWords}) {
    final delegate = HttpClient();
    return HttpOverrides.runZoned(() => edgeSynth('测试。', voice: 'zh-CN-YunxiNeural',
      rate: '+10%', cancelToken: token, onWords: onWords),
      createHttpClient: (_) => _LoopbackClient(delegate, server.uri));
  }

  test('complete audio is delivered at turn.end without waiting for a missing close acknowledgement', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    final sent = Completer<void>();
    const audio = [0xff, 0xfb, 0x90, 0x64, 1, 2, 3];
    server.onSsml = (peer) async {
      peer.audio(audio);
      peer.text('Path:audio.metadata\r\n\r\n${jsonEncode({'Metadata': [
        {'Type': 'WordBoundary', 'Data': {'Offset': 1000000, 'Duration': 2000000, 'text': {'Text': '测试'}}},
      ]})}');
      peer.text('Path:turn.end\r\n\r\n');
      await peer.socket.flush(); sent.complete();
    };
    List<SpeechWord>? words;
    final synthesis = speak(server, onWords: (value) => words = value);
    await sent.future.timeout(const Duration(seconds: 3));
    // The local peer intentionally leaves the close handshake unanswered.
    expect(await synthesis.timeout(const Duration(seconds: 1)), audio);
    expect(words!.single.text, '测试'); expect(words!.single.startMicros, 100000);
    expect(server.messages.where((m) => m.contains('Path:ssml')).single, contains("name='zh-CN-YunxiNeural'"));
    expect(server.messages.last, contains("rate='+10%'"));
    await server.closeRequested.future.timeout(const Duration(seconds: 1));
    // Background cleanup must eventually destroy TCP, not merely abandon the
    // close future after its timeout and leak the connection.
    await server.disconnected.future.timeout(const Duration(seconds: 3));
  });

  test('a slow native close future cannot hold completed audio and is force-released after its grace period', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    final sent = Completer<void>(), gate = Completer<void>();
    server.onSsml = (peer) async {
      peer.audio([7, 8, 9]); peer.text('Path:turn.end\r\n\r\n');
      await peer.socket.flush(); sent.complete();
    };
    final client = _LoopbackClient(HttpClient(), server.uri, closeGate: gate);
    final synthesis = HttpOverrides.runZoned(() => edgeSynth('测试。'), createHttpClient: (_) => client);
    await sent.future.timeout(const Duration(seconds: 3));
    expect(await synthesis.timeout(const Duration(seconds: 1)), [7, 8, 9],
      reason: 'The old foreground await of close() held these ready bytes until its two-second timeout.');
    await client.heldSocket!.closing.future.timeout(const Duration(seconds: 1));
    expect(gate.isCompleted, isFalse, reason: 'The native close is still pending after audio delivery.');
    await client.heldSocket!.destroyed.future.timeout(const Duration(seconds: 3));
    expect(gate.isCompleted, isTrue);
  });

  test('partial audio followed by disconnect cannot become successful or cacheable speech', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    server.onSsml = (peer) async {
      peer.audio([1, 2, 3]); await peer.socket.flush(); peer.socket.destroy();
    };
    var wordsPublished = false;
    await expectLater(speak(server, onWords: (_) => wordsPublished = true),
      throwsA(isA<EdgeTtsException>().having((error) => error.kind, 'kind', 'connection')));
    expect(wordsPublished, isFalse);
  });

  test('a turn.end string inside metadata cannot truncate the remaining audio', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    server.onSsml = (peer) async {
      peer.audio([1, 2]);
      peer.text('Path:audio.metadata\r\n\r\n{"comment":"Path:turn.end"}');
      peer.audio([3, 4]); peer.text('Path:turn.end\r\n\r\n');
      await peer.socket.flush();
    };
    expect(await speak(server), [1, 2, 3, 4]);
  });

  test('active cancellation interrupts a partial stream immediately and releases TCP', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    final sentPartial = Completer<void>(), token = EdgeSynthCancelToken();
    server.onSsml = (peer) async {
      peer.audio([1, 2, 3]); await peer.socket.flush(); sentPartial.complete();
    };
    var wordsPublished = false;
    final cancelled = expectLater(speak(server, token: token, onWords: (_) => wordsPublished = true),
      throwsA(isA<EdgeTtsException>().having((error) => error.kind, 'kind', 'cancelled')));
    await sentPartial.future.timeout(const Duration(seconds: 3)); token.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
    expect(wordsPublished, isFalse);
    await server.disconnected.future.timeout(const Duration(seconds: 1));
  });

  test('the synthesis watchdog rejects an unfinished stream and cleans up its socket', () async {
    final server = await _RawEdgeServer.create(); addTearDown(server.dispose);
    server.onSsml = (peer) async { peer.audio([1, 2, 3]); await peer.socket.flush(); };
    var wordsPublished = false;
    // Accelerate only the actual 20-second synthesis watchdog. HTTP deadlines
    // and the cleanup grace timer retain their production durations.
    final synthesis = runZoned(() => speak(server, onWords: (_) => wordsPublished = true),
      zoneSpecification: ZoneSpecification(createTimer: (self, parent, zone, duration, callback) =>
        parent.createTimer(zone, duration == const Duration(seconds: 20)
          ? const Duration(milliseconds: 50) : duration, callback)));
    await expectLater(synthesis,
      throwsA(isA<EdgeTtsException>().having((error) => error.kind, 'kind', 'timeout')));
    expect(wordsPublished, isFalse);
    await server.disconnected.future.timeout(const Duration(seconds: 1));
  });

  test('a connection timeout closes its HTTP client and retains the timeout error', () async {
    final client = _TimedOutClient();
    await expectLater(HttpOverrides.runZoned(() => edgeSynth('测试。'), createHttpClient: (_) => client),
      throwsA(isA<EdgeTtsException>().having((error) => error.kind, 'kind', 'timeout')));
    expect(client.closed, isTrue);
  });
}
