import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/webdav_client.dart';

typedef _Reply = Future<void> Function(HttpRequest request, List<int> body);
typedef _Request = ({String method, String path, String ifMatch,
  String ifNoneMatch, List<int> body});

/// Only this test's ephemeral loopback server is used. No saved credentials,
/// user server, external process or fixed listening port is involved.
class _DavFixture {
  final HttpServer server;
  final requests = <_Request>[];
  final errors = <Object>[];
  late final StreamSubscription<HttpRequest> subscription;
  _Reply reply = (request, body) async {};

  _DavFixture(this.server) {
    subscription = server.listen((request) async {
      try {
        final body = await request.fold<List<int>>(<int>[],
          (all, part) => all..addAll(part));
        requests.add((method: request.method, path: request.uri.path,
          ifMatch: request.headers.value(HttpHeaders.ifMatchHeader) ?? '',
          ifNoneMatch: request.headers.value(HttpHeaders.ifNoneMatchHeader) ?? '',
          body: body));
        await reply(request, body);
      } catch (error) {
        errors.add(error);
        request.response.statusCode = 500;
      } finally {
        await request.response.close();
      }
    });
  }

  static Future<_DavFixture> open() async =>
    _DavFixture(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  WebDavClient get client => WebDavClient(
    server: 'http://127.0.0.1:${server.port}', remoteDir: '',
    timeout: const Duration(seconds: 3));

  Future<void> close() async {
    await server.close(force: true);
    await subscription.cancel();
  }
}

Matcher _status(int status) => isA<WebDavException>()
  .having((error) => error.status, 'status', status);

void main() {
  late _DavFixture fixture;
  setUp(() async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    fixture = await _DavFixture.open();
    addTearDown(() async {
      await fixture.close();
      expect(fixture.errors, isEmpty, reason: 'The owned HTTP server must complete its responses');
    });
  });

  test('metadata GET captures bytes and strong ETag from the identical response', () async {
    fixture.reply = (request, body) async {
      request.response.headers.set(HttpHeaders.etagHeader, '"from-get-2"');
      request.response.write('{"progress_at":200}');
    };
    final response = await fixture.client.getWithMetadata('v1/books/a.json');
    expect(response.status, 200);
    expect(response.etag, '"from-get-2"');
    expect(utf8.decode(response.body), '{"progress_at":200}');
    expect(fixture.requests.map((request) => request.method), ['GET'],
      reason: 'A directory ETag or a second HEAD cannot validate these bytes');
  });

  test('true missing resource is 404 and legacy byte getter still returns null', () async {
    fixture.reply = (request, body) async { request.response.statusCode = 404; };
    final response = await fixture.client.getWithMetadata('v1/books/missing.json');
    expect(response.status, 404);
    expect(response.etag, isEmpty);
    expect(await fixture.client.get('v1/books/missing.json'), isNull);
  });

  test('conditional PUT propagates 412 without a temporary file, MOVE or fallback', () async {
    fixture.reply = (request, body) async { request.response.statusCode = 412; };
    await expectLater(fixture.client.put('v1/books/a.json', utf8.encode('local'), etag: '"old"'),
      throwsA(_status(412)));
    expect(fixture.requests, hasLength(1));
    expect(fixture.requests.single.method, 'PUT');
    expect(fixture.requests.single.path, '/v1/books/a.json');
    expect(fixture.requests.single.ifMatch, '"old"');
    expect(fixture.requests.single.ifNoneMatch, isEmpty);
    expect(utf8.decode(fixture.requests.single.body), 'local');
  });

  test('creation uses If-None-Match and cannot replace a concurrent creator', () async {
    List<int>? remote;
    fixture.reply = (request, body) async {
      if (request.method == 'GET') {
        request.response.statusCode = remote == null ? 404 : 200;
        if (remote != null) {
          request.response.headers.set(HttpHeaders.etagHeader, '"created"');
          request.response.add(remote!);
        }
      } else if (remote != null && request.headers.value(HttpHeaders.ifNoneMatchHeader) == '*') {
        request.response.statusCode = 412;
      } else {
        remote = List<int>.from(body);
        request.response.statusCode = 201;
      }
    };
    expect((await fixture.client.getWithMetadata('a.json')).status, 404);
    expect(await fixture.client.put('a.json', utf8.encode('first'), ifNoneMatch: true), isTrue);
    await expectLater(fixture.client.put('a.json', utf8.encode('second'), ifNoneMatch: true),
      throwsA(_status(412)));
    expect(utf8.decode(remote!), 'first');
    for (final request in fixture.requests.where((request) => request.method == 'PUT')) {
      expect(request.ifNoneMatch, '*');
      expect(request.ifMatch, isEmpty);
      expect(request.path, '/a.json');
    }
  });

  test('successive conflicts require a newly read ETag on every retry', () async {
    var revision = 1, attempted = 0;
    var remote = <String, dynamic>{'remoteRevision': revision};
    fixture.reply = (request, body) async {
      if (request.method == 'GET') {
        request.response.headers.set(HttpHeaders.etagHeader, '"v$revision"');
        request.response.write(jsonEncode(remote));
        return;
      }
      attempted++;
      if (attempted <= 2) {
        revision++;
        remote = {'remoteRevision': revision};
      }
      if (request.headers.value(HttpHeaders.ifMatchHeader) != '"v$revision"') {
        request.response.statusCode = 412;
        return;
      }
      remote = Map<String, dynamic>.from(jsonDecode(utf8.decode(body)) as Map);
      revision++;
      request.response.statusCode = 204;
    };
    for (var attempt = 0; attempt < 3; attempt++) {
      final snapshot = await fixture.client.getWithMetadata('a.json');
      final candidate = Map<String, dynamic>.from(jsonDecode(utf8.decode(snapshot.body)) as Map)
        ..['localBookmark'] = 'kept';
      try {
        await fixture.client.put('a.json', utf8.encode(jsonEncode(candidate)), etag: snapshot.etag);
        break;
      } on WebDavException catch (error) {
        expect(error.status, 412);
        expect(attempt, lessThan(2));
      }
    }
    expect(attempted, 3);
    expect(remote, {'remoteRevision': 3, 'localBookmark': 'kept'});
    final puts = fixture.requests.where((request) => request.method == 'PUT').toList();
    expect(puts.map((request) => request.ifMatch), ['"v1"', '"v2"', '"v3"']);
    expect(puts.every((request) => request.ifNoneMatch.isEmpty && request.path == '/a.json'), isTrue);
    expect(fixture.requests.map((request) => request.method), ['GET', 'PUT', 'GET', 'PUT', 'GET', 'PUT']);
  });

  test('weak, missing, malformed and injected ETags fail before opening a request', () async {
    for (final tag in ['', 'W/"weak"', 'unquoted', '*', ' "space"',
      '"line"\r\nInjected: value', '"line"\n', '"embedded"quote"', '"has space"']) {
      expect(WebDavClient.isStrongEtag(tag), isFalse, reason: tag);
      await expectLater(fixture.client.put('a.json', [1], etag: tag), throwsA(isA<WebDavException>()));
      await expectLater(fixture.client.delete('a.json', etag: tag), throwsA(isA<WebDavException>()));
    }
    for (final tag in ['""', '"revision-1.2"', '"a&b"']) {
      expect(WebDavClient.isStrongEtag(tag), isTrue);
    }
    await expectLater(fixture.client.put('a.json', [1], etag: '"a"', ifNoneMatch: true),
      throwsA(isA<WebDavException>()));
    expect(fixture.requests, isEmpty);
  });

  test('metadata GET rejects partial, empty-success and redirect responses', () async {
    for (final status in [202, 204, 206, 301, 302, 303, 304, 307, 308]) {
      fixture.reply = (request, body) async {
        request.response.statusCode = status;
        if (status >= 300 && status != 304) request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
      };
      await expectLater(fixture.client.getWithMetadata('a.json'), throwsA(_status(status)));
    }
    expect(fixture.requests, hasLength(9), reason: 'Unexpected redirects must not produce a second request');
    expect(fixture.requests.every((request) => request.path == '/a.json'), isTrue);
  });

  test('conditional PUT accepts only completed write statuses and never follows redirects', () async {
    for (final status in [202, 206, 207, 301, 302, 303, 307, 308]) {
      fixture.reply = (request, body) async {
        request.response.statusCode = status;
        if (status >= 300) request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
      };
      await expectLater(fixture.client.put('a.json', [1], etag: '"a"'), throwsA(_status(status)));
    }
    for (final status in [200, 201, 204]) {
      fixture.reply = (request, body) async { request.response.statusCode = status; };
      expect(await fixture.client.put('a.json', [1], etag: '"a"'), isTrue);
    }
    expect(fixture.requests, hasLength(11));
    expect(fixture.requests.every((request) => request.method == 'PUT' && request.path == '/a.json'), isTrue);
  });

  test('conditional DELETE preserves precondition failures while legacy delete remains boolean', () async {
    fixture.reply = (request, body) async { request.response.statusCode = 412; };
    await expectLater(fixture.client.delete('a.json', etag: '"old"'), throwsA(_status(412)));
    expect(fixture.requests.single.ifMatch, '"old"');
    fixture.reply = (request, body) async { request.response.statusCode = 204; };
    expect(await fixture.client.delete('a.json', etag: '"fresh"'), isTrue);
    for (final status in [202, 207, 302]) {
      fixture.reply = (request, body) async { request.response.statusCode = status; };
      await expectLater(fixture.client.delete('a.json', etag: '"fresh"'), throwsA(_status(status)));
    }
    fixture.reply = (request, body) async { request.response.statusCode = 500; };
    expect(await fixture.client.delete('a.json'), isFalse);
  });

  test('legacy atomic PUT still performs part upload and MOVE without conditions', () async {
    fixture.reply = (request, body) async {
      request.response.statusCode = request.method == 'PUT' ? 201 : 204;
    };
    expect(await fixture.client.put('a.json', utf8.encode('legacy')), isTrue);
    expect(fixture.requests.map((request) => request.method), ['PUT', 'MOVE']);
    expect(fixture.requests.map((request) => request.path), ['/a.json.part', '/a.json.part']);
    expect(fixture.requests.every((request) => request.ifMatch.isEmpty && request.ifNoneMatch.isEmpty), isTrue);
  });

  test('PROPFIND quoted validator decodes XML exactly once without weakening path checks', () {
    final entries = WebDavClient.parsePropfind('''
      <D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/v1/books/a.json</D:href>
      <D:propstat><D:prop><D:getetag>&quot;a&amp;b&quot;</D:getetag></D:prop>
      </D:propstat></D:response></D:multistatus>''', 'https://synthetic.invalid/dav/');
    expect(entries.single.etag, '"a&b"');
    expect(entries.single.rel, 'v1/books/a.json');
    final literal = WebDavClient.parsePropfind('''
      <response><href>/dav/a&amp;quot;b.json</href><getetag>&amp;quot;</getetag></response>''',
      'https://synthetic.invalid/dav/');
    expect(literal.single.etag, '&quot;');
    expect(literal.single.name, 'a&quot;b.json');
    expect(() => WebDavClient.parsePropfind('''
      <response><href>https://outside.invalid/dav/a.json</href></response>''',
      'https://synthetic.invalid/dav/'), throwsA(isA<WebDavException>()));
  });
}
