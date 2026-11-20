import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'fixtures/edge_tts_v126.dart' as legacy;

void main() {
  test('optional live online voice probe', () async {
    try {
      final previous = await legacy.edgeSynth('你好，这是语音连接测试。').timeout(const Duration(seconds: 40));
      print('v1.2.6 baseline: ${previous.length} audio bytes');
    } catch (error) { print('v1.2.6 baseline: ${error.runtimeType}'); }
    var words = 0;
    final audio = await edgeSynth('你好，这是语音连接测试。', onWords: (value) => words = value.length)
      .timeout(const Duration(seconds: 40));
    // Only fixed test text is sent. Do not log request headers or identifiers.
    print('Online voice probe: ${audio.length} audio bytes, $words word timestamps');
    expect(audio.length, greaterThan(500));
  }, skip: Platform.environment['DD_READER_LIVE_TTS'] != '1', timeout: const Timeout(Duration(seconds: 100)));
}
