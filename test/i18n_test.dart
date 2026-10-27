import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duoduo_langdu/i18n.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';

void main() {
  group('AppLang.detect 系统语言匹配', () {
    test('zh-CN → 简体', () {
      expect(AppLang.detect(const [Locale('zh', 'CN')]), AppLang.zhHans);
    });
    test('zh → 简体（无地区）', () {
      expect(AppLang.detect(const [Locale('zh')]), AppLang.zhHans);
    });
    test('zh-Hans → 简体（显式脚本）', () {
      expect(AppLang.detect(const [Locale('zh', 'CN')]), AppLang.zhHans);
    });
    test('zh-TW → 繁体', () {
      expect(AppLang.detect(const [Locale('zh', 'TW')]), AppLang.zhHant);
    });
    test('zh-HK → 繁体', () {
      expect(AppLang.detect(const [Locale('zh', 'HK')]), AppLang.zhHant);
    });
    test('zh-Hant 脚本 → 繁体', () {
      expect(AppLang.detect(const [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')]), AppLang.zhHant);
    });
    test('en-US → 英语', () {
      expect(AppLang.detect(const [Locale('en', 'US')]), AppLang.en);
    });
    test('ja-JP → 日语', () {
      expect(AppLang.detect(const [Locale('ja', 'JP')]), AppLang.ja);
    });
    test('ko-KR → 韩语', () {
      expect(AppLang.detect(const [Locale('ko', 'KR')]), AppLang.ko);
    });
    test('多语言列表按顺序取第一个匹配', () {
      expect(
        AppLang.detect(const [Locale('fr', 'FR'), Locale('ja', 'JP')]),
        AppLang.ja,
      );
    });
    test('不匹配语言（fr）→ 默认英语', () {
      expect(AppLang.detect(const [Locale('fr', 'FR')]), AppLang.en);
    });
    test('空列表 → 默认英语', () {
      expect(AppLang.detect(const []), AppLang.en);
    });
  });

  group('翻译表完整性', () {
    test('5 语言 key 集合一致', () {
      final keys = <String>[];
      for (final lang in AppLang.values) {
        final k = AppI18n.tableFor(lang).keys.toSet();
        if (keys.isEmpty) {
          keys.addAll(k);
        } else {
          expect(k, keys, reason: '${lang.name} 的 key 集合与基准不一致');
        }
      }
      expect(keys.length, greaterThan(40));
    });

    test('每个 key 在 5 语言都有非空值且占位符参数名合法', () {
      const knownParams = {
        'n', 'pct', 'rate', 'm', 'c', 'total', 'idx', 'q', 'ver', 'err',
        'text', 'title', 'name',
      };
      for (final lang in AppLang.values) {
        for (final e in AppI18n.tableFor(lang).entries) {
          expect(e.value.trim().isNotEmpty, isTrue,
              reason: '${lang.name}/${e.key} 为空');
          final re = RegExp(r'\{(\w+)\}');
          for (final m in re.allMatches(e.value)) {
            expect(knownParams.contains(m.group(1)), isTrue,
                reason: '${lang.name}/${e.key} 使用了未知占位符 {${m.group(1)}}');
          }
        }
      }
    });

    test('T() 按当前语言返回', () {
      AppI18n.current = AppLang.en;
      expect(T('read'), 'Read');
      AppI18n.current = AppLang.ja;
      expect(T('read'), '読み上げ');
      AppI18n.current = AppLang.ko;
      expect(T('read'), '읽기');
      AppI18n.current = AppLang.zhHant;
      expect(T('read'), '朗讀');
      AppI18n.current = AppLang.zhHans;
      expect(T('read'), '朗读');
    });

    test('T() 参数替换', () {
      AppI18n.current = AppLang.en;
      expect(T('timerAfter', {'m': '30'}), 'Stop after 30 min');
      AppI18n.current = AppLang.zhHans;
      expect(T('timerAfter', {'m': '30'}), '30 分钟后停止');
    });

    test('未知 key 回退到 key 原文', () {
      expect(T('no_such_key'), 'no_such_key');
    });
  });

  group('sortedEdgeVoices 默认语言置顶', () {
    test('简体界面：zh-CN 组置顶', () {
      AppI18n.current = AppLang.zhHans;
      final v = sortedEdgeVoices();
      expect(v.first.langCode, 'zh-CN');
      // 组顺序：zh-CN → zh-TW → en → ja-JP → ko-KR
      final order = v.map((e) => e.langCode).toList();
      final zhTwIdx = order.indexOf('zh-TW');
      final enIdx = order.indexOf('en');
      final jaIdx = order.indexOf('ja-JP');
      final koIdx = order.indexOf('ko-KR');
      expect(zhTwIdx, greaterThan(0));
      expect(enIdx, greaterThan(zhTwIdx));
      expect(jaIdx, greaterThan(enIdx));
      expect(koIdx, greaterThan(jaIdx));
      // 组内音色数符合预期
      expect(order.where((c) => c == 'zh-CN').length, 7);
      expect(order.where((c) => c == 'zh-TW').length, 3);
      expect(order.where((c) => c == 'en').length, 6);
      expect(order.where((c) => c == 'ja-JP').length, 2);
      expect(order.where((c) => c == 'ko-KR').length, 2);
    });

    test('英语界面：en 组置顶', () {
      AppI18n.current = AppLang.en;
      final v = sortedEdgeVoices();
      expect(v.first.langCode, 'en');
      expect(v.where((e) => e.langCode == 'en').first.id, 'en-US-AriaNeural');
    });

    test('日语界面：ja-JP 组置顶', () {
      AppI18n.current = AppLang.ja;
      expect(sortedEdgeVoices().first.langCode, 'ja-JP');
    });

    test('韩语界面：ko-KR 组置顶', () {
      AppI18n.current = AppLang.ko;
      expect(sortedEdgeVoices().first.langCode, 'ko-KR');
    });

    test('繁体界面：zh-TW 组置顶', () {
      AppI18n.current = AppLang.zhHant;
      expect(sortedEdgeVoices().first.langCode, 'zh-TW');
    });

    test('音色 id 全局唯一', () {
      final ids = edgeVoices.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });
}
