import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/annotation_store.dart';
import '../services/app_appearance.dart';
import '../services/app_storage.dart';
import '../services/sync_engine.dart';

/// Shared preview and target checks for the library and reader entrypoints.
class SyncActionPreview {
  static bool sameTarget(Map<String, dynamic> left, Map<String, dynamic> right) {
    Object? value(Map<String, dynamic> settings, String key) {
      if (key == SyncEngine.cfgVerifyTls) return settings[key] ?? true;
      final text = settings[key] as String? ?? '';
      if (key == SyncEngine.cfgPass) return text;
      if (key == SyncEngine.cfgDir && text.trim().isEmpty) return SyncEngine.remoteDirDefault;
      return text.trim();
    }
    return [SyncEngine.cfgServer, SyncEngine.cfgUser, SyncEngine.cfgPass,
      SyncEngine.cfgDir, SyncEngine.cfgVerifyTls].every((key) => value(left, key) == value(right, key));
  }

  static String label(String mode) => T(switch (mode) {
    'push' => 'syncPush', 'pull' => 'syncPull', _ => 'syncRun',
  });

  static String description(SyncReport report) {
    final lines = <String>[];
    void add(String key, int count) {
      if (count > 0) lines.add(T(key, {'n': '$count'}));
    }
    if (report.mode != 'pull') {
      add('syncWillPush', report.pushed);
      add('syncWillDelete', report.deleted);
      add('syncWillUploadSource', report.sourceUploaded);
    }
    if (report.mode != 'push') {
      add('syncWillPull', report.pulled);
      add('syncWillImport', report.imported);
      add('syncWillRemove', report.removed);
      add('syncWillRecordDeletion', report.deletionUpdates);
    }
    if (lines.isEmpty && report.hasChanges) lines.add(T('syncWillReconcile'));
    if (report.remoteOnly.isNotEmpty) lines.add(T('syncRemoteOnly', {'n': '${report.remoteOnly.length}'}));
    lines.add(T('syncPreviewNotice'));
    return lines.join('\n');
  }

  static Future<bool> confirm(BuildContext context, SyncReport report, {ThemeData? theme}) async =>
    await showDialog<bool>(context: context, builder: (dialog) => Theme(
      data: theme ?? AppAppearance.menuTheme(Theme.of(dialog)),
      child: AlertDialog(key: const ValueKey('sync-preview'),
        title: Text(label(report.mode)),
        content: Text(description(report)),
        actions: [
          TextButton(key: const ValueKey('sync-preview-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false), child: Text(T('cancel'))),
          FilledButton(key: const ValueKey('sync-preview-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true), child: Text(T('syncContinue'))),
        ]))) == true;
}

/// 数据同步（WebDAV）。与 PC 版「设置 → 数据同步」同一套协议：
/// 远端 v1/books/<content_key>.json、v1/devices/<device_id>.json、v1/meta.json。
/// 同步书架、进度、书签、书源文件和删除记录；音频缓存不上传。
class SyncScreen extends StatefulWidget {
  final AppStorage storage;
  final AnnotationStore annotations;
  final VoidCallback? onSynced;
  final SyncEngine? syncEngine;

  const SyncScreen({
    super.key,
    required this.storage,
    required this.annotations,
    this.onSynced,
    this.syncEngine,
  });

  static Future<void> show(
    BuildContext context, {
    required AppStorage storage,
    required AnnotationStore annotations,
    VoidCallback? onSynced,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => SyncScreen(
        storage: storage,
        annotations: annotations,
        onSynced: onSynced,
      ),
    );
  }

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  ColorScheme get _colors => Theme.of(context).colorScheme;

  final _serverCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _dirCtl = TextEditingController();

  bool _auto = true;
  bool _verifyTls = true;
  bool _busy = false;
  String _status = '';
  double _lastTime = 0;

  late final SyncEngine _engine =
      widget.syncEngine ?? SyncEngine(storage: widget.storage, annotations: widget.annotations);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [_serverCtl, _userCtl, _passCtl, _dirCtl]) { controller.dispose(); }
    super.dispose();
  }

  Future<void> _load() async {
    final s = await _engine.settings();
    if (!mounted) return;
    setState(() {
      _serverCtl.text = s[SyncEngine.cfgServer] as String? ?? '';
      _userCtl.text = s[SyncEngine.cfgUser] as String? ?? '';
      _passCtl.text = s[SyncEngine.cfgPass] as String? ?? '';
      _dirCtl.text = (s[SyncEngine.cfgDir] as String? ?? '').trim().isEmpty
          ? SyncEngine.remoteDirDefault
          : s[SyncEngine.cfgDir] as String;
      _auto = (s[SyncEngine.cfgAuto] as bool?) ?? true;
      _verifyTls = (s[SyncEngine.cfgVerifyTls] as bool?) ?? true;
      _lastTime = (s[SyncEngine.cfgLastTime] as num?)?.toDouble() ?? 0;
    });
  }

  Future<void> _persist() async {
    await _engine.saveSettings({
      SyncEngine.cfgServer: _serverCtl.text.trim(),
      SyncEngine.cfgUser: _userCtl.text.trim(),
      SyncEngine.cfgPass: _passCtl.text,
      SyncEngine.cfgDir: _dirCtl.text.trim().isEmpty
        ? SyncEngine.remoteDirDefault
        : _dirCtl.text.trim(),
      SyncEngine.cfgAuto: _auto,
      SyncEngine.cfgVerifyTls: _verifyTls,
    });
  }

  String get _lastText {
    if (_lastTime <= 0) return T('syncNever');
    final d = DateTime.fromMillisecondsSinceEpoch((_lastTime * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return T('syncLastTime', {
      'text': '${d.year}-${two(d.month)}-${two(d.day)} '
          '${two(d.hour)}:${two(d.minute)}',
    });
  }

  Future<void> _run(bool testOnly) async {
    if (!testOnly) return _runMode('both');
    if (_busy) return;
    if (_serverCtl.text.trim().isEmpty) {
      setState(() => _status = T('syncNeedServer'));
      return;
    }
    setState(() {
      _busy = true;
      _status = T('syncRunning');
    });
    try {
      await _persist();
      if (!mounted) return;
      final (_, message) = await _engine.testConnection();
      if (!mounted) return;
      setState(() => _status = message);
    } catch (error) {
      if (mounted) setState(() => _status = T('operationFailed', {'err': '$error'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runMode(String mode) async {
    if (_busy) return;
    if (_serverCtl.text.trim().isEmpty) {
      setState(() => _status = T('syncNeedServer'));
      return;
    }
    setState(() { _busy = true; _status = T('syncChecking'); });
    try {
      await _persist();
      if (!mounted) return;
      final target = await _engine.settings();
      if (!mounted) return;
      final preview = await _engine.sync(mode: mode, dryRun: true, expectedSettings: target);
      if (!mounted) return;
      if (!preview.ok) {
        setState(() => _status = preview.error.isEmpty ? T('syncFailed') : preview.error);
        return;
      }
      if (!SyncActionPreview.sameTarget(target, await _engine.settings())) {
        if (mounted) setState(() => _status = T('syncTargetChanged'));
        return;
      }
      if (!mounted) return;
      if (!preview.hasChanges) {
        setState(() => _status = preview.remoteOnly.isEmpty ? T('syncNoChange') :
          '${T('syncNoChange')}\n${T('syncRemoteOnly', {'n': '${preview.remoteOnly.length}'})}');
        return;
      }
      final confirmed = await SyncActionPreview.confirm(context, preview);
      if (!mounted) return;
      if (!confirmed) {
        setState(() => _status = T('syncCancelled'));
        return;
      }
      if (!SyncActionPreview.sameTarget(target, await _engine.settings())) {
        if (mounted) setState(() => _status = T('syncTargetChanged'));
        return;
      }
      if (!mounted) return;
      setState(() => _status = T('syncRunning'));
      final report = await _engine.sync(mode: mode, expectedSettings: target);
      if (!mounted) return;
      setState(() {
        _status = report.summary;
        if (report.ok) _lastTime = DateTime.now().millisecondsSinceEpoch / 1000.0;
      });
      if (report.ok) widget.onSynced?.call();
    } catch (error) {
      if (mounted) setState(() => _status = T('operationFailed', {'err': '$error'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field({
    required String label,
    required TextEditingController ctl,
    String? hint,
    bool obscure = false,
    TextInputType? type,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextField(
            controller: ctl,
            enabled: !_busy,
            obscureText: obscure,
            keyboardType: type,
            style: TextStyle(fontSize: 14, color: _colors.onSurface),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant),
              filled: true,
              fillColor: _colors.surfaceContainerHighest,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: _colors.outline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: _colors.outline),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: _colors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: size.height - 90,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: LayoutBuilder(builder: (context, constraints) {
            final content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_sync_outlined, color: _colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      T('syncData'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _colors.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _lastText,
                style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Text(T('syncScope'), style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant)),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _field(
                        label: T('syncServer'),
                        ctl: _serverCtl,
                        hint: T('syncServerHint'),
                        type: TextInputType.url,
                      ),
                      _field(label: T('syncUser'), ctl: _userCtl),
                      _field(
                        label: T('syncPass'),
                        ctl: _passCtl,
                        obscure: true,
                      ),
                      _field(label: T('syncDir'), ctl: _dirCtl),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _auto,
                        onChanged: _busy ? null : (v) => setState(() => _auto = v),
                        title: Text(T('syncAuto'),
                            style: const TextStyle(fontSize: 13)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _verifyTls,
                        onChanged: _busy ? null : (v) => setState(() => _verifyTls = v),
                        title: Text(T('syncVerifyTls'),
                            style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(height: 4),
                      Text(T('syncHint'), style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _colors.onSurfaceVariant)),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              // 状态固定在按钮上方，保证可见（不随内容滚动被裁掉）
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _status,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _colors.onSurface),
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            await _persist();
                            if (!mounted) return;
                            setState(() => _status = T('syncSave'));
                          },
                    child: Text(T('syncSave')),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run(true),
                    child: Text(T('syncTest')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => _run(false),
                    child: Text(_busy ? T('syncRunning') : T('syncRun')),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: OutlinedButton(key: const ValueKey('sync-push'),
                  onPressed: _busy ? null : () => _runMode('push'),
                  child: Text(T('syncPush'), textAlign: TextAlign.center))),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton(key: const ValueKey('sync-pull'),
                  onPressed: _busy ? null : () => _runMode('pull'),
                  child: Text(T('syncPull'), textAlign: TextAlign.center))),
              ]),
            ],
            );
            return constraints.maxHeight < 380 ? SingleChildScrollView(child: content) : content;
          }),
        ),
      ),
    );
  }
}
