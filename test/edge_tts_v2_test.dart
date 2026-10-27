import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/edge_tts.dart';

void main() {
  test('v2 Sec-MS-GEC 与官方 edge-tts 7.3.1 输出一致（固定时间戳）', () {
    expect(
      generateSecMsGecV2(1780123456.0),
      'C4E909D87ED89746-2D6725FA379DA5CCFD38E340B86446947CB2DCD98E22306C96025DAC6070CB23',
    );
    expect(
      generateSecMsGecV2(1754000000.0),
      '2C258E9E63340210-086D4A5162A0692A74EB3DF446184A384A3B904E0C92401DDB105AD9A5648694',
    );
  });
}
