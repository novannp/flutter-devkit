import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/local_builds.dart';
import '../../../console/console_session.dart';
import '../../../console/console_view.dart';
import '../../services/device_adb.dart';
import '../../../../core/compact_dropdown.dart';

/// Interactive terminal for one device: `adb shell`, or a PC shell pre-targeted at it (ANDROID_SERIAL).
class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key, required this.dev, required this.focus, required this.active});

  final DeviceAdb dev;
  final ValueNotifier<String?> focus;

  /// Started on first view so Multi Screen panels don't each spawn a shell up front.
  final bool active;

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  ConsoleSession? _session;
  late final List<ShellKind> _shells = [
    if (widget.dev.adb.tools.adb case final adb?) ShellKind.deviceShell(adb, widget.dev.target),
    ...ShellKind.available(),
  ];
  late ShellKind _shell = _shells.first;

  @override
  void didUpdateWidget(TerminalTab old) {
    super.didUpdateWidget(old);
    if (widget.active && _session == null) _start();
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<String> _cwdFor() async {
    final pkg = widget.focus.value;
    if (pkg != null) {
      final proj = (await scanFlutterProjects()).where((p) => p.package == pkg).firstOrNull;
      if (proj != null) return proj.path;
    }
    return Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;
  }

  Future<void> _start() async {
    final device = _shell.label == 'Device shell';
    final cwd = device ? null : await _cwdFor();
    if (!mounted) return;
    _session?.dispose();
    setState(() {
      _session = ConsoleSession(
        shell: _shell,
        cwd: cwd,
        // adb and flutter in this shell target this device without -s / -d.
        environment: device ? null : {'ANDROID_SERIAL': widget.dev.target},
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(
            children: [
              CompactDropdown<ShellKind>(
                value: _shell,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [for (final k in _shells) DropdownMenuItem(value: k, child: Text(k.label))],
                onChanged: (k) {
                  if (k == null || k == _shell) return;
                  setState(() => _shell = k);
                  _start();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _shell.label == 'Device shell'
                      ? 'adb shell on ${widget.dev.target}'
                      : 'PC shell · ANDROID_SERIAL=${widget.dev.target}${s?.cwd == null ? '' : ' · ${s!.cwd}'}',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(tooltip: 'Restart', onPressed: s?.restart, icon: const Icon(Icons.restart_alt, size: 18)),
            ],
          ),
        ),
        Expanded(
          child: s == null
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Start terminal'),
                  ),
                )
              : ConsoleView(key: ObjectKey(s), session: s, autofocus: widget.active),
        ),
      ],
    );
  }
}
