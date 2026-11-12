/// Display-only break opportunities. Original text and speech coordinates stay
/// unchanged, including when punctuation starts a line.
class ReaderTypography {
  static final _punctuation = RegExp(r'''[，。！？；：、,.!?;:…）\]】》〉」』”’]''');
  static int leadingLength(String text) => RegExp(r'^[ \t\u3000]*').firstMatch(text)!.end;

  static String layout(String text, {bool paragraphStart = false}) {
    final leading = paragraphStart ? leadingLength(text) : 0;
    return '${leading > 0 ? '\uFFFC' : ''}${text.substring(leading).replaceAllMapped(_punctuation, (m) => '\u200B${m[0]}')}';
  }

  static int layoutOffset(String source, int offset) {
    offset = offset.clamp(0, source.length);
    final leading = leadingLength(source);
    if (offset < leading) return 0;
    var result = offset - leading + (leading > 0 ? 1 : 0);
    for (var i = 0; i < source.length && i <= offset; i++) {
      if (_punctuation.hasMatch(source[i])) result++;
    }
    return result;
  }

  static int sourceOffset(String source, int offset) {
    final leading = leadingLength(source);
    if (leading > 0 && offset <= 0) return 0;
    var rendered = leading > 0 ? 1 : 0;
    for (var i = leading; i < source.length; i++) {
      if (_punctuation.hasMatch(source[i])) rendered++;
      if (rendered >= offset) return i;
      rendered++;
    }
    return source.length;
  }
}
