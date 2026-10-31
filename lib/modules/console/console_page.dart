import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/files.dart';
import '../../core/local_builds.dart';
import 'console_session.dart';
import 'console_view.dart';

/// Terminals opened per folder (usually a project repo), as tabs.
class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key});

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final _sessions = <ConsoleSession>[];
  var _index = 0;
  List<FlutterProject> _projects = const [];
  final _shells = ShellKind.available();
  late ShellKind _shell = _shells.first;

  @override
  void initState() {
    super.initState();
    scanFlutterProjects().then((p) => mounted ? setState(() => _projects = p) : null);
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  void _open(String folder, {ShellKind? shell}) {
    final s = ConsoleSession(shell: shell ?? _shell, cwd: folder, title: p.basename(folder));
    setState(() {
      _sessions.add(s);
      _index = _sessions.length - 1;
    });
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Open terminal here');
    if (dir != null) _open(dir);
  }

  void _close(int i) {
    final s = _sessions.removeAt(i);
    s.dispose();
    setState(() => _index = _index.clamp(0, (_sessions.length - 1).clamp(0, 1 << 30)));
  }

  static Future<void> _external(String exe, List<String> args, String cwd) async {
    try {
      await Process.start(exe, args, workingDirectory: cwd, mode: ProcessStartMode.detached, runInShell: true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final current = _sessions.isEmpty ? null : _sessions[_index.clamp(0, _sessions.length - 1)];

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Terminal', style: text.headlineSmall),
                  Text('Shells opened in your project folders', style: text.bodySmall?.copyWith(color: scheme.outline)),
                ],
              ),
              const Spacer(),
              SegmentedButton<ShellKind>(
                showSelectedIcon: false,
                segments: [for (final s in _shells) ButtonSegment(value: s, label: Text(s.label))],
                selected: {_shell},
                onSelectionChanged: (v) => setState(() => _shell = v.first),
              ),
              const SizedBox(width: 8),
              MenuAnchor(
                builder: (context, c, _) => FilledButton.icon(
                  onPressed: () => c.isOpen ? c.close() : c.open(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Open in folder'),
                ),
                menuChildren: [
                  for (final proj in _projects)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.folder_outlined, size: 18),
                      onPressed: () => _open(proj.path),
                      child: Text(proj.name),
                    ),
                  if (_projects.isNotEmpty) const Divider(height: 1),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.home_outlined, size: 18),
                    onPressed: () => _open(Platform.environment['USERPROFILE'] ?? Directory.current.path),
                    child: const Text('Home folder'),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.folder_open, size: 18),
                    onPressed: _browse,
                    child: const Text('Choose folder…'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: current == null
                ? _Empty(projects: _projects, onOpen: _open, onBrowse: _browse)
                : Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 40,
                          color: scheme.surfaceContainerLow,
                          child: Row(
                            children: [
                              Expanded(
                                child: ListView(
                                  scrollDirection: Axis.horizontal,
                                  children: [
                                    for (final (i, s) in _sessions.indexed)
                                      _Tab(
                                        title: '${s.title} · ${s.shell.label}',
                                        selected: s == current,
                                        onTap: () => setState(() => _index = i),
                                        onClose: () => _close(i),
                                      ),
                                  ],
                                ),
                              ),
                              if (current.cwd case final cwd?) ...[
                                IconButton(
                                  tooltip: 'Open folder in VS Code',
                                  onPressed: () => _external('code', ['.'], cwd),
                                  icon: const Icon(Icons.code, size: 18),
                                ),
                                IconButton(
                                  tooltip: 'Show in Explorer',
                                  onPressed: () => revealInExplorer(cwd),
                                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                                ),
                                IconButton(
                                  tooltip: 'Open in Windows Terminal',
                                  onPressed: () => _external('wt', ['-d', cwd], cwd),
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                ),
                              ],
                              IconButton(
                                tooltip: 'Restart shell',
                                onPressed: current.restart,
                                icon: const Icon(Icons.restart_alt, size: 18),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: IndexedStack(
                            index: _sessions.indexOf(current),
                            children: [for (final s in _sessions) ConsoleView(key: ObjectKey(s), session: s)],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.title, required this.selected, required this.onTap, required this.onClose});

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 14, right: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : null,
          border: Border(bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2)),
        ),
        child: Row(
          children: [
            Icon(Icons.terminal, size: 15, color: selected ? scheme.primary : scheme.outline),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(fontSize: 12.5, fontWeight: selected ? FontWeight.w600 : null)),
            IconButton(
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.projects, required this.onOpen, required this.onBrowse});

  final List<FlutterProject> projects;
  final void Function(String folder) onOpen;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 56, color: scheme.outline),
            const SizedBox(height: 12),
            Text('Open a terminal in a project', style: text.titleMedium),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final proj in projects)
                  ActionChip(
                    avatar: const Icon(Icons.folder_outlined, size: 16),
                    label: Text(proj.name),
                    onPressed: () => onOpen(proj.path),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Choose folder…'),
                  onPressed: onBrowse,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
