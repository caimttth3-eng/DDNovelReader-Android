import 'package:flutter_test/flutter_test.dart';

import 'package:duoduo_langdu/services/updater.dart';

void main() {
  group('Updater.parseVersion', () {
    test('三段式', () {
      expect(Updater.parseVersion('1.2.3'), [1, 2, 3]);
    });
    test('v 前缀', () {
      expect(Updater.parseVersion('v1.2.3'), [1, 2, 3]);
      expect(Updater.parseVersion('V2.1.0'), [2, 1, 0]);
    });
    test('不足三段补 0', () {
      expect(Updater.parseVersion('1.2'), [1, 2, 0]);
      expect(Updater.parseVersion('2'), [2, 0, 0]);
    });
    test('历史格式取数字前缀（2.2v2）', () {
      expect(Updater.parseVersion('2.2v2'), [2, 2, 0]);
      expect(Updater.parseVersion('2.0V6c'), [2, 0, 0]);
    });
    test('非法输入归 0', () {
      expect(Updater.parseVersion(''), [0, 0, 0]);
      expect(Updater.parseVersion('abc'), [0, 0, 0]);
    });
  });

  group('Updater.compareVersion', () {
    test('大于', () {
      expect(Updater.compareVersion('1.2.3', '1.2.2'), 1);
      expect(Updater.compareVersion('2.0.0', '1.9.9'), 1);
    });
    test('等于', () {
      expect(Updater.compareVersion('1.2.2', '1.2.2'), 0);
      expect(Updater.compareVersion('v1.2.2', '1.2.2'), 0);
    });
    test('小于', () {
      expect(Updater.compareVersion('1.2.1', '1.2.2'), -1);
      expect(Updater.compareVersion('1.2.2', 'v1.3.0'), -1);
    });
  });
}
