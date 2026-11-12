import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';

void main() {
  test('optional live online voice probe', () async {
    var words = 0;
    final audio = await edgeSynth('你好，这是语音连接测试。', onWords: (value) => words = value.length)
      .timeout(const Duration(seconds: 40));
    // Only fixed test text is sent. Do not log request headers or identifiers.
    print('Online voice probe: ${audio.length} audio bytes, $words word timestamps');
    expect(audio.length, greaterThan(500));
  }, skip: Platform.environment['DD_READER_LIVE_TTS'] != '1');
}
