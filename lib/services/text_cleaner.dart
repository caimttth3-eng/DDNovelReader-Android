/// 一段文本的双层表示：
///  [display] 原始文本（保留标点、空白、颜文字），用于屏幕显示；
///  [tts] 清洗后的纯净文本（去除连续标点/空白/emoji/颜文字），用于 TTS 朗读。
///
/// 同时建立 tts 字符偏移 -> display 字符偏移 的映射，供朗读进度高亮定位。
class CleanedText {
  final String display;
  final String tts;

  /// 长度 = tts.length + 1。
  /// map[0] = 0（tts 第 0 个字符的 display 起点）；
  /// map[p] = tts 第 p 个字符对应的 display 起始位置（p 从 0 开始）；
  /// map[tts.length] = display.length（哨兵）。
  final List<int> ttsToDisplay;

  const CleanedText._(this.display, this.tts, this.ttsToDisplay);

  /// 将 tts 字符位置映射回 display 字符位置。
  /// [ttsPos] 是 tts 文本中第 N 个字符（0-based）。
  int displayOffsetOfTts(int ttsPos) {
    if (ttsPos <= 0) return 0;
    if (ttsPos >= ttsToDisplay.length) return display.length;
    return ttsToDisplay[ttsPos];
  }
}

/// 双文本清洗管线。
///
/// 规则：
///  1. 剔除 emoji（Unicode 表情符号区）与常见颜文字；
///  2. 连续空白（空格/制表/换行/全角空格）压缩为单个普通空格；
///  3. 连续标点压缩为单个标点（避免 TTS 因 "！！！"、"。。。" 等空读/卡顿）；
///  4. 移除孤立零宽与控制字符；
///  5. ASCII 标点归一为中文标点（更利于中文 TTS 断句）。
class TextCleaner {
  const TextCleaner();

  static final RegExp _emojiRe = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{2300}-\u{23FF}\u{1F1E6}-\u{1F1FF}]',
    unicode: true,
  );

  // 颜文字：括号内含特殊符号（数学符号/箭头/几何/平假名等）视为颜文字整段剔除。
  // 用 lookahead 要求括号内至少含一个非中日韩文字的特殊符号，避免误删「（你好）」。
  static final RegExp _kaomojiRe = RegExp(
    r'[（(](?=.*[\u2190-\u27BF\u3040-\u30FF\u3000-\u303F\uFF00-\uFFEF])[^)）\n]{1,16}[)）]',
  );

  static final RegExp _controlRe = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B\u200C\u200D\uFEFF\u2060]');

  /// 中文标点归一表
  static const Map<String, String> _norm = {
    '，': '，', '。': '。', '！': '！', '？': '？', '；': '；', '：': '：',
    '“': '“', '”': '”', '‘': '‘', '’': '’', '（': '（', '）': '）',
    '、': '、', '…': '…',
  };

  CleanedText clean(String source) {
    final display = source;
    final deEmoji = _removeEmojiKaomoji(display);

    // tts 字符序列 + 每个 tts 字符在 display 中的结束位置
    final chars = <String>[];
    final endPos = <int>[];

    var lastWasWs = false;
    var lastPunct = '';

    for (var i = 0; i < deEmoji.length; i++) {
      final ch = deEmoji[i];
      final cp = ch.runes.first;

      // 控制字符直接跳过
      if (_isControl(cp)) continue;

      // 空白：压缩为单个空格
      if (_isWhitespace(cp)) {
        if (!lastWasWs) {
          chars.add(' ');
          endPos.add(i + 1);
          lastWasWs = true;
        }
        lastPunct = '';
        continue;
      }

      // 标点：归一化 + 去重
      if (_isPunct(cp)) {
        final norm = _normalizePunct(ch);
        // 连续标点去重：仅当与前一个 tts 标点相同且中间无空白
        if (lastWasWs || norm != lastPunct) {
          chars.add(norm);
          endPos.add(i + 1);
          lastPunct = norm;
        }
        lastWasWs = false;
        continue;
      }

      // 常规文字
      chars.add(ch);
      endPos.add(i + 1);
      lastWasWs = false;
      lastPunct = '';
    }

    // trim 首尾空格
    var start = 0, end = chars.length;
    while (start < end && chars[start] == ' ') {
      start++;
    }
    while (end > start && chars[end - 1] == ' ') {
      end--;
    }

    final tts = chars.sublist(start, end).join();
    final map = <int>[0]; // map[0] = 0
    for (var k = start; k < end; k++) {
      map.add(endPos[k]);
    }
    // map 长度 = tts.length + 1；若 tts 为空则 map=[0]
    if (map.length == 1) map.add(display.length);

    return CleanedText._(display, tts, map);
  }

  String _removeEmojiKaomoji(String s) {
    return s
        .replaceAll(_emojiRe, '')
        .replaceAll(_controlRe, '')
        .replaceAll(_kaomojiRe, '');
  }

  bool _isControl(int cp) {
    return (cp < 0x20 && cp != 0x0A && cp != 0x0D) ||
        cp == 0x7F ||
        (cp >= 0x200B && cp <= 0x200D) ||
        cp == 0xFEFF ||
        cp == 0x2060;
  }

  bool _isWhitespace(int cp) {
    if (cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D) return true;
    if (cp == 0x3000) return true; // 全角空格
    if (cp >= 0x2000 && cp <= 0x200A) return true;
    return false;
  }

  bool _isPunct(int cp) {
    if (cp >= 0x2000 && cp <= 0x206F) return true;
    if (cp >= 0x3000 && cp <= 0x303F) return true;
    if (cp >= 0xFF00 && cp <= 0xFFEF) return true;
    if (cp >= 0x2010 && cp <= 0x2027) return true;
    if (cp >= 0x2030 && cp <= 0x205E) return true;
    if ((cp >= 0x21 && cp <= 0x2F) ||
        (cp >= 0x3A && cp <= 0x40) ||
        (cp >= 0x5B && cp <= 0x60) ||
        (cp >= 0x7B && cp <= 0x7E)) {
      return true;
    }
    return false;
  }

  String _normalizePunct(String ch) {
    switch (ch) {
      case ',':
        return '，';
      case '.':
        return '。';
      case '!':
        return '！';
      case '?':
        return '？';
      case ';':
        return '；';
      case ':':
        return '：';
      case '(':
        return '（';
      case ')':
        return '）';
      default:
        return _norm[ch] ?? ch;
    }
  }
}
