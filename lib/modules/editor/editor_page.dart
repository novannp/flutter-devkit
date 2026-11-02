import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/local_builds.dart';
import '../console/console_session.dart';
import '../console/console_view.dart';
import '../devices/cubit/devices_cubit.dart';
import '../devices/models/device.dart';
import '../devices/services/flutter_session.dart';
import 'code_pane.dart';
import 'dart_sdk.dart';
import 'debug_panel.dart';
import 'debugger.dart';
import 'editor_workspace.dart';
import 'file_tree.dart';
import 'source_control.dart';
import 'source_control_view.dart';

const _prefRoot = 'editor_root';
const _prefFiles = 'editor_open_files';
const _prefReloadOnSave = 'editor_reload_on_save';
const _desktopDevice = 'windows';

/// Saves unsaved tabs when the app quits, so nothing typed is lost.
Future<void> Function()? editorSaveAllOnQuit;

String _projectRootOf(String file) {
  var dir = p.dirname(file);
  while (!File(p.join(dir, 'pubspec.yaml')).existsSync() && p.dirname(dir) != dir) {
    dir = p.dirname(dir);
  }
  return File(p.join(dir, 'pubspec.yaml')).existsSync() ? dir : p.dirname(file);
}

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, this.initialRoot, this.initialFile});

  final String? initialRoot;
  final String? initialFile;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

enum _Panel { problems, output, debug, diff, terminal, search }

class _EditorPageState extends State<EditorPage> {
  EditorWorkspace? _ws;
  List<FlutterProject> _projects = const [];
  StreamSubscription<EditTarget>? _revealSub;
  final _paneKey = GlobalKey<CodePaneState>();
  final _treeKey = GlobalKey<FileTreeState>();

  var _panel = _Panel.problems;
  var _panelOpen = false;
  double _panelHeight = 240;
  double _treeWidth = 260;

  ConsoleSession? _terminal;
  FlutterSession? _flutter;
  final _debugger = Debugger();
  final _pageFocus = FocusNode(debugLabel: 'editor page');
  final _git = SourceControl();
  Timer? _gitPoll;
  var _showGit = false;
  var _diffTitle = '';
  String? _diffPath;
  List<DiffLine> _diff = const [];
  String? _debugUri;
  (String, int)? _shownStop;
  String? _device;
  bool _reloadOnSave = true;
  final _tool = <String>[];
  bool _toolBusy = false;
  final _outputScroll = ScrollController();

  final _searchCtrl = TextEditingController();
  List<SearchHit> _hits = const [];
  String _hitsTitle = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    editorSaveAllOnQuit = () async => _ws?.saveAll();
    _git.addListener(_rebuild);
    _debugger
      ..onMessage = ((m) => _flutter?.note(m, error: true))
      ..addListener(_onDebugger);
    _load();
  }

  @override
  void dispose() {
    editorSaveAllOnQuit = null;
    _revealSub?.cancel();
    _ws?.removeListener(_rebuild);
    _ws?.dispose();
    _terminal?.dispose();
    _pageFocus.dispose();
    _gitPoll?.cancel();
    _git
      ..removeListener(_rebuild)
      ..dispose();
    _flutter?.removeListener(_onFlutter);
    _flutter?.dispose();
    _debugger
      ..removeListener(_onDebugger)
      ..dispose();
    _searchCtrl.dispose();
    _outputScroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), width: 480, behavior: SnackBarBehavior.floating));

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final projects = await scanFlutterProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _reloadOnSave = prefs.getBool(_prefReloadOnSave) ?? true;
    });
    // DEVKIT_EDITOR=<file> opens straight on that file (README screenshots, demos).
    final envFile = Platform.environment['DEVKIT_EDITOR'];
    final startFile = widget.initialFile ?? envFile;
    final startRoot = widget.initialRoot ?? (envFile == null ? null : _projectRootOf(envFile));
    final root = startRoot ?? prefs.getString(_prefRoot);
    if (root == null || !Directory(root).existsSync()) return;
    final files = startRoot != null ? [?startFile] : (prefs.getStringList(_prefFiles) ?? const <String>[]);
    await _openRoot(root, files: files);
  }

  Future<void> _rememberTabs() async {
    final ws = _ws;
    if (ws == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRoot, ws.root);
    await prefs.setStringList(_prefFiles, ws.documents.map((d) => d.path).toList());
  }

  Future<void> _openRoot(String root, {List<String> files = const []}) async {
    final old = _ws;
    if (old != null) {
      if (!await _confirmUnsaved(old.documents.where((d) => d.dirty).toList())) return;
      old.removeListener(_rebuild);
      _revealSub?.cancel();
      old.dispose();
    }
    _terminal?.dispose();
    _terminal = null;
    _flutter?.removeListener(_onFlutter);
    _flutter?.dispose();
    _flutter = null;
    _debugUri = null;
    unawaited(_debugger.disconnect());
    final ws = EditorWorkspace(
      root,
      spanBuilderFor: (path) => diagnosticsSpanBuilder(() => _ws?.documentAt(path)?.diagnostics ?? const []),
    );
    ws.addListener(_rebuild);
    _revealSub = ws.revealRequests.stream.listen((t) {
      // The tab's pane may only appear on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _paneKey.currentState?.reveal(t.line, t.column));
    });
    setState(() {
      _ws = ws;
      _hits = const [];
      _diff = const [];
      _diffTitle = '';
      _diffPath = null;
    });
    unawaited(_git.open(root));
    for (final f in files) {
      if (File(f).existsSync()) await _openFile(f);
    }
    await _rememberTabs();
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open folder');
    if (path != null) await _openRoot(path);
  }

  Future<void> _openFile(String path, {int? line, int? column}) async {
    try {
      await _ws?.open(path, line: line, column: column);
      await _rememberTabs();
    } on FileSystemException catch (e) {
      _toast('${p.basename(path)}: ${e.message}');
    }
  }

  /// True when it's fine to continue: everything saved, or the user chose to discard.
  Future<bool> _confirmUnsaved(List<EditorDocument> docs) async {
    if (docs.isEmpty) return true;
    final names = docs.map((d) => d.name).join(', ');
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save changes?'),
        content: Text('Unsaved changes in $names.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text("Don't save")),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (choice == null) return false;
    if (choice == 'save') {
      for (final d in docs) {
        await _ws?.save(d);
      }
    }
    return true;
  }

  Future<void> _closeTab(EditorDocument doc) async {
    if (!await _confirmUnsaved(doc.dirty ? [doc] : const [])) return;
    await _ws?.close(doc);
    await _rememberTabs();
  }

  Future<void> _save() async {
    final ws = _ws, doc = ws?.active;
    if (ws == null || doc == null) return;
    try {
      await ws.save(doc);
    } on FileSystemException catch (e) {
      return _toast('Could not save ${doc.name}: ${e.message}');
    }
    final f = _flutter;
    if (_reloadOnSave && doc.languageId == 'dart' && f != null && f.canReload) unawaited(f.reload());
  }

  // ---------------------------------------------------------------- keys

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final key = e.logicalKey;
    void Function()? action;
    if (key == LogicalKeyboardKey.f5 && !hw.isControlPressed) {
      action = hw.isShiftPressed ? () => _flutter?.stop() : (_debugger.paused ? _debugger.resume : _run);
    } else if (hw.isControlPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyG) {
      action = _toggleGit;
    } else if (key == LogicalKeyboardKey.f6) {
      action = _debugger.pause;
    } else if (key == LogicalKeyboardKey.f9) {
      action = () => _paneKey.currentState?.toggleBreakpointAtCursor();
    } else if (key == LogicalKeyboardKey.f10) {
      action = _debugger.stepOver;
    } else if (key == LogicalKeyboardKey.f11) {
      action = hw.isShiftPressed ? _debugger.stepOut : _debugger.stepInto;
    } else if (hw.isControlPressed) {
      if (key == LogicalKeyboardKey.keyS) action = hw.isShiftPressed ? () => _ws?.saveAll() : _save;
      if (key == LogicalKeyboardKey.keyW) action = _ws?.active == null ? null : () => _closeTab(_ws!.active!);
      if (key == LogicalKeyboardKey.keyP) action = _quickOpen;
      if (key == LogicalKeyboardKey.keyG) action = _goToLine;
      if (key == LogicalKeyboardKey.keyJ) action = () => setState(() => _panelOpen = !_panelOpen);
      if (key == LogicalKeyboardKey.backquote) action = () => _showPanel(_Panel.terminal);
      if (hw.isShiftPressed && key == LogicalKeyboardKey.keyF) action = () => _showPanel(_Panel.search);
      if (key == LogicalKeyboardKey.f5) action = () => _flutter?.reload(full: hw.isShiftPressed);
    } else if (hw.isAltPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyF) {
      action = _format;
    }
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  void _showPanel(_Panel panel) => setState(() {
    _panel = panel;
    _panelOpen = true;
  });

  Future<void> _format() async {
    final ws = _ws, doc = ws?.active;
    if (ws == null || doc == null) return;
    try {
      await ws.format(doc);
    } on Exception catch (e) {
      _toast("Couldn't format: $e");
    }
  }

  Future<void> _quickOpen() async {
    final ws = _ws;
    if (ws == null) return;
    final files = await listProjectFiles(ws.root);
    if (!mounted) return;
    final path = await showDialog<String>(
      context: context,
      builder: (_) => _QuickOpen(root: ws.root, files: files),
    );
    if (path != null) await _openFile(path);
  }

  Future<void> _goToLine() async {
    final pane = _paneKey.currentState;
    if (pane == null) return;
    final ctrl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to line'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
      ),
    );
    ctrl.dispose();
    if (line != null) pane.reveal(line - 1, 0);
  }

  // ---------------------------------------------------------------- flutter

  FlutterProject _project(EditorWorkspace ws) =>
      FlutterProject(p.basename(ws.root), ws.root, '', usesFvm: projectUsesFvm(ws.root));

  Future<void> _run() async {
    final ws = _ws, device = _device;
    if (ws == null) return;
    if (device == null) return _toast('Pick a device first');
    await ws.saveAll();
    if (_flutter?.deviceId != device) {
      _flutter?.removeListener(_onFlutter);
      _flutter?.dispose();
      _flutter = FlutterSession(device)..addListener(_onFlutter);
    }
    _showPanel(_Panel.output);
    // Pausing at start gets the breakpoints in before main runs; the debugger resumes once they're set.
    await _flutter!.start(_project(ws), attach: false, extraArgs: _debugger.hasBreakpoints ? const ['--start-paused'] : const []);
  }

  // A click on a panel can leave nothing focused, and then F9 or F10 reach no one.
  Widget _keepingKeys(Widget child) => Listener(
    onPointerUp: (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageFocus.hasFocus && FocusManager.instance.primaryFocus is FocusScopeNode) _pageFocus.requestFocus();
    }),
    child: child,
  );

  void _toggleGit() {
    setState(() => _showGit = !_showGit);
    _gitPoll?.cancel();
    _gitPoll = null;
    if (!_showGit) return;
    unawaited(_git.refresh());
    // Terminals and other tools change the repo too.
    _gitPoll = Timer.periodic(const Duration(seconds: 4), (_) => _git.refresh());
  }

  Future<void> _showDiff(GitChange change, bool staged) async {
    final lines = await _git.diffOf(change, staged: staged);
    if (!mounted) return;
    setState(() {
      _diff = lines;
      _diffTitle = change.path;
      _diffPath = _git.absolute(change.path);
    });
    _showPanel(_Panel.diff);
  }

  void _onFlutter() {
    _rebuild();
    final uri = _flutter?.vmServiceUri, root = _ws?.root;
    if (uri == _debugUri) return;
    _debugUri = uri;
    if (uri == null || root == null) {
      unawaited(_debugger.disconnect());
      return;
    }
    unawaited(
      _debugger.connect(uri, root).catchError((Object e) {
        _flutter?.note('Debugger could not connect: $e', error: true);
      }),
    );
  }

  void _onDebugger() {
    _rebuild();
    final frame = _debugger.currentFrame;
    if (frame == null) {
      _shownStop = null;
      return;
    }
    // Only follow a new stop, so reading other files while paused doesn't jump back.
    final path = frame.path;
    if (_debugger.selectedFrame != 0 || path == null || _shownStop == (path, frame.line)) return;
    _shownStop = (path, frame.line);
    _showPanel(_Panel.debug);
    unawaited(_openFile(path, line: frame.line, column: frame.column));
  }

  Future<void> _runTool(String args) async {
    final ws = _ws;
    if (ws == null || _toolBusy) return;
    await ws.saveAll();
    final fvm = projectUsesFvm(ws.root);
    final line = '${fvm ? 'fvm ' : ''}flutter $args';
    setState(() {
      _toolBusy = true;
      _tool
        ..clear()
        ..add('\$ $line');
    });
    _showPanel(_Panel.output);
    try {
      final parts = line.split(' ');
      final process = await Process.start(parts.first, parts.skip(1).toList(), workingDirectory: ws.root, runInShell: Platform.isWindows);
      void add(String l) {
        if (mounted) setState(() => _tool.add(l));
      }

      final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(add);
      final err = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(add);
      final code = await process.exitCode;
      await Future.wait([out, err]);
      add(code == 0 ? '✓ Done' : '✗ Exit code $code');
    } on Exception catch (e) {
      if (mounted) setState(() => _tool.add('Failed: $e'));
    }
    if (mounted) setState(() => _toolBusy = false);
  }

  Future<void> _search(String query) async {
    final ws = _ws;
    if (ws == null || query.trim().isEmpty) return;
    setState(() => _searching = true);
    final hits = await searchInFiles(ws.root, query.trim());
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _hitsTitle = '${hits.length}${hits.length >= 1000 ? '+' : ''} results for "${query.trim()}"';
      _searching = false;
    });
  }

  Future<void> _showReferences(List<EditTarget> refs) async {
    final hits = <SearchHit>[];
    for (final r in refs) {
      var text = '';
      try {
        text = (await File(r.path).readAsLines()).elementAtOrNull(r.line)?.trim() ?? '';
      } on Exception {
        // A file that can't be read still gets its location listed.
      }
      hits.add(SearchHit(r.path, r.line, r.column, text));
    }
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _hitsTitle = '${hits.length} references';
    });
    _showPanel(_Panel.search);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ws = _ws;
    if (ws == null) return _Welcome(projects: _projects, onOpen: _openRoot, onPick: _pickFolder);
    final scheme = Theme.of(context).colorScheme;
    final doc = ws.active;
    return _keepingKeys(Focus(
      focusNode: _pageFocus,
      onKeyEvent: (_, e) => _onKey(e),
      child: Column(
        children: [
          _toolbar(ws, scheme),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: _treeWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sideTabs(scheme),
                      Expanded(
                        // The tree stays mounted, so its open folders survive a look at Source Control.
                        child: IndexedStack(
                          index: _showGit ? 1 : 0,
                          sizing: StackFit.expand,
                          children: [
                            FileTree(
                              key: _treeKey,
                              root: ws.root,
                              onOpen: _openFile,
                              errorsIn: (path) => ws.diagnostics[path]?.where((d) => d.severity == 1).length ?? 0,
                              isOpen: (path) => p.equals(ws.active?.path ?? '', path),
                            ),
                            SourceControlView(git: _git, onBeforeCommit: ws.saveAll, onDiff: _showDiff),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _DragHandle(
                  axis: Axis.horizontal,
                  onDrag: (d) => setState(() => _treeWidth = (_treeWidth + d).clamp(160, 600)),
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (ws.documents.isNotEmpty) _tabs(ws, scheme),
                      if (doc != null && doc.changedOnDisk) _changedBanner(doc, scheme),
                      if (ws.lspError != null) _errorBanner(ws.lspError!, scheme),
                      Expanded(
                        child: doc == null
                            ? _EmptyEditor(onQuickOpen: _quickOpen)
                            : CodePane(
                                key: _paneKey,
                                workspace: ws,
                                doc: doc,
                                debugger: _debugger,
                                git: _git,
                                onKey: _onKey,
                                onTarget: (t) => _openFile(t.path, line: t.line, column: t.column),
                                onReferences: _showReferences,
                              ),
                      ),
                      if (_panelOpen) ...[
                        _DragHandle(
                          axis: Axis.vertical,
                          onDrag: (d) => setState(() => _panelHeight = (_panelHeight - d).clamp(100, 700)),
                        ),
                        SizedBox(height: _panelHeight, child: _bottomPanel(ws, scheme)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          _statusBar(ws, scheme),
        ],
      ),
    ));
  }

  Widget _sideTabs(ColorScheme scheme) {
    Widget tab(String tip, IconData icon, bool selected, String? badge) => IconButton(
      tooltip: tip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      color: selected ? scheme.primary : scheme.onSurfaceVariant,
      onPressed: selected ? null : _toggleGit,
      icon: badge == null ? Icon(icon) : Badge(label: Text(badge), child: Icon(icon)),
    );
    final count = _git.changes.length;
    return Row(
      children: [
        tab('Files', Icons.folder_outlined, !_showGit, null),
        tab('Source Control (Ctrl+Shift+G)', Icons.call_split, _showGit, count == 0 ? null : '$count'),
      ],
    );
  }

  Widget _toolbar(EditorWorkspace ws, ColorScheme scheme) {
    final f = _flutter;
    final active = f?.active == true;
    final devices = context.select<DevicesCubit, List<Device>>(
      (c) => c.state.devices.where((d) => d.adb == AdbState.connected && d.adbTarget != null).toList(),
    );
    final targets = {for (final d in devices) d.adbTarget!: d.displayName, _desktopDevice: 'Windows (desktop)'};
    if (_device != null && !targets.containsKey(_device)) _device = null;
    _device ??= devices.firstOrNull?.adbTarget;
    final fvm = projectUsesFvm(ws.root);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Switch project',
            onSelected: (v) => v.isEmpty ? _pickFolder() : _openRoot(v),
            itemBuilder: (_) => [
              for (final pr in _projects) PopupMenuItem(value: pr.path, child: Text(pr.name)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: '', child: Text('Open folder…')),
            ],
            child: Row(
              children: [
                const Icon(Icons.folder_open_outlined, size: 18),
                const SizedBox(width: 6),
                Text(p.basename(ws.root), style: const TextStyle(fontWeight: FontWeight.w600)),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
          if (fvm)
            Tooltip(
              message: 'Flutter SDK pinned by fvm: ${flutterSdkOf(ws.root) ?? 'not installed yet'}',
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('fvm', style: TextStyle(color: scheme.primary, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
          const Spacer(),
          DropdownButton<String>(
            value: _device,
            hint: const Text('No device', style: TextStyle(fontSize: 13)),
            isDense: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
            onChanged: active ? null : (v) => setState(() => _device = v),
            items: [for (final t in targets.entries) DropdownMenuItem(value: t.key, child: Text(t.value))],
          ),
          const SizedBox(width: 4),
          if (active)
            IconButton(tooltip: 'Stop (Shift+F5)', onPressed: f!.stop, icon: const Icon(Icons.stop, color: Colors.red))
          else
            IconButton(
              tooltip: 'Run (F5)',
              onPressed: _run,
              icon: Icon(Icons.play_arrow, color: scheme.primary),
            ),
          IconButton(
            tooltip: 'Hot reload (Ctrl+F5)',
            onPressed: f?.canReload == true ? f!.reload : null,
            icon: const Icon(Icons.bolt),
          ),
          IconButton(
            tooltip: 'Hot restart (Ctrl+Shift+F5)',
            onPressed: f?.canReload == true ? () => f!.reload(full: true) : null,
            icon: const Icon(Icons.restart_alt),
          ),
          PopupMenuButton<String>(
            tooltip: 'Flutter commands',
            icon: const Icon(Icons.flutter_dash),
            enabled: !_toolBusy,
            onSelected: _runTool,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pub get', child: Text('pub get')),
              PopupMenuItem(value: 'pub upgrade', child: Text('pub upgrade')),
              PopupMenuItem(value: 'pub outdated', child: Text('pub outdated')),
              PopupMenuItem(value: 'clean', child: Text('clean')),
              PopupMenuItem(value: 'analyze', child: Text('analyze')),
              PopupMenuItem(value: 'test', child: Text('test')),
              PopupMenuItem(value: 'doctor', child: Text('doctor')),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Editor options',
            icon: const Icon(Icons.tune, size: 20),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'format', checked: ws.formatOnSave, child: const Text('Format on save')),
              CheckedPopupMenuItem(value: 'reload', checked: _reloadOnSave, child: const Text('Hot reload on save')),
            ],
            onSelected: (v) async {
              if (v == 'format') ws.formatOnSave = !ws.formatOnSave;
              if (v == 'reload') {
                _reloadOnSave = !_reloadOnSave;
                await (await SharedPreferences.getInstance()).setBool(_prefReloadOnSave, _reloadOnSave);
              }
              _rebuild();
            },
          ),
        ],
      ),
    );
  }

  Widget _tabs(EditorWorkspace ws, ColorScheme scheme) => Container(
    height: 36,
    color: scheme.surfaceContainerLow,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final d in ws.documents)
          Listener(
            // Middle click closes, as in every other editor.
            onPointerDown: (e) {
              if (e.buttons == 4) _closeTab(d);
            },
            child: InkWell(
              onTap: () => ws.activate(d),
              child: Container(
                padding: const EdgeInsets.only(left: 12, right: 4),
                decoration: BoxDecoration(
                  color: d == ws.active ? scheme.surface : null,
                  border: Border(
                    right: BorderSide(color: scheme.outlineVariant),
                    top: BorderSide(color: d == ws.active ? scheme.primary : Colors.transparent, width: 2),
                  ),
                ),
                child: Row(
                  children: [
                    Tooltip(
                      message: d.path,
                      child: Text(
                        d.name,
                        style: TextStyle(
                          fontSize: 13,
                          color: d.diagnostics.any((x) => x.severity == 1) ? scheme.error : null,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: d.dirty ? 'Unsaved. Close (Ctrl+W)' : 'Close (Ctrl+W)',
                      visualDensity: VisualDensity.compact,
                      iconSize: d.dirty ? 10 : 14,
                      onPressed: () => _closeTab(d),
                      icon: Icon(d.dirty ? Icons.circle : Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _changedBanner(EditorDocument doc, ColorScheme scheme) => Container(
    color: Colors.orange.withValues(alpha: .15),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text('${doc.name} changed on disk. Saving will overwrite that change.', style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _errorBanner(String text, ColorScheme scheme) => Container(
    color: scheme.error.withValues(alpha: .12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        Icon(Icons.error_outline, size: 16, color: scheme.error),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _statusBar(EditorWorkspace ws, ColorScheme scheme) {
    final errors = ws.countOf(1), warnings = ws.countOf(2);
    final doc = ws.active;
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => _showPanel(_Panel.problems),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: errors > 0 ? scheme.error : scheme.outline),
                Text(' $errors  ', style: style),
                Icon(Icons.warning_amber_rounded, size: 14, color: warnings > 0 ? Colors.orange : scheme.outline),
                Text(' $warnings', style: style),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (ws.analyzing) Text('Analyzing…', style: style),
          const Spacer(),
          if (doc != null)
            ListenableBuilder(
              listenable: doc.controller,
              builder: (_, _) {
                final sel = doc.controller.selection;
                return Text('Ln ${sel.extentIndex + 1}, Col ${sel.extentOffset + 1}', style: style);
              },
            ),
          const SizedBox(width: 14),
          InkWell(onTap: () => _showPanel(_Panel.terminal), child: Text('Terminal', style: style)),
          const SizedBox(width: 10),
          InkWell(onTap: () => setState(() => _panelOpen = !_panelOpen), child: Icon(_panelOpen ? Icons.expand_more : Icons.expand_less, size: 16)),
        ],
      ),
    );
  }

  Widget _bottomPanel(EditorWorkspace ws, ColorScheme scheme) {
    Widget tab(_Panel panel, String label) => TextButton(
      onPressed: () => setState(() => _panel = panel),
      style: TextButton.styleFrom(
        foregroundColor: _panel == panel ? scheme.primary : scheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );

    return Container(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                tab(_Panel.problems, 'Problems (${ws.allDiagnostics.length})'),
                tab(_Panel.output, 'Output'),
                tab(_Panel.debug, _debugger.paused ? 'Debug (paused)' : 'Debug'),
                tab(_Panel.diff, 'Diff'),
                tab(_Panel.terminal, 'Terminal'),
                tab(_Panel.search, 'Search'),
                const Spacer(),
                IconButton(
                  tooltip: 'Hide (Ctrl+J)',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _panelOpen = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (_panel) {
              _Panel.problems => _problems(ws, scheme),
              _Panel.output => _output(scheme),
              _Panel.debug => DebugPanel(
                debugger: _debugger,
                root: ws.root,
                onOpen: (path, line, column) => _openFile(path, line: line, column: column),
              ),
              _Panel.diff => DiffView(
                title: _diffTitle,
                lines: _diff,
                onLine: (line) {
                  final path = _diffPath;
                  if (path != null && File(path).existsSync()) _openFile(path, line: line, column: 0);
                },
              ),
              _Panel.terminal => _terminalView(ws),
              _Panel.search => _searchView(ws, scheme),
            },
          ),
        ],
      ),
    );
  }

  Widget _problems(EditorWorkspace ws, ColorScheme scheme) {
    final all = ws.allDiagnostics;
    if (all.isEmpty) return Center(child: Text('No problems in open files.', style: TextStyle(color: scheme.outline)));
    return ListView.builder(
      itemCount: all.length,
      itemExtent: 28,
      itemBuilder: (_, i) {
        final d = all[i];
        return InkWell(
          onTap: () => _openFile(d.path, line: d.line, column: d.column),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(
                  d.severity == 1 ? Icons.error_outline : (d.severity == 2 ? Icons.warning_amber_rounded : Icons.info_outline),
                  size: 15,
                  color: diagnosticColor(d.severity),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(d.message, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                Text(
                  '  ${p.relative(d.path, from: ws.root)}:${d.line + 1}',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static final _sourceRef = RegExp(r'(?:file:///)?((?:[A-Za-z]:)?[\w./\\ -]*?lib[/\\][\w./\\-]+\.dart)[:( ]+(\d+)(?::(\d+))?');

  Widget _output(ColorScheme scheme) {
    final lines = _flutter?.lines ?? const <FlutterLine>[];
    final tool = _tool;
    final total = tool.length + lines.length;
    if (total == 0) {
      return Center(child: Text('Run the app or a Flutter command to see output here.', style: TextStyle(color: scheme.outline)));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_outputScroll.hasClients) _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
    });
    return SelectionArea(
      child: ListView.builder(
        controller: _outputScroll,
        padding: const EdgeInsets.all(8),
        itemCount: total,
        itemBuilder: (_, i) {
          final isTool = i < tool.length;
          final text = isTool ? tool[i] : lines[i - tool.length].text;
          final kind = isTool ? FlutterLineKind.log : lines[i - tool.length].kind;
          final color = switch (kind) {
            FlutterLineKind.error => scheme.error,
            FlutterLineKind.success => scheme.primary,
            FlutterLineKind.info => scheme.outline,
            _ => scheme.onSurface,
          };
          final ref = _sourceRef.firstMatch(text);
          final line = Text(text, style: TextStyle(fontFamily: 'Consolas', fontSize: 12.5, color: color));
          if (ref == null) return line;
          return InkWell(
            onTap: () {
              final ws = _ws;
              if (ws == null) return;
              final raw = ref[1]!.replaceAll('/', Platform.pathSeparator);
              final path = p.isAbsolute(raw) ? raw : p.join(ws.root, raw);
              if (File(path).existsSync()) _openFile(path, line: int.parse(ref[2]!) - 1, column: int.parse(ref[3] ?? '1') - 1);
            },
            child: line,
          );
        },
      ),
    );
  }

  Widget _terminalView(EditorWorkspace ws) {
    final session = _terminal ??= ConsoleSession(
      shell: ShellKind.available().first,
      cwd: ws.root,
      environment: projectEnvironment(ws.root),
      title: p.basename(ws.root),
    );
    return ConsoleView(key: ObjectKey(session), session: session, autofocus: false);
  }

  Widget _searchView(EditorWorkspace ws, ColorScheme scheme) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          height: 34,
          child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search in files (Enter)',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 16),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(9),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
            onSubmitted: _search,
          ),
        ),
      ),
      if (_hitsTitle.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(alignment: Alignment.centerLeft, child: Text(_hitsTitle, style: TextStyle(fontSize: 12, color: scheme.outline))),
        ),
      Expanded(
        child: ListView.builder(
          itemCount: _hits.length,
          itemExtent: 26,
          itemBuilder: (_, i) {
            final h = _hits[i];
            return InkWell(
              onTap: () => _openFile(h.path, line: h.line, column: h.column),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      '${p.relative(h.path, from: ws.root)}:${h.line + 1}  ',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                    Expanded(
                      child: Text(
                        h.text.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.axis, required this.onDrag});

  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onDrag(d.delta.dy),
        child: Container(
          width: horizontal ? 5 : null,
          height: horizontal ? null : 5,
          alignment: Alignment.center,
          child: Container(width: horizontal ? 1 : null, height: horizontal ? null : 1, color: color),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.projects, required this.onOpen, required this.onPick});

  final List<FlutterProject> projects;
  final Future<void> Function(String root, {List<String> files}) onOpen;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        Text('Editor', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Open a Flutter project. Analysis uses its own SDK, including the version pinned by fvm.', style: TextStyle(color: scheme.outline)),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(onPressed: onPick, icon: const Icon(Icons.folder_open), label: const Text('Open folder')),
        ),
        const SizedBox(height: 16),
        for (final pr in projects)
          Card(
            child: ListTile(
              leading: Icon(pr.usesFvm ? Icons.layers_outlined : Icons.flutter_dash),
              title: Text(pr.name),
              subtitle: Text(pr.path),
              trailing: pr.usesFvm ? const Chip(label: Text('fvm'), visualDensity: VisualDensity.compact) : null,
              onTap: () => onOpen(pr.path),
            ),
          ),
        if (projects.isEmpty) Text('Projects from Settings → Project folders show up here.', style: TextStyle(color: scheme.outline)),
      ],
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  const _EmptyEditor({required this.onQuickOpen});

  final VoidCallback onQuickOpen;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.code, size: 40, color: color),
          const SizedBox(height: 8),
          Text('Pick a file on the left', style: TextStyle(color: color)),
          TextButton(onPressed: onQuickOpen, child: const Text('Quick open (Ctrl+P)')),
        ],
      ),
    );
  }
}

class _QuickOpen extends StatefulWidget {
  const _QuickOpen({required this.root, required this.files});

  final String root;
  final List<String> files;

  @override
  State<_QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<_QuickOpen> {
  var _query = '';
  var _index = 0;

  List<String> get _matches {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.files.take(50).toList();
    final byName = <String>[], byPath = <String>[];
    for (final f in widget.files) {
      if (p.basename(f).toLowerCase().contains(q)) {
        byName.add(f);
      } else if (p.relative(f, from: widget.root).toLowerCase().contains(q)) {
        byPath.add(f);
      }
    }
    byName.sort((a, b) => p.basename(a).length.compareTo(p.basename(b).length));
    return [...byName, ...byPath].take(50).toList();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final index = matches.isEmpty ? 0 : _index.clamp(0, matches.length - 1);
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 640,
        height: 440,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is KeyUpEvent) return KeyEventResult.ignored;
                  if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                    setState(() => _index = index + 1);
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() => _index = (index - 1).clamp(0, 49));
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search files by name', isDense: true),
                  onChanged: (v) => setState(() {
                    _query = v;
                    _index = 0;
                  }),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) Navigator.pop(context, matches[index]);
                  },
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemExtent: 30,
                itemBuilder: (_, i) => InkWell(
                  onTap: () => Navigator.pop(context, matches[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    color: i == index ? scheme.primary.withValues(alpha: .14) : null,
                    child: Row(
                      children: [
                        Text(p.basename(matches[i]), style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            p.relative(p.dirname(matches[i]), from: widget.root),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: scheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
