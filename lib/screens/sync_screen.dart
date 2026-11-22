import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/annotation_store.dart';
import '../services/app_storage.dart';
import '../services/sync_engine.dart';

/// 数据同步（WebDAV）。与 PC 版「设置 → 数据同步」同一套协议：
/// 远端 v1/books/<content_key>.json、v1/devices/<device_id>.json、v1/meta.json。
/// 只同步书架元信息、阅读进度与书签；正文与音频缓存不上传
/// （音频缓存靠两端相同的 content_key 目录名互相复用）。
class SyncScreen extends StatefulWidget {
  final AppStorage storage;
  final AnnotationStore annotations;
  final VoidCallback? onSynced;

  const SyncScreen({
    super.key,
    required this.storage,
    required this.annotations,
    this.onSynced,
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
  static const _paper = Color(0xFFF7F0E3);
  static const _ink = Color(0xFF5D3A1A);

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
      SyncEngine(storage: widget.storage, annotations: widget.annotations);

  @override
  void initState() {
    super.initState();
    _load();
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
    final s = await _engine.settings();
    s[SyncEngine.cfgServer] = _serverCtl.text.trim();
    s[SyncEngine.cfgUser] = _userCtl.text.trim();
    s[SyncEngine.cfgPass] = _passCtl.text;
    s[SyncEngine.cfgDir] = _dirCtl.text.trim().isEmpty
        ? SyncEngine.remoteDirDefault
        : _dirCtl.text.trim();
    s[SyncEngine.cfgAuto] = _auto;
    s[SyncEngine.cfgVerifyTls] = _verifyTls;
    await _engine.saveSettings(s);
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
    if (_serverCtl.text.trim().isEmpty) {
      setState(() => _status = T('syncNeedServer'));
      return;
    }
    await _persist();
    setState(() {
      _busy = true;
      _status = T('syncRunning');
    });
    if (testOnly) {
      final (ok, msg) = await _engine.testConnection();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = msg;
      });
      return;
    }
    final report = await _engine.sync();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = report.summary;
      _lastTime = report.ok
          ? DateTime.now().millisecondsSinceEpoch / 1000.0
          : _lastTime;
    });
    if (report.ok) {
      widget.onSynced?.call();
    }
  }

  /// 预览文本：按按钮之前先说清楚这次会动几条
  String _previewText(SyncReport r) {
    final parts = <String>[];
    if (r.mode == 'push') {
      parts.add(T('syncWillPush', {'n': '${r.pushed}'}));
      if (r.deleted > 0) parts.add(T('syncWillDelete', {'n': '${r.deleted}'}));
    } else {
      parts.add(T('syncWillPull', {'n': '${r.pulled}'}));
      if (r.imported > 0) parts.add(T('syncWillImport', {'n': '${r.imported}'}));
      if (r.removed > 0) parts.add(T('syncWillRemove', {'n': '${r.removed}'}));
    }
    return parts.join('；');
  }

  /// 「保存到云端」/「从云端读取」：先跑一次只读预览，确认后才真正同步
  Future<void> _runMode(String mode) async {
    if (_busy) return;
    if (_serverCtl.text.trim().isEmpty) {
      setState(() => _status = T('syncNeedServer'));
      return;
    }
    await _persist();
    setState(() {
      _busy = true;
      _status = T('syncChecking');
    });
    SyncReport preview;
    try {
      preview = await _engine.sync(mode: mode, dryRun: true);
    } catch (e) {
      preview = SyncReport()..error = T('syncCheckFailed', {'err': '$e'});
    }
    if (!mounted) return;
    if (!preview.ok) {
      setState(() {
        _busy = false;
        _status = preview.error.isEmpty
            ? T('syncCheckFailed', {'err': ''})
            : preview.error;
      });
      return;
    }
    final total = preview.pushed +
        preview.pulled +
        preview.imported +
        preview.removed +
        preview.deleted;
    if (total == 0) {
      setState(() {
        _busy = false;
        _status = T('syncNoChange');
      });
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _paper,
        title: Text(T('syncData'),
            style: const TextStyle(fontSize: 15, color: _ink)),
        content: Text(_previewText(preview),
            style: const TextStyle(fontSize: 13, color: Color(0xFF5D3A1A))),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(T('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _ink),
            child: Text(T('syncContinue')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (go != true) {
      setState(() {
        _busy = false;
        _status = T('syncCancelled');
      });
      return;
    }
    setState(() => _status = T('syncRunning'));
    final report = await _engine.sync(mode: mode);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = report.summary;
      _lastTime = report.ok
          ? DateTime.now().millisecondsSinceEpoch / 1000.0
          : _lastTime;
    });
    if (report.ok) {
      widget.onSynced?.call();
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A7360))),
          const SizedBox(height: 4),
          TextField(
            controller: ctl,
            obscureText: obscure,
            keyboardType: type,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFA99680)),
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFD8C7AE)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFD8C7AE)),
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
      backgroundColor: _paper,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: size.height - 90,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.cloud_sync_outlined, color: _ink),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      T('syncData'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _ink,
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
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A7360)),
              ),
              const SizedBox(height: 10),
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
                        onChanged: (v) => setState(() => _auto = v),
                        title: Text(T('syncAuto'),
                            style: const TextStyle(fontSize: 13)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _verifyTls,
                        onChanged: (v) => setState(() => _verifyTls = v),
                        title: Text(T('syncVerifyTls'),
                            style: const TextStyle(fontSize: 13)),
                      ),
                      const SizedBox(height: 4),
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
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B5B4B)),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                T('syncHint'),
                style: const TextStyle(
                    fontSize: 11, height: 1.35, color: Color(0xFF8A7360)),
              ),
              const SizedBox(height: 6),
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
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : () => _runMode('push'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _ink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(T('syncPush')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _runMode('pull'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _ink,
                        side: const BorderSide(color: Color(0xFF5D3A1A)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(T('syncPull')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
