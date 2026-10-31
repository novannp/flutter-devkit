import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/apps.dart';
import '../../../../core/local_builds.dart';
import '../../services/flutter_session.dart';

class FlutterTab extends StatefulWidget {
  const FlutterTab({super.key, required this.session, required this.focus});

  final FlutterSession session;
  final ValueNotifier<String?> focus;

  @override
  State<FlutterTab> createState() => _FlutterTabState();
}

class _FlutterTabState extends State<FlutterTab> {
  final _scroll = ScrollController();
  final _args = TextEditingController();
  final _filter = TextEditingController();
  List<FlutterProject> _projects = const [];
  FlutterProject? _project;
  var _attach = false;
  var _onlyApp = false;
  var _autoScroll = true;

  FlutterSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
    widget.focus.addListener(_matchFocus);
    _load();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    widget.focus.removeListener(_matchFocus);
    _scroll.dispose();
    _args.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final projects = await scanFlutterProjects();
    if (!mounted) return;
    setState(() => _projects = projects);
    _matchFocus();
  }

  // Project follows the focus app so you don't pick twice.
  void _matchFocus() {
    final match = _projects.where((p) => p.package == widget.focus.value).firstOrNull;
    if (match != null || _project == null) _select(match ?? _projects.firstOrNull);
  }

  Future<void> _select(FlutterProject? p) async {
    if (s.active) return;
    setState(() => _project = p);
    if (p == null) return;
    final prefs = await SharedPreferences.getInstance();
    _args.text = prefs.getString('flutter_args_${p.name}') ?? '';
  }

  Future<void> _start() async {
    final p = _project;
    if (p == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flutter_args_${p.name}', _args.text.trim());
    final extra = _args.text.trim().isEmpty ? <String>[] : _args.text.trim().split(RegExp(r'\s+'));
    s.start(p, attach: _attach, extraArgs: extra);
  }

  void _onSession() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Color? _color(FlutterLineKind k, ColorScheme scheme) => switch (k) {
    FlutterLineKind.error => Colors.red.shade400,
    FlutterLineKind.success => Colors.green.shade400,
    FlutterLineKind.info => scheme.primary,
    FlutterLineKind.build => scheme.outline,
    FlutterLineKind.log => scheme.onSurface,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _filter.text.toLowerCase();
    final lines = s.lines
        .where((l) => !_onlyApp || l.kind == FlutterLineKind.log || l.kind == FlutterLineKind.error)
        .where((l) => q.isEmpty || l.text.toLowerCase().contains(q))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<FlutterProject>(
                      initialValue: _project,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Project',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final p in _projects)
                          DropdownMenuItem(
                            value: p,
                            child: Text(
                              isOurApp(p.package) ? '${appName(p.package)}  ·  ${p.name}' : p.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: s.active ? null : _select,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Run'), tooltip: 'flutter run'),
                      ButtonSegment(value: true, label: Text('Attach'), tooltip: 'Connect to a running debug app'),
                    ],
                    selected: {_attach},
                    onSelectionChanged: s.active ? null : (v) => setState(() => _attach = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _args,
                enabled: !s.active,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Extra args (saved per project)',
                  hintText: '--flavor dev -t lib/main_dev.dart',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (!s.active)
                    FilledButton.icon(
                      onPressed: _project == null ? null : _start,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_attach ? 'Attach (F5)' : 'Run (F5)'),
                    )
                  else
                    FilledButton.tonalIcon(onPressed: s.stop, icon: const Icon(Icons.stop), label: const Text('Stop')),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: 'Hot reload (Ctrl+F5)',
                    onPressed: s.canReload ? () => s.reload() : null,
                    icon: const Icon(Icons.bolt),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Hot restart (Ctrl+Shift+F5)',
                    onPressed: s.canReload ? () => s.reload(full: true) : null,
                    icon: const Icon(Icons.restart_alt),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: 'Auto hot reload when a .dart file in lib/ is saved',
                    child: Row(
                      children: [
                        const Text('Reload on save', style: TextStyle(fontSize: 12)),
                        Switch(value: s.reloadOnSave, onChanged: s.setReloadOnSave),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _filter,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Filter log…',
                      prefixIcon: Icon(Icons.filter_list, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('App logs only'),
                tooltip: 'Hide build output',
                selected: _onlyApp,
                onSelected: (v) => setState(() => _onlyApp = v),
              ),
              IconButton(
                tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
                onPressed: () => setState(() => _autoScroll = !_autoScroll),
                icon: Icon(Icons.vertical_align_bottom, color: _autoScroll ? scheme.primary : null),
              ),
              IconButton(tooltip: 'Clear', onPressed: s.clear, icon: const Icon(Icons.delete_sweep_outlined)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: scheme.surfaceContainerLowest,
            child: lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _projects.isEmpty
                            ? 'No Flutter projects in project folders. Set them in Settings (main DevKit) or Install → "Set project folders…".'
                            : 'Pick a project, then Run.\nAttach = connect to a running debug app (e.g. from VS Code).',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.outline),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                        child: Text(
                          lines[i].text,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 12.5,
                            color: _color(lines[i].kind, scheme),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
