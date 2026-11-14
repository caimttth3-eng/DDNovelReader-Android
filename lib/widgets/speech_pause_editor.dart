import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
import '../services/speech_breaks.dart';

/// Edits a local system-voice draft; only Apply publishes the new settings.
/// Closing the containing sheet or collapsing this widget cannot persist it.
class SpeechPauseEditor extends StatefulWidget {
  final SpeechPauseSettings initialPauses;
  final ValueChanged<SpeechPauseSettings> onApply;
  final bool initiallyExpanded;
  final String? title;
  const SpeechPauseEditor({super.key, required this.initialPauses,
    required this.onApply, this.initiallyExpanded = false, this.title});

  @override
  State<SpeechPauseEditor> createState() => _SpeechPauseEditorState();
}

class _SpeechPauseEditorState extends State<SpeechPauseEditor> {
  late SpeechPauseSettings _draft = widget.initialPauses;
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant SpeechPauseEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPauses != widget.initialPauses) {
      _draft = widget.initialPauses;
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    ListTile(key: const ValueKey('pause-expand'),
      title: Text(widget.title ?? T('additionalPauses'), key: const ValueKey('pause-expand-label')),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_expanded) SizedBox(height: 48, child: FilledButton(key: const ValueKey('pause-apply'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 12)),
          onPressed: _draft == widget.initialPauses ? null : () => widget.onApply(_draft),
          child: Text(T('applyPauseSettings'), maxLines: 1))),
        Icon(_expanded ? Icons.expand_less : Icons.expand_more),
      ]),
      onTap: () => setState(() => _expanded = !_expanded)),
    if (_expanded) ...[
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
