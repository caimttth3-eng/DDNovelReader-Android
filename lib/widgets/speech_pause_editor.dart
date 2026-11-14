import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../services/speech_breaks.dart';

enum SpeechPauseAction { currentVoice, global, resetGlobal }

@immutable
class SpeechPauseSelection {
  final SpeechPauseAction action;
  final SpeechPauseSettings pauses;
  final String voiceId;
  const SpeechPauseSelection(this.action, this.pauses, this.voiceId);
}

/// Edits a local draft; only the three explicit actions publish a selection.
/// Closing the containing sheet or collapsing this widget cannot persist it.
class SpeechPauseEditor extends StatefulWidget {
  final String voiceId;
  final SpeechPauseSettings initialPauses, globalPauses;
  final ValueChanged<SpeechPauseSelection> onApply;
  final bool initiallyExpanded;
  final String? title;
  const SpeechPauseEditor({super.key, required this.voiceId, required this.initialPauses,
    required this.globalPauses, required this.onApply, this.initiallyExpanded = false, this.title});

  @override
  State<SpeechPauseEditor> createState() => _SpeechPauseEditorState();
}

class _SpeechPauseEditorState extends State<SpeechPauseEditor> {
  late SpeechPauseSettings _draft = widget.initialPauses;
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant SpeechPauseEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.voiceId != widget.voiceId || oldWidget.initialPauses != widget.initialPauses) {
      _draft = widget.initialPauses;
    }
  }

  Widget _action({required Key key, required String label, required bool enabled,
    required SpeechPauseAction action, SpeechPauseSettings? pauses}) =>
    SizedBox(height: 48, child: FilledButton(key: key,
      style: FilledButton.styleFrom(minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 4)),
      onPressed: enabled ? () => widget.onApply(SpeechPauseSelection(action, pauses ?? _draft, widget.voiceId)) : null,
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 12)))));

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    ListTile(key: const ValueKey('pause-expand'),
      title: Text(widget.title ?? T('additionalPauses'), key: const ValueKey('pause-expand-label')),
      trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
      onTap: () => setState(() => _expanded = !_expanded)),
    if (_expanded) ...[
      Row(children: [
        Expanded(flex: 7, child: _action(key: const ValueKey('pause-apply'),
          label: T('applyPauseCurrentVoice'), enabled: _draft != widget.initialPauses,
          action: SpeechPauseAction.currentVoice)),
        const SizedBox(width: 6),
        Expanded(flex: 7, child: _action(key: const ValueKey('pause-apply-global'),
          label: T('applyPauseGlobalVoices'), enabled: _draft != widget.globalPauses,
          action: SpeechPauseAction.global)),
        const SizedBox(width: 6),
        Expanded(flex: 6, child: _action(key: const ValueKey('pause-reset-global'),
          label: T('restoreGlobalPauses'), enabled: widget.globalPauses != const SpeechPauseSettings(),
          action: SpeechPauseAction.resetGlobal, pauses: const SpeechPauseSettings())),
      ]),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(T('pauseDescription'))),
      for (final kind in SpeechPauseKind.values) Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          SizedBox(width: 48, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
            child: Text(T('pause-${kind.name}'), maxLines: 1, style: const TextStyle(fontSize: 14)))),
          SizedBox(width: 80, child: TextButton(key: ValueKey('pause-${kind.name}'),
            child: FittedBox(fit: BoxFit.scaleDown, child: Text(
              T('pauseSeconds', {'n': (_draft.millisecondsFor(kind) / 1000).toStringAsFixed(2)}),
              style: const TextStyle(fontSize: 14))),
            onPressed: () async {
              final value = await showDialog<int>(context: context, builder: (_) => _PauseSecondsInputDialog(
                title: T('pause-${kind.name}'), milliseconds: _draft.millisecondsFor(kind),
                inputKey: ValueKey('pause-number-${kind.name}')));
              if (value != null && mounted) setState(() => _draft = _draft.withPause(kind, value));
            })),
          Expanded(child: Slider(key: ValueKey('pause-slider-${kind.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            min: SpeechPauseSettings.minimum.toDouble(), max: SpeechPauseSettings.maximum.toDouble(),
            divisions: (SpeechPauseSettings.maximum - SpeechPauseSettings.minimum) ~/ SpeechPauseSettings.step,
            value: _draft.millisecondsFor(kind).toDouble(),
            onChanged: (value) => setState(() => _draft = _draft.withPause(kind, value.round())))),
        ])),
    ],
  ]);
}

class _PauseSecondsInputDialog extends StatefulWidget {
  final String title;
  final int milliseconds;
  final Key inputKey;
  const _PauseSecondsInputDialog({required this.title, required this.milliseconds, required this.inputKey});
  @override
  State<_PauseSecondsInputDialog> createState() => _PauseSecondsInputDialogState();
}

class _PauseSecondsInputDialogState extends State<_PauseSecondsInputDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: (widget.milliseconds / 1000).toStringAsFixed(2));
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, (double.parse(_controller.text) * 1000).round());
  }
  @override
  Widget build(BuildContext context) => AlertDialog(title: Text(widget.title),
    content: Form(key: _form, child: TextFormField(key: widget.inputKey, controller: _controller, autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [TextInputFormatter.withFunction((oldValue, newValue) =>
        RegExp(r'^\d*(?:\.\d{0,2})?$').hasMatch(newValue.text) ? newValue : oldValue)],
      decoration: InputDecoration(helperText: T('numberRange', {'n': '0.00', 'total': '3.00'}),
        suffixText: T('pauseSeconds', {'n': ''})),
      validator: (text) {
        final seconds = double.tryParse(text ?? '');
        return seconds == null || !seconds.isFinite || seconds < 0 || seconds > 3
          ? T('numberRange', {'n': '0.00', 'total': '3.00'}) : null;
      }, onFieldSubmitted: (_) => _submit())),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(T('cancel'))),
      FilledButton(onPressed: _submit, child: Text(T('ok')))]);
}
