import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/device_adb.dart';
import '../../../../core/mono_font.dart';

Map<String, String> get _quickCommands => {
  'Battery': 'dumpsys battery',
  'Wi-Fi IP': 'ip -f inet addr show wlan0',
  'Storage': 'df -h /data /sdcard',
  'Top processes': 'top -n 1 -m 10',
  'Active activity': 'dumpsys activity activities | grep -m3 -E "mResumedActivity|topResumedActivity"',
  'My installed apps': ourPackagesShell(),
};

Map<String, String> _appCommands(String pkg) => {
  'Version': 'dumpsys package $pkg | grep -E "versionName|versionCode|lastUpdateTime"',
  // run-as only works on debuggable builds.
  'Shared prefs': 'run-as $pkg cat shared_prefs/FlutterSharedPreferences.xml',
  'App files': 'run-as $pkg ls -la files app_flutter',
  'Restart': 'am force-stop $pkg && monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null && echo restarted',
  'Permission': 'dumpsys package $pkg | grep -A50 "runtime permissions:" | grep granted',
};

class _Entry {
  _Entry(this.command);

  final String command;
  String? output;
  bool error = false;
}

class ShellTab extends StatefulWidget {
  const ShellTab({super.key, required this.dev, required this.focus});

  final DeviceAdb dev;
  final ValueNotifier<String?> focus;

  @override
  State<ShellTab> createState() => _ShellTabState();
}

class _ShellTabState extends State<ShellTab> {
  final _entries = <_Entry>[];
  final _history = <String>[];
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  var _historyIndex = -1;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(String command) async {
    command = command.trim();
    if (command.isEmpty) return;
    if (command == 'clear') return setState(_entries.clear);
    _history.remove(command);
    _history.add(command);
    _historyIndex = -1;
    _input.clear();
    final entry = _Entry(command);
    setState(() => _entries.add(entry));
    _scrollToEnd();
    final r = await widget.dev.shell(command);
    if (!mounted) return;
    setState(() {
      entry.output = [r.stdout, r.stderr].where((s) => s.trim().isNotEmpty).join('\n').trimRight();
      entry.error = !r.ok;
      if (r.exitCode == -1) entry.output = '${entry.output}\n(30s timeout — interactive commands not supported)';
    });
    _scrollToEnd();
    _focus.requestFocus();
  }

  void _scrollToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || _history.isEmpty) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _historyIndex = _historyIndex == -1 ? _history.length - 1 : (_historyIndex - 1).clamp(0, _history.length - 1);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex == -1) return KeyEventResult.handled;
      _historyIndex++;
      if (_historyIndex >= _history.length) {
        _historyIndex = -1;
        _input.clear();
        return KeyEventResult.handled;
      }
    } else {
      return KeyEventResult.ignored;
    }
    _input.text = _history[_historyIndex];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const mono = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 13);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ValueListenableBuilder(
            valueListenable: widget.focus,
            builder: (_, focus, _) => Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _quickCommands.entries)
                  ActionChip(label: Text(e.key), tooltip: e.value, onPressed: () => _run(e.value)),
                if (focus != null)
                  for (final e in _appCommands(focus).entries)
                    ActionChip(
                      avatar: const Icon(Icons.apps, size: 16),
                      label: Text('${appShort(focus)}: ${e.key}'),
                      tooltip: e.value,
                      onPressed: () => _run(e.value),
                    ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: scheme.surfaceContainerLowest,
            child: SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _entries.length,
                itemBuilder: (_, i) {
                  final e = _entries[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '\$ ${e.command}',
                          style: mono.copyWith(color: scheme.primary, fontWeight: FontWeight.bold),
                        ),
                        if (e.output == null)
                          const Padding(padding: EdgeInsets.all(4), child: LinearProgressIndicator())
                        else if (e.output!.isNotEmpty)
                          Text(e.output!, style: mono.copyWith(color: e.error ? scheme.error : null)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Focus(
            onKeyEvent: _onKey,
            child: TextField(
              controller: _input,
              focusNode: _focus,
              style: mono,
              decoration: const InputDecoration(
                prefixText: '\$ ',
                hintText: 'adb shell …  (↑/↓ history, "clear" to clear)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: _run,
            ),
          ),
        ),
      ],
    );
  }
}
