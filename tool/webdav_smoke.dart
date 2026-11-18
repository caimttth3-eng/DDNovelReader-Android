// 协议冒烟：直接用 dart 跑（不经 flutter_test，避免 HttpOverrides 拦截）。
// 用法：dart run tool/webdav_smoke.dart http://127.0.0.1:8080/dav demo demo DDProbe
import 'dart:convert';
import 'dart:io';

import 'package:duoduo_langdu/services/webdav_client.dart';

Future<void> main(List<String> args) async {
  final server = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8080/dav';
  final user = args.length > 1 ? args[1] : 'demo';
  final pass = args.length > 2 ? args[2] : 'demo';
  final dir = args.length > 3 ? args[3] : 'DDProbe';

  final cli = WebDavClient(
    server: server,
    username: user,
    password: pass,
    remoteDir: dir,
    verifyTls: false,
  );
  final ok = <String>[];
  final fail = <String>[];

  void check(String name, bool cond, [Object? extra]) {
    (cond ? ok : fail).add('$name${extra == null ? '' : ' ($extra)'}');
  }

  // 1) MKCOL 逐级建目录
  await cli.mkdirs('v1/books');
  await cli.mkdirs('v1/devices');
  check('mkdirs', true);

  // 2) PUT 普通写（非原子）
  final payload = utf8.encode(jsonEncode({'k': '中文内容', 'n': 42}));
  await cli.put('v1/books/probe.json', payload, atomic: false);
  final back = await cli.get('v1/books/probe.json');
  check('put/get bytes', back != null && back.length == payload.length,
      '${back?.length} vs ${payload.length}');
  if (back != null) {
    final m = jsonDecode(utf8.decode(back)) as Map<String, dynamic>;
    check('put/get json 中文往返', m['k'] == '中文内容' && m['n'] == 42, m);
  }

  // 3) 原子写 .part + MOVE
  final payload2 = utf8.encode(jsonEncode({'k': '原子写', 'n': 7}));
  await cli.put('v1/books/probe2.json', payload2);
  final back2 = await cli.get('v1/books/probe2.json');
  check('atomic put/get', back2 != null && back2.length == payload2.length,
      '${back2?.length} vs ${payload2.length}');

  // 4) PROPFIND 列目录
  final entries = await cli.propfind('v1/books');
  final names = entries.map((e) => e.name).toList();
  check('propfind 列出 probe.json', names.contains('probe.json'), names);
  check('propfind 带 size',
      entries.any((e) => e.name == 'probe.json' && e.size > 0),
      entries.map((e) => '${e.name}:${e.size}').toList());

  // 5) 不存在返回 null
  check('get 404 -> null', await cli.get('v1/books/nope.json') == null);

  // 6) DELETE
  await cli.delete('v1/books/probe2.json');
  check('delete 生效', await cli.get('v1/books/probe2.json') == null);

  // 7) 鉴权失败
  final bad = WebDavClient(server: server, username: user, password: 'wrong',
      remoteDir: dir, verifyTls: false);
  try {
    await bad.propfind('v1/books');
    check('错误密码应 401', false);
  } on WebDavException catch (e) {
    check('错误密码应 401', e.status == 401, e.status);
  }

  stdout.writeln('PASS ${ok.length}');
  for (final s in ok) {
    stdout.writeln('  ok  $s');
  }
  if (fail.isNotEmpty) {
    stdout.writeln('FAIL ${fail.length}');
    for (final s in fail) {
      stdout.writeln('  FAIL $s');
    }
    exitCode = 1;
  }
  exit(exitCode);
}
