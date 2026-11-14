/// Extra silence after the voice engine's own natural punctuation prosody.
enum SpeechPauseKind { enumerationComma, comma, semicolon, colon, period,
  question, exclamation, ellipsis, dash, paragraph }

class SpeechPauseSettings {
  static const minimum = 0, maximum = 3000, step = 50;
  final Map<SpeechPauseKind, int> _values;
  const SpeechPauseSettings() : _values = const {};
  SpeechPauseSettings._(Map<SpeechPauseKind, int> values) : _values = Map.unmodifiable(values);
  int millisecondsFor(SpeechPauseKind kind) => _values[kind] ?? (kind == SpeechPauseKind.dash ? 300 : 0);
  static int _normalize(num value) => ((value.clamp(minimum, maximum) / step).round() * step);
  SpeechPauseSettings withPause(SpeechPauseKind kind, int milliseconds) =>
    SpeechPauseSettings._({..._values, kind: _normalize(milliseconds)});
  factory SpeechPauseSettings.fromJson(dynamic json) {
    if (json is! Map || (json['version'] != null && json['version'] != 1)) return const SpeechPauseSettings();
    final values = <SpeechPauseKind, int>{};
    for (final kind in SpeechPauseKind.values) {
      final value = json[kind.name];
      if (value is num && value.isFinite) values[kind] = _normalize(value);
    }
    return SpeechPauseSettings._(values);
  }
  Map<String, dynamic> toJson() => {'version': 1,
    for (final kind in SpeechPauseKind.values) kind.name: millisecondsFor(kind)};
  String get cacheKey => 'pause1:${SpeechPauseKind.values.map(millisecondsFor).join(',')}';
  @override
  bool operator ==(Object other) => other is SpeechPauseSettings && cacheKey == other.cacheKey;
  @override
  int get hashCode => cacheKey.hashCode;
}

class SpeechBreak {
  final int end, milliseconds;
  const SpeechBreak(this.end, this.milliseconds);
}

/// UTF-16 end offsets include trailing closing quotes. Adjacent punctuation
/// forms one boundary, using its longest configured pause rather than a sum.
class SpeechBreaks {
  static final _runs = RegExp(r'''[、，,；;：:。！？!?….\u2014\u2015]+[”’」』）》）\]"']*''');
  static final _digit = RegExp(r'[0-9０-９]');
  static Iterable<SpeechBreak> boundaries(String text, SpeechPauseSettings settings) sync* {
    for (final match in _runs.allMatches(text)) {
      var pause = 0;
      final run = match.group(0)!;
      void include(SpeechPauseKind kind) {
        final value = settings.millisecondsFor(kind);
        if (value > pause) pause = value;
      }
      for (var i = 0; i < run.length; i++) {
        final at = match.start + i;
        final withinNumber = at > 0 && at + 1 < text.length &&
          _digit.hasMatch(text[at - 1]) && _digit.hasMatch(text[at + 1]);
        switch (run[i]) {
          case '、': include(SpeechPauseKind.enumerationComma);
          case '，': case ',': if (!withinNumber) include(SpeechPauseKind.comma);
          case '；': case ';': include(SpeechPauseKind.semicolon);
          case '：': case ':': if (!withinNumber) include(SpeechPauseKind.colon);
          case '。': include(SpeechPauseKind.period);
          case '？': case '?': include(SpeechPauseKind.question);
          case '！': case '!': include(SpeechPauseKind.exclamation);
          case '…': include(SpeechPauseKind.ellipsis);
          case '—': case '―': include(SpeechPauseKind.dash);
          case '.':
            if (run.contains('..')) {
              include(SpeechPauseKind.ellipsis);
            } else {
              if (!withinNumber) include(SpeechPauseKind.period);
            }
        }
      }
      if (pause > 0) yield SpeechBreak(match.end, pause);
    }
  }
  static int maxPause(String text, SpeechPauseSettings settings) {
    var result = 0;
    for (final boundary in boundaries(text, settings)) {
      if (boundary.milliseconds > result) result = boundary.milliseconds;
    }
    return result;
  }
}
