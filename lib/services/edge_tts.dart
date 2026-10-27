/// Edge TTS：调用微软 Edge 神经语音在线合成中文音频（MP3）。
/// 基于 edge-tts 7.2.8 协议逐项移植（已联网调研并核对 twn39/edgetts-dart 实现）。
///
/// 关键点（debug 排坑所得）：
/// - 必须手动 HttpClient upgrade 而非 WebSocket.connect（后者默认头被服务端 403）
/// - 握手请求头需完整（UA/Origin/Accept/Accept-Encoding/Accept-Language + Cookie: muid）
/// - SSML 消息必须带 X-RequestId 头，否则服务端 1002 关闭
/// - Sec-MS-GEC 为完整 64 位 SHA256 hex，且时钟偏差会导致 403，需 Date 头同步后重试
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String _secMsGecVersion = '2-143.0.3650.75';
const String _voiceList =
    'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=$_trustedClientToken';

/// 时钟偏差（秒），403 时通过服务器 Date 头校准
double _clockSkew = 0.0;

/// 可用中文音色
const List<String> edgeVoices = [
  'zh-CN-XiaoxiaoNeural', // 晓晓（女，温暖）
  'zh-CN-YunxiNeural', // 云希（男，阳光）
  'zh-CN-YunyangNeural', // 云扬（男，专业）
  'zh-CN-XiaoyiNeural', // 晓伊（女，活泼）
  'zh-CN-liaoning-XiaobeiNeural', // 东北话小北
  'zh-CN-shaanxi-XiaoniNeural', // 陕西话小妮
];

/// 当前 UTC Unix 时间戳 + 时钟偏差
double _nowUnix() =>
    (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0) + _clockSkew;

/// 生成 Sec-MS-GEC v2：`<CS64-16hex>-<SHA256-64hex>`（微软 2025 年底升级，
/// v1 纯 SHA256 + 版本号 1- 已被服务端 403 拒绝，edge-tts 7.3+ 使用本算法）
String _generateSecMsGec() => _generateSecMsGecV2(_nowUnix());

/// v2 核心（unix 时间戳可注入，供测试对照）
String generateSecMsGecV2(double unix) => _generateSecMsGecV2(unix);

String _generateSecMsGecV2(double unix) {
  var ticks = unix + 11644473600.0; // 1601 epoch
  ticks -= ticks % 300.0; // 5 分钟块
  ticks *= 10000000.0; // 100ns
  final strToHash = '${ticks.toStringAsFixed(0)}$_trustedClientToken';
  final data = ascii.encode(strToHash);
  final digest = _sha256Digest(data);
  final cs64 = _cs64Digest(data, digest);
  final cs64Hex = [
    for (var i = 0; i < 2; i++)
      _hex2(cs64[i] & 0xFF) +
          _hex2((cs64[i] >> 8) & 0xFF) +
          _hex2((cs64[i] >> 16) & 0xFF) +
          _hex2((cs64[i] >> 24) & 0xFF)
  ].join();
  final shaHex = digest.map(_hex2).join();
  return '$cs64Hex-$shaHex';
}

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

// ===================== Edge DRM v2：改良 SHA-256 + CS64 =====================
// 逐行移植自 edge-tts 7.3.x src/edge_tts/drm.py（非标准 SHA-256：第 15 轮常量
// 0x9BDC06A7 被替换为 0xC9DC06A7，且压缩函数为 d/h 累加变体，必须整体照抄）
const int _u32Mask = 0xFFFFFFFF;

const List<int> _sha256Initial = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];
const List<int> _sha256State = [
  0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
  0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
];
const List<int> _sha256Schedule = [
  0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
  0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
  0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
  0xD258B060, 0x72766564,
];
const List<int> _sha256RoundConstants = [
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
  0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
  0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
  0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
  0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
  0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
  0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
  0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
  0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];
const int _sha256Adjustment = 0xC9DC06A7;
List<int> get _sha256BlockConstants => [
      ..._sha256RoundConstants.sublist(0, 14),
      _sha256Adjustment,
      ..._sha256RoundConstants.sublist(15),
    ];
const int _sha256Sigma0Adjustment = 0x059C0B80;
const int _sha256Sigma1Adjustment = 0x000B92C0;

const List<List<int>> _cs64Coefficients = [
  [0xE82E91B1, 0xB32700D0],
  [0x44DE24C6, 0x88DFF51D],
  [0x3BEB65BC, 0x29514038],
  [0xC89C5933, 0xB328CBDF],
  [0x8D1EC211, 0xD405B4D5],
  [0x314EF5D5, 0x26E55F3C],
  [0xE92491B1, 0x607801C6],
  [0xF0A5B9D5, 0x82B2C1FB],
  [0x06064CF3, 0xFA51A3DA],
  [0xDA79FA60, 0x207CC464],
  [0xBED20560, 0x3C3C74F3],
  [0x89F9C9F8, 0xD2D14B61],
  [0x35FA38C6, 0xBB04A2C1],
  [0xCB49E3C6, 0xC5626167],
];
const int _cs64Factor = 0x82893933;
const int _cs64Adjustment0 = 0xF2F90B1A;
const int _cs64Adjustment1 = 0x0B1A0000;

int _mul32(int a, int b) => (a * b) & _u32Mask;

int _rol16(int value) => ((value << 16) | (value >> 16)) & _u32Mask;

List<int> _wordsLe4Even(List<int> data) {
  final padded = List<int>.from(data);
  while (padded.length % 4 != 0) {
    padded.add(0);
  }
  final words = <int>[];
  for (var i = 0; i < padded.length; i += 4) {
    words.add(
        padded[i] | (padded[i + 1] << 8) | (padded[i + 2] << 16) | (padded[i + 3] << 24));
  }
  if (words.length.isOdd) words.add(0);
  return words;
}

int _sigma0(int value) =>
    ((value >> 7) ^ (value << 25) ^ (value >> 18) ^ (value << 14) ^ (value >> 3)) &
        _u32Mask;

int _sigma1(int value) =>
    ((value >> 17) ^ (value << 15) ^ (value >> 19) ^ (value << 13) ^ (value >> 10)) &
        _u32Mask;

void _expandSha256Schedule(List<int> words, [int firstWord = 16]) {
  for (var index = firstWord; index < 64; index++) {
    final x = words[index - 2];
    final y = words[index - 15];
    final sigma1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10);
    final sigma0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3);
    words.add((sigma1 + words[index - 7] + sigma0 + words[index - 16]) & _u32Mask);
  }
}

int _rotr(int v, int n) => ((v >> n) | (v << (32 - n))) & _u32Mask;

int _bigSigma1(int v) => _rotr(v, 6) ^ _rotr(v, 11) ^ _rotr(v, 25);

int _bigSigma0(int v) => _rotr(v, 2) ^ _rotr(v, 13) ^ _rotr(v, 22);

List<int> _sha256Rounds(List<int> state, List<int> words, [int firstRound = 0]) {
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  final constants = firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;
  final aligned = min(64, ((firstRound + 7) ~/ 8) * 8);
  for (var index = firstRound; index < aligned; index++) {
    final t1 = (h + _bigSigma1(e) + (g ^ (e & (f ^ g))) + constants[index] + words[index]) & _u32Mask;
    final t2 = (_bigSigma0(a) + ((a & b) | (c & (a | b)))) & _u32Mask;
    final newA = (t1 + t2) & _u32Mask;
    final newE = (d + t1) & _u32Mask;
    h = g;
    g = f;
    f = e;
    e = newE;
    d = c;
    c = b;
    b = a;
    a = newA;
  }
  for (var index = aligned; index < 64; index += 8) {
    // 8 轮展开，逐行照抄 Python（d/h 累加变体压缩函数）
    var t1 = (h + _bigSigma1(e) + (g ^ (e & (f ^ g))) + constants[index] + words[index]) & _u32Mask;
    d = (d + t1) & _u32Mask;
    h = (t1 + _bigSigma0(a) + ((a & b) | (c & (a | b)))) & _u32Mask;
    t1 = (g + _bigSigma1(d) + (f ^ (d & (e ^ f))) + constants[index + 1] + words[index + 1]) & _u32Mask;
    c = (c + t1) & _u32Mask;
    g = (t1 + _bigSigma0(h) + ((h & a) | (b & (h | a)))) & _u32Mask;
    t1 = (f + _bigSigma1(c) + (e ^ (c & (d ^ e))) + constants[index + 2] + words[index + 2]) & _u32Mask;
    b = (b + t1) & _u32Mask;
    f = (t1 + _bigSigma0(g) + ((g & h) | (a & (g | h)))) & _u32Mask;
    t1 = (e + _bigSigma1(b) + (d ^ (b & (c ^ d))) + constants[index + 3] + words[index + 3]) & _u32Mask;
    a = (a + t1) & _u32Mask;
    e = (t1 + _bigSigma0(f) + ((f & g) | (h & (f | g)))) & _u32Mask;
    t1 = (d + _bigSigma1(a) + (c ^ (a & (b ^ c))) + constants[index + 4] + words[index + 4]) & _u32Mask;
    h = (h + t1) & _u32Mask;
    d = (t1 + _bigSigma0(e) + ((e & f) | (g & (e | f)))) & _u32Mask;
    t1 = (c + _bigSigma1(h) + (b ^ (h & (a ^ b))) + constants[index + 5] + words[index + 5]) & _u32Mask;
    g = (g + t1) & _u32Mask;
    c = (t1 + _bigSigma0(d) + ((d & e) | (f & (d | e)))) & _u32Mask;
    t1 = (b + _bigSigma1(g) + (a ^ (g & (h ^ a))) + constants[index + 6] + words[index + 6]) & _u32Mask;
    f = (f + t1) & _u32Mask;
    b = (t1 + _bigSigma0(c) + ((c & d) | (e & (c | d)))) & _u32Mask;
    t1 = (a + _bigSigma1(f) + (h ^ (f & (g ^ h))) + constants[index + 7] + words[index + 7]) & _u32Mask;
    e = (e + t1) & _u32Mask;
    a = (t1 + _bigSigma0(b) + ((b & c) | (d & (b | c)))) & _u32Mask;
  }
  return [a, b, c, d, e, f, g, h];
}

List<int> _sha256Init(List<int> data) {
  final mask = _u32Mask;
  final words = <int>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    (data[0] << 16) | (data[1] << 8) | data[2],
    (data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6],
  ];
  for (var index = 16; index < 30; index++) {
    var value = _sha256Schedule[index - 16];
    if (index - 2 >= 14) {
      value += (index == 16)
          ? (_sigma1(words[index - 2]) ^ _sha256Sigma1Adjustment)
          : _sigma1(words[index - 2]);
    }
    if (index - 7 >= 14) value += words[index - 7];
    if (index - 15 >= 14) {
      value += (index == 29)
          ? (_sigma0(words[index - 15]) ^ _sha256Sigma0Adjustment)
          : _sigma0(words[index - 15]);
    }
    words.add(value & mask);
  }
  words.add((_sigma1(words[28]) +
          words[23] +
          _sigma0(words[15]) +
          words[14] +
          _sha256Adjustment -
          _sha256RoundConstants[14]) &
      mask);
  _expandSha256Schedule(words, 31);
  final working = _sha256Rounds(_sha256State, words, 14);
  return [
    for (var i = 0; i < 8; i++) (_sha256Initial[i] + working[i]) & mask
  ];
}

/// 改良 SHA-256 摘要（首 7 字节 salt 参与初始状态计算）
Uint8List _sha256Digest(List<int> data) {
  final mask = _u32Mask;
  final length = 57 + data.length;
  final padded = <int>[...data.sublist(7), 0x80];
  var padCount = (55 - length) % 64;
  if (padCount < 0) padCount += 64;
  for (var i = 0; i < padCount; i++) {
    padded.add(0);
  }
  var bits = length * 8;
  final lenBytes = List<int>.filled(8, 0);
  for (var i = 7; i >= 0; i--) {
    lenBytes[i] = bits & 0xFF;
    bits >>= 8;
  }
  padded.addAll(lenBytes);
  var state = _sha256Init(data.sublist(0, 7));
  for (var offset = 0; offset < padded.length; offset += 64) {
    final words = <int>[];
    for (var i = 0; i < 64; i += 4) {
      words.add((padded[offset + i] << 24) |
          (padded[offset + i + 1] << 16) |
          (padded[offset + i + 2] << 8) |
          padded[offset + i + 3]);
    }
    _expandSha256Schedule(words);
    final working = _sha256Rounds(state, words);
    state = [for (var i = 0; i < 8; i++) (state[i] + working[i]) & mask];
  }
  final out = <int>[];
  for (final w in state) {
    out.add((w >> 24) & 0xFF);
    out.add((w >> 16) & 0xFF);
    out.add((w >> 8) & 0xFF);
    out.add(w & 0xFF);
  }
  return Uint8List.fromList(out);
}

int _le32(Uint8List digest, int offset) =>
    digest[offset] | (digest[offset + 1] << 8) | (digest[offset + 2] << 16) | (digest[offset + 3] << 24);

/// CS64 摘要：返回两个 u32（小端打包后为 16 hex）
List<int> _cs64Digest(List<int> data, Uint8List digest) {
  final mask = _u32Mask;
  var keyA = _le32(digest, 0) | 1;
  var keyB = _le32(digest, 4) | 1;
  final factorA = _mul32(keyA, _cs64Factor);
  final factorB = _mul32(keyB, _cs64Factor);
  final terms = <int>[];
  final offsets = <int>[];
  for (var i = 0; i < 14; i++) {
    final factor = (i % 2 == 0) ? factorA : factorB;
    terms.add(_mul32(_cs64Coefficients[i][0], factor));
    offsets.add(_cs64Coefficients[i][1]);
  }
  final words = _wordsLe4Even([0, ...data]);
  for (var index = 0; index < words.length; index++) {
    final word = words[index];
    var term = _mul32(word, (index % 2 == 0) ? keyA : keyB);
    var offset = _mul32(_rol16(word), (index % 2 == 0) ? 0xEF0569FB : 0xC31713DB);
    if (index == 0) {
      term = (term + _mul32(_cs64Adjustment0, factorA)) & mask;
      offset = (offset + _cs64Adjustment1) & mask;
    }
    terms.add(term & mask);
    offsets.add(offset & mask);
  }
  var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
  for (var index = 0; index < terms.length; index += 2) {
    final x = terms[index], y = terms[index + 1];
    var t = _rol16((offsets[index] + x) & mask);
    var q = _mul32(t, 0x76F50F34);
    swapAcc = (swapAcc + (_mul32(_rol16(q), 0xC3EFEA97) + q)) & mask;
    t = _rol16((offsets[index + 1] + y) & mask);
    q = _mul32(t, 0x1881CE3C);
    swapLast = (_mul32(_rol16(q), 0x35BD1EC9) + q) & mask;
    swapAcc = (swapAcc + swapLast) & mask;
    state = (state * keyA + x) & mask;
    state = _mul32(_rol16(state), 0xCF98B111);
    state = _mul32(_rol16(state), 0x87085B9F);
    state = _mul32(_rol16(state), 0x12CEB96D);
    state = _mul32(_rol16(state), 0x257E1D83);
    acc = (acc + state) & mask;
    t = (state * keyB + y) & mask;
    t = _mul32(_rol16(t), 0xA27416F5);
    t = _mul32(_rol16(t), 0xD38396FF);
    state = _mul32(_rol16(_mul32(_rol16(t), 0x7C932B89)), 0xBFA49F69);
    acc = (acc + state) & mask;
  }
  return [swapLast ^ state, swapAcc ^ acc];
}

/// 随机 MUID（握手 Cookie）
String _generateMuid() {
  final r = Random.secure();
  final values = List<int>.generate(16, (_) => r.nextInt(256));
  return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 32 位随机连接 ID
String _connectId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// JS 风格日期（speech.config 的 X-Timestamp）
String _jsDate() {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final t = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${weekdays[t.weekday - 1]} ${months[t.month - 1]} '
      '${two(t.day)} ${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}

/// ISO8601 毫秒 UTC（SSML 的 X-Timestamp，末尾由调用处补 Z）
String _isoTs() {
  final s = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${s.year}-${two(s.month)}-${two(s.day)}'
      'T${two(s.hour)}:${two(s.minute)}:${two(s.second)}.${three(s.millisecond)}';
}

/// 构建 WS 握手 headers
Map<String, String> _wssHeaders() {
  final headers = <String, String>{
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Sec-WebSocket-Version': '13',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
    'Accept': '*/*',
    'Accept-Encoding': 'gzip, deflate, br, zstd',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  headers['Cookie'] = 'muid=${_generateMuid()};';
  return headers;
}

/// 同步时钟偏差：GET voiceList 拿 Date 头
Future<void> _syncClock() async {
  try {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(_voiceList))
          .timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0');
      req.headers.set('Cookie', 'muid=${_generateMuid()};');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final date = res.headers.value(HttpHeaders.dateHeader);
      await res.drain<void>();
      if (date != null) {
        final server = HttpDate.parse(date).millisecondsSinceEpoch / 1000.0;
        _clockSkew = server - _nowUnix();
      }
    } finally {
      client.close();
    }
  } catch (_) {}
}

/// 合成单句文本为 MP3 字节。
/// 内部含一次 403 时钟同步重试。
Future<Uint8List> edgeSynth(String text,
    {String voice = 'zh-CN-XiaoxiaoNeural', String rate = '+0%'}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final result = await _synthOnce(text, voice: voice, rate: rate);
    if (result != null && result.isNotEmpty) return result;
    if (attempt == 0) {
      // 可能 403（时钟偏差）→ 同步时钟重试
      await _syncClock();
    }
  }
  return Uint8List(0);
}

/// 从音频二进制帧中提取 MP3 payload。
/// Edge TTS 音频帧格式：[2字节 big-endian headerLength][header 文本][音频数据]，
/// header 文本形如 "X-RequestId:...\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n\r\n"。
/// （与 twn39/edgetts-dart message_parser.parseBinaryMessage 一致；
///   注意二进制帧 payload 并非纯音频，之前按"纯音频"提取会把 header 混进 MP3 导致无声）
List<int> _extractAudioPayload(List<int> data) {
  if (data.length < 2) return data;
  final headerLength = (data[0] << 8) | data[1];
  if (data.length < headerLength + 2) return data;
  return data.sublist(2 + headerLength);
}

Future<Uint8List?> _synthOnce(String text,
    {required String voice, required String rate}) async {
  final connId = _connectId();
  final gec = _generateSecMsGec();
  final uri = Uri(
    scheme: 'https',
    host: 'speech.platform.bing.com',
    path: '/consumer/speech/synthesize/readaloud/edge/v1',
    queryParameters: {
      'TrustedClientToken': _trustedClientToken,
      'Sec-MS-GEC': gec,
      'Sec-MS-GEC-Version': _secMsGecVersion,
      'ConnectionId': connId,
    },
  );

  final client = HttpClient()..autoUncompress = false;
  client.connectionTimeout = const Duration(seconds: 15);
  WebSocket? ws;
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    _wssHeaders().forEach((k, v) {
      request.headers.set(k, v);
    });
    request.headers.set('Connection', 'Upgrade');
    request.headers.set('Upgrade', 'websocket');
    request.headers.set('Sec-WebSocket-Key',
        base64.encode(List<int>.generate(16, (_) => Random.secure().nextInt(256))));

    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 101) {
      await response.drain<void>();
      return null;
    }
    final detached = await response.detachSocket();
    ws = WebSocket.fromUpgradedSocket(detached, serverSide: false);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }

  final audioBuf = BytesBuilder();
  var gotAudio = false;
  final done = Completer<Uint8List?>();
  final timer = Timer(const Duration(seconds: 20), () {
    if (!done.isCompleted) done.complete(null);
  });

  void finish() {
    if (!done.isCompleted) done.complete(gotAudio ? audioBuf.toBytes() : null);
  }

  ws.listen(
    (data) {
      if (data is List<int>) {
        // 服务端二进制帧为纯音频 payload（无文本头），直接全部作为音频
        final audio = _extractAudioPayload(data);
        if (audio.isNotEmpty) {
          audioBuf.add(audio);
          gotAudio = true;
        }
      } else if (data is String) {
        if (data.contains('Path:turn.end')) {
          finish();
        }
      }
    },
    onDone: () {
      finish();
    },
    onError: (Object e) {
      finish();
    },
  );

  // 发送 speech.config
  final config = 'X-Timestamp:$_jsDate\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n';
  ws.add(config);

  // 发送 SSML（带 X-RequestId，否则服务端 1002 关闭）
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  final ssml = 'X-RequestId:$connId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${_isoTs()}Z\r\n'
      'Path:ssml\r\n\r\n'
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
      "<voice name='$voice'><prosody pitch='+0Hz' rate='$rate' volume='+0%'>"
      '$escaped</prosody></voice></speak>';
  ws.add(ssml);

  final result = await done.future;
  timer.cancel();
  try {
    await ws.close();
  } catch (_) {}
  return result;
}
