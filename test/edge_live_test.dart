import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';
import 'package:duoduo_langdu/models/speech_word.dart';
import 'fixtures/edge_tts_v126.dart' as legacy;

void main() {
  test('optional online rate saturation characterization', () async {
    const text = '清晨的阳光照进窗户，桌上放着一本打开的书。今天我们用同一段文字核对不同语速，'
      '确保缓存、播放和词时间轴保持一致。读到这里以后，再停顿片刻，继续向前翻页。';
    for (final voice in ['zh-CN-XiaoxiaoNeural', 'zh-CN-YunxiNeural']) {
    final durations = <double>[];
    for (final rate in [1.0, 2.0, 3.0]) {
      var words = <SpeechWord>[];
      final audio = await edgeSynth(text, voice: voice, rate: edgeRateStr(rate), onWords: (value) => words = value)
        .timeout(const Duration(seconds: 40));
      final duration = _mp3Seconds(audio);
      expect(duration, greaterThan(0));
      expect(words, isNotEmpty);
      var previous = -1;
      for (final word in words) {
        expect(word.startMicros, greaterThanOrEqualTo(previous));
        expect(word.textStart, inInclusiveRange(0, text.length));
        expect(word.textEnd, inInclusiveRange(word.textStart, text.length));
        expect((word.startMicros + word.durationMicros) / 1000000, lessThanOrEqualTo(duration + 1.5));
        previous = word.startMicros;
      }
      durations.add(duration);
      print('Rate probe $voice $rate: ${duration.toStringAsFixed(3)} seconds, ${words.length} word ranges');
    }
    expect(durations[1], lessThan(durations[0] * 0.8));
    // Current service accepts +200% but saturates at the +100% audio speed.
    // A future change here is evidence to revisit the visible online limit.
    expect(durations[2], closeTo(durations[1], durations[1] * 0.05 + 0.1));
    }
  }, skip: !const bool.fromEnvironment('DD_READER_RATE_PROBE'),
    timeout: const Timeout(Duration(seconds: 260)));

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

// Sum MPEG Layer III frame durations; no player, decoder download or disk copy.
double _mp3Seconds(List<int> bytes) {
  const mpeg1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  const mpeg2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  var offset = 0;
  var seconds = 0.0;
  while (offset + 4 <= bytes.length) {
    final first = bytes[offset + 1], second = bytes[offset + 2];
    final version = (first >> 3) & 3, layer = (first >> 1) & 3;
    final rateIndex = (second >> 2) & 3, bitrateIndex = second >> 4;
    if (bytes[offset] != 255 || (first & 224) != 224 || version == 1 || layer != 1 ||
        rateIndex == 3 || bitrateIndex == 0 || bitrateIndex == 15) { offset++; continue; }
    final sampleRate = [44100, 48000, 32000][rateIndex] ~/ (version == 3 ? 1 : version == 2 ? 2 : 4);
    final bitrate = (version == 3 ? mpeg1 : mpeg2)[bitrateIndex] * 1000;
    final length = (version == 3 ? 144 : 72) * bitrate ~/ sampleRate + ((second >> 1) & 1);
    if (offset + length > bytes.length) break;
    seconds += (version == 3 ? 1152 : 576) / sampleRate;
    offset += length;
  }
  return seconds;
}
