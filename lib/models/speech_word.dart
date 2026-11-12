import 'dart:convert';

class SpeechWord {
  final int startMicros;
  final int durationMicros;
  final int textStart;
  final int textEnd;
  final String text;
  const SpeechWord({required this.startMicros, required this.durationMicros,
    required this.textStart, required this.textEnd, required this.text});
  Map<String, dynamic> toJson() => {'startMicros': startMicros, 'durationMicros': durationMicros,
    'textStart': textStart, 'textEnd': textEnd, 'text': text};
  factory SpeechWord.fromJson(Map<String, dynamic> json) => SpeechWord(
    startMicros: json['startMicros'] as int, durationMicros: json['durationMicros'] as int,
    textStart: json['textStart'] as int, textEnd: json['textEnd'] as int, text: json['text'] as String);
}

/// Edge supplies 100 ns timing units and escaped words. Match each word in
/// order so repeated words keep their own coordinates. Unmatched metadata is
/// ignored instead of inventing a position.
class SpeechWordCollector {
  final String source;
  final List<SpeechWord> words = [];
  int _cursor = 0;
  SpeechWordCollector(this.source);

  void addMetadata(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      for (final raw in data['Metadata'] as List<dynamic>) {
        if (raw['Type'] != 'WordBoundary') continue;
        final wordData = raw['Data'];
        final encoded = wordData['text']['Text'] as String;
        final text = encoded.replaceAll('&lt;', '<').replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
        if (text.isEmpty) continue;
        final start = source.indexOf(text, _cursor);
        if (start < 0) continue;
        final ticks = wordData['Offset'] as num;
        final duration = wordData['Duration'] as num;
        if (ticks < 0 || duration <= 0) continue;
        words.add(SpeechWord(startMicros: ticks.toInt() ~/ 10, durationMicros: duration.toInt() ~/ 10,
          textStart: start, textEnd: start + text.length, text: text));
        _cursor = start + text.length;
      }
    } catch (_) { /* Audio remains usable if metadata is absent or malformed. */ }
  }
}

SpeechWord? speechWordAt(List<SpeechWord> words, Duration position) {
  final micros = position.inMicroseconds;
  var lo = 0, hi = words.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (words[mid].startMicros <= micros) { lo = mid + 1; } else { hi = mid; }
  }
  if (lo == 0) return null;
  final word = words[lo - 1];
  return micros < word.startMicros + word.durationMicros ? word : null;
}
