import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/child_processes.dart';
import '../../core/settings.dart';
import '../../core/panels.dart';
import '../../core/theme.dart';
import '../../core/local_builds.dart';
import '../console/console_session.dart';
import '../console/console_view.dart';
import '../../extensions/emulators/avd_service.dart';
import '../../extensions/registry.dart' show ExtensionManager;
import '../devices/cubit/devices_cubit.dart';
import '../devices/models/device.dart';
import '../devices/services/flutter_session.dart';
import '../devices/view/workspace/embedded_scrcpy.dart';
import 'breadcrumbs.dart';
import 'code_pane.dart';
import 'dart_sdk.dart';
import 'dart_settings.dart';
import 'debug_panel.dart';
import 'debugger.dart';
import 'editor_view.dart';
import 'editor_workspace.dart';
import 'file_preview.dart';
import 'file_tree.dart';
import 'fuzzy_files.dart';
import 'log_style.dart';
import 'notices.dart';
import 'project_tools.dart';
import 'packages_view.dart';
import 'palette.dart';
import 'widget_inspector.dart';
import 'source_control.dart';
import 'source_control_view.dart';
import 'tool_tabs.dart';
import '../../core/mono_font.dart';
import '../../core/platform_keys.dart';

const _prefRoot = 'editor_root';
const _prefFiles = 'editor_open_files';
const _desktopDevice = 'windows';

/// What the title bar's menus ask of the Editor, and how the Editor reaches the shell.
class EditorCommands {
  static VoidCallback? openFolder, openFile, quickOpen, saveAll, openExtensions, openSettings, openTerminal, openDartSettings, commandPalette, goToSymbol;

  /// Commands of the window around the Editor, listed in the palette too.
  static List<PaletteItem> Function()? windowCommands;
  static ValueChanged<String>? openRecent;
  static Future<void> Function(String path, {int? line, int? column})? openPath;
}

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

const _pickPackageToUpgrade = 'pick';
const _buildRunnerBuild = 'dart run build_runner build --delete-conflicting-outputs';
const _buildRunnerWatch = 'dart run build_runner watch --delete-conflicting-outputs';
const _buildRunnerClean = 'dart run build_runner clean';

final _ansi = RegExp('\x1B\\[[0-9;]*[A-Za-z]');

/// Every word has to be on the line, in any case. Colors in the log don't count as text.
bool matchesLogSearch(String line, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final text = line.replaceAll(_ansi, '').toLowerCase();
  return words.every(text.contains);
}

/// The Output panel holds the app's log and the last command, in the order they happened:
/// the command's lines start where the log had got to when it started.
(bool isTool, int index) outputRow(int row, int anchor, int toolLines) {
  if (row < anchor) return (false, row);
  if (row < anchor + toolLines) return (true, row - anchor);
  return (false, row - toolLines);
}

enum _Panel { problems, output, terminal, widgets }

/// What the left panel shows. There's one panel, so opening one view replaces the other.
enum _Side { files, git, search, debug, packages }

class _EditorPageState extends State<EditorPage> {
  EditorWorkspace? _ws;
  List<FlutterProject> _projects = const [];
  StreamSubscription<EditTarget>? _revealSub;
  final _paneKeys = <EditorGroup, GlobalKey<CodePaneState>>{};
  CodePaneState? get _pane => _paneKeys[_ws?.focused]?.currentState;
  final _searchFocus = FocusNode(debugLabel: 'search in files');
  final _treeKey = GlobalKey<FileTreeState>();

  var _panel = _Panel.problems;
  var _panelOpen = false;
  double _panelHeight = 240;
  double _treeWidth = 320;

  ConsoleSession? _terminal;
  FlutterSession? _flutter;
  final _debugger = Debugger();
  late final _inspector = WidgetTreeInspector(_debugger);
  final _pageFocus = FocusNode(debugLabel: 'editor page');
  List<EditorNotice> _notices = const [];
  var _noticesHidden = false;
  int? _dismissedPackages;
  Timer? _packagesPoll;
  final _groupsKey = GlobalKey();
  var _mirrorOpen = false;
  double _mirrorWidth = 360;
  SdkVersions? _sdk;
  final _back = <EditTarget>[], _forward = <EditTarget>[];
  final _git = SourceControl();
  Timer? _gitPoll;
  var _side = _Side.files;
  var _pubRevision = 0;
  EditorDocument? _draggingTab;
  var _restoringTabs = false;
  List<Avd> _avds = const [];
  var _sideOpen = true;
  final _diffTabs = <String, AppModule>{};
  String? _debugUri;
  (String, int)? _shownStop;
  String? _device;
  bool get _reloadOnSave => Settings.instance.flag('flutter.hotReloadOnSave');
  int _toolAnchor = 0;
  final _tool = <String>[];
  bool _toolBusy = false;
  String? _toolArgs;
  Process? _toolProcess;
  var _toolStopped = false;
  var _buildRunner = false;
  final _outputScroll = ScrollController();
  final _outputSearch = TextEditingController();

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  var _searchToken = 0;
  List<SearchHit> _hits = const [];
  String _hitsTitle = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    editorSaveAllOnQuit = () async {
      await _ws?.saveAll();
      await _rememberTabs();
    };
    EditorCommands.openFolder = _pickFolder;
    EditorCommands.openFile = _pickFile;
    EditorCommands.openTerminal = () {
      ToolTabs.instance.showEditor();
      // It runs in the project, so with none open there's nowhere for it to start.
      _ws == null ? _toast('Open a folder first') : _showPanel(_Panel.terminal);
    };
    EditorCommands.openDartSettings = () {
      final ws = _ws;
      if (ws != null) return unawaited(_dartSettings(ws));
      ToolTabs.instance.showEditor();
      _toast('Open a folder first');
    };
    EditorCommands.openRecent = _openRecent;
    EditorCommands.openPath = _openFile;
    Settings.instance.addListener(_onSettings);
    EditorCommands.quickOpen = _quickOpen;
    EditorCommands.commandPalette = _commandPalette;
    EditorCommands.goToSymbol = _goToSymbol;
    EditorCommands.saveAll = _saveAll;
    _git.addListener(_rebuild);
    // A pull or a teammate's change can touch pubspec.yaml, with nothing in the Editor being saved.
    _packagesPoll = Timer.periodic(const Duration(seconds: 10), (_) => _checkPackages());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadAvds());
    });
    ToolTabs.instance.addListener(_onTools);
    _debugger
      ..onMessage = ((m) => _flutter?.note(m, error: true))
      ..addListener(_onDebugger);
    _load();
  }

  @override
  void dispose() {
    editorSaveAllOnQuit = null;
    _inspector.dispose();
    EditorCommands.openFolder = EditorCommands.openFile = EditorCommands.openTerminal = EditorCommands.quickOpen = EditorCommands.saveAll = null;
    EditorCommands.openRecent = EditorCommands.openDartSettings = EditorCommands.commandPalette = EditorCommands.goToSymbol = null;
    _revealSub?.cancel();
    _stopTool();
    EditorCommands.openPath = null;
    Settings.instance.removeListener(_onSettings);
    _ws?.removeListener(_rebuild);
    _ws?.dispose();
    _terminal?.dispose();
    _pageFocus.dispose();
    _packagesPoll?.cancel();
    _searchFocus.dispose();
    ToolTabs.instance.removeListener(_onTools);
    _gitPoll?.cancel();
    _git
      ..removeListener(_rebuild)
      ..dispose();
    _flutter?.removeListener(_onFlutter);
    _flutter?.dispose();
    _debugger
      ..removeListener(_onDebugger)
      ..dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _outputScroll.dispose();
    _outputSearch.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  var _syncingTools = false;

  /// [ToolTabs] says which tools are open and which is in front; here they are tabs among the files.
  void _syncTools() {
    final ws = _ws;
    if (ws == null || _syncingTools) return;
    _syncingTools = true;
    try {
      final tools = ToolTabs.instance;
      for (final doc in [...ws.documents]) {
        if (doc.module case final m? when !tools.open.contains(m)) unawaited(ws.close(doc));
      }
      for (final m in tools.open) {
        if (ws.toolDoc(m) == null) ws.openTool(m, activate: false);
      }
      if (tools.active case final m?) {
        ws.openTool(m);
      } else {
        ws.showCode();
      }
    } finally {
      _syncingTools = false;
    }
  }

  void _onTools() {
    _syncTools();
    _rebuild();
  }

  /// A tab clicked, or a file opened, decides what's in front: the title bar and menus follow.
  void _followActiveTab() {
    if (_syncingTools) return;
    final ws = _ws;
    if (ws == null) return;
    final module = ws.active?.module;
    final tools = ToolTabs.instance;
    if (identical(module, tools.active)) return;
    _syncingTools = true;
    try {
      module == null ? tools.showEditor() : tools.show(module);
    } finally {
      _syncingTools = false;
    }
  }

  // A settings.json edited by hand, or in the settings page, applies at once.
  Future<void> _onSettings() async {
    _rebuild();
    final ws = _ws;
    if (ws == null) return;
    final next = await DartSettings.load(ws.root);
    if (!mounted || !identical(ws, _ws)) return;
    if (jsonEncode(next.toServerConfig(ws.root)) != jsonEncode(ws.dart.toServerConfig(ws.root)) || next.formatOnSave != ws.dart.formatOnSave || next.pubGetOnSave != ws.dart.pubGetOnSave || next.organizeImportsOnSave != ws.dart.organizeImportsOnSave || next.fixAllOnSave != ws.dart.fixAllOnSave) {
      ws.useDartSettings(next);
    }
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _load() async {
    await EditorView.load();
    await RecentPaths.load();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // Walks the project folders, maybe on a slow drive; the open project shouldn't wait for that.
    unawaited(
      scanFlutterProjects().then((projects) {
        if (mounted) setState(() => _projects = projects);
      }),
    );
    // DEVKIT_EDITOR=<file> opens straight on that file (README screenshots, demos).
    final envFile = Platform.environment['DEVKIT_EDITOR'];
    final startFile = widget.initialFile ?? envFile;
    final startRoot = widget.initialRoot ?? (envFile == null ? null : _projectRootOf(envFile));
    final root = startRoot ?? (Settings.instance.flag('app.reopenLastProject') ? prefs.getString(_prefRoot) : null);
    if (root == null || !Directory(root).existsSync()) return;
    await _openRoot(root, files: startFile == null ? null : [startFile]);
  }

  Future<void> _rememberTabs() async {
    final ws = _ws;
    // While tabs are coming back one by one, saving would forget the ones still to open.
    if (ws == null || _restoringTabs) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRoot, ws.root);
    final files = ws.documents.where((d) => d.module == null);
    await ProjectTabs(files.map((d) => d.path).toList(), ws.active?.module == null ? ws.active?.path : null).save(ws.root);
  }

  /// What a project had open last time. Before tabs were per project there was one list, for the last project.
  Future<ProjectTabs?> _savedTabs(String root) async {
    final saved = await ProjectTabs.load(root);
    if (saved != null) return saved;
    final prefs = await SharedPreferences.getInstance();
    final oldRoot = prefs.getString(_prefRoot);
    final oldFiles = prefs.getStringList(_prefFiles);
    return oldRoot != null && oldFiles != null && p.equals(oldRoot, root) ? ProjectTabs(oldFiles, null) : null;
  }

  /// Without [files], the project comes back with the tabs it had.
  Future<void> _openRoot(String root, {List<String>? files}) async {
    final old = _ws;
    if (old != null) {
      if (!await _confirmUnsaved(old.documents.where((d) => d.dirty).toList())) return;
      // The active tab can have changed since the last save.
      await _rememberTabs();
      _stopTool();
      old.removeListener(_rebuild);
      old.removeListener(_followActiveTab);
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
      spanBuilderFor: (path) => diagnosticsSpanBuilder(
        () => _ws?.documentAt(path)?.diagnostics ?? const [],
        semantics: () => _ws?.documentAt(path)?.semantics ?? const {},
      ),
    );
    Settings.instance.openProject(root);
    ws.dart = await DartSettings.load(root);
    ws.addListener(_rebuild);
    ws.addListener(_followActiveTab);
    _revealSub = ws.revealRequests.stream.listen((t) {
      // The tab's pane may only appear on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _pane?.reveal(t.line, t.column));
    });
    setState(() {
      _ws = ws;
      _hits = const [];
      _syncTools();
    });
    unawaited(_git.open(root));
    // A diff belongs to the project it was opened from.
    for (final tab in _diffTabs.values) {
      ToolTabs.instance.close(tab);
    }
    _diffTabs.clear();
    unawaited(RecentPaths.add(root));
    _dismissedPackages = null;
    _notices = const [];
    _checkPackages();
    _back.clear();
    _forward.clear();
    unawaited(
      sdkVersionsOf(root).then((v) {
        if (mounted && _ws == ws) setState(() => _sdk = v);
      }),
    );
    final saved = files == null ? await _savedTabs(root) : null;
    if (File(p.join(root, 'pubspec.yaml')).existsSync()) unawaited(ws.startAnalyzer());
    _restoringTabs = true;
    for (final f in files ?? saved?.files ?? const <String>[]) {
      // Another project may have been opened meanwhile; its tabs are its own.
      if (_ws != ws) break;
      if (File(f).existsSync()) await _openFile(f);
    }
    if (_ws != ws) return;
    _restoringTabs = false;
    final active = saved?.active == null ? null : ws.documentAt(saved!.active!);
    if (active != null) ws.activate(active);
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
    if (doc.module case final m?) return ToolTabs.instance.close(m);
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
    isProjectPubspec(doc.path, ws.root) ? _onPubspecSaved(ws) : _checkPackages();
    final f = _flutter;
    if (_reloadOnSave && doc.languageId == 'dart' && f != null && f.canReload) unawaited(f.reload());
  }

  Future<void> _saveAll() async {
    final ws = _ws;
    if (ws == null) return;
    final pubspec = ws.documents.any((d) => d.dirty && isProjectPubspec(d.path, ws.root));
    await ws.saveAll();
    if (pubspec) _onPubspecSaved(ws);
  }

  void _onPubspecSaved(EditorWorkspace ws) {
    if (ws.dart.pubGetOnSave && packagesOutOfSyncSince(ws.root) != null) {
      unawaited(_runTool('pub get'));
    } else {
      _checkPackages();
    }
  }

  // ---------------------------------------------------------------- keys

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final key = e.logicalKey;
    void Function()? action;
    if (key == LogicalKeyboardKey.f5 && !hw.isPrimaryPressed) {
      action = hw.isShiftPressed ? () => _flutter?.stop() : (_debugger.paused ? _debugger.resume : _run);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyP) {
      action = _commandPalette;
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyO) {
      action = _goToSymbol;
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyG) {
      action = () => _showSide(_Side.git);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyE) {
      action = () => _showSide(_Side.files);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyD) {
      action = () => _showSide(_Side.debug);
    } else if (hw.isPrimaryPressed && key == LogicalKeyboardKey.backslash) {
      action = _splitActive;
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyM) {
      action = () => _showPanel(_Panel.problems);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyU) {
      action = () => _showPanel(_Panel.output);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyB) {
      action = () => _showSide(_Side.packages);
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyV) {
      final doc = _ws?.active;
      action = doc != null && doc.canPreview ? doc.togglePreview : null;
    } else if (hw.isPrimaryPressed && hw.isShiftPressed && key == LogicalKeyboardKey.keyX) {
      action = EditorCommands.openExtensions;
    } else if (hw.isPrimaryPressed && key == LogicalKeyboardKey.comma) {
      action = EditorCommands.openSettings;
    } else if (hw.isControlPressed && (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.pageUp)) {
      final back = key == LogicalKeyboardKey.pageUp || (key == LogicalKeyboardKey.tab && hw.isShiftPressed);
      action = () => _cycleTab(back ? -1 : 1);
    } else if (hw.isPrimaryPressed && hw.isAltPressed && key == LogicalKeyboardKey.keyM) {
      action = () => setState(() => _mirrorOpen = !_mirrorOpen);
    } else if (hw.isAltPressed && key == LogicalKeyboardKey.keyZ) {
      action = EditorView.toggleWordWrap;
    } else if (Platform.isMacOS && hw.isControlPressed && key == LogicalKeyboardKey.backquote) {
      action = () => _showPanel(_Panel.terminal);
    } else if (Platform.isMacOS && hw.isControlPressed && key == LogicalKeyboardKey.minus) {
      // Option+arrows move by word there, so back and forward live where VS Code puts them on a Mac.
      action = hw.isShiftPressed ? () => _navigate(_forward, _back) : () => _navigate(_back, _forward);
    } else if (!Platform.isMacOS && hw.isAltPressed && key == LogicalKeyboardKey.arrowLeft) {
      action = () => _navigate(_back, _forward);
    } else if (!Platform.isMacOS && hw.isAltPressed && key == LogicalKeyboardKey.arrowRight) {
      action = () => _navigate(_forward, _back);
    } else if (key == LogicalKeyboardKey.f8) {
      action = () => _nextProblem(hw.isShiftPressed ? -1 : 1);
    } else if (key == LogicalKeyboardKey.f6) {
      action = _debugger.pause;
    } else if (key == LogicalKeyboardKey.f9) {
      action = () => _pane?.toggleBreakpointAtCursor();
    } else if (key == LogicalKeyboardKey.f10) {
      action = _debugger.stepOver;
    } else if (key == LogicalKeyboardKey.f11) {
      action = hw.isShiftPressed ? _debugger.stepOut : _debugger.stepInto;
    } else if (hw.isPrimaryPressed) {
      if (key == LogicalKeyboardKey.keyS) action = hw.isShiftPressed ? _saveAll : _save;
      if (key == LogicalKeyboardKey.keyW) action = _ws?.active == null ? null : () => _closeTab(_ws!.active!);
      if (key == LogicalKeyboardKey.keyP) action = _quickOpen;
      if (key == LogicalKeyboardKey.keyG) action = _goToLine;
      if (key == LogicalKeyboardKey.keyB) action = _toggleSide;
      if (key == LogicalKeyboardKey.keyO) action = _pickFile;
      if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd) action = () => EditorView.zoom(1);
      if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) action = () => EditorView.zoom(-1);
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) action = EditorView.resetZoom;
      if (key == LogicalKeyboardKey.keyJ) action = () => setState(() => _panelOpen = !_panelOpen);
      if (key == LogicalKeyboardKey.backquote) action = () => _showPanel(_Panel.terminal);
      if (hw.isShiftPressed && key == LogicalKeyboardKey.keyF) action = () => _showSide(_Side.search);
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

  /// A file from outside the open project opens its project too, when nothing is open yet.
  Future<void> _openPicked(String path) async {
    if (_ws == null) await _openRoot(_projectRootOf(path));
    await _openFile(path);
  }

  Future<void> _pickFile() async {
    final file = await openFile();
    if (file != null) await _openPicked(file.path);
  }

  Future<void> _openRecent(String path) async {
    if (Directory(path).existsSync()) return _openRoot(path);
    await RecentPaths.remove(path);
    _toast('${p.basename(path)} is no longer there');
  }

  Future<void> _quickOpen() async {
    final ws = _ws;
    if (ws == null) return;
    final files = await listProjectFiles(ws.root);
    if (!mounted) return;
    final picked = await showDialog<(String, int?)>(
      context: context,
      builder: (_) => _QuickOpen(root: ws.root, files: files, recent: [for (final d in ws.documents) if (d.module == null) d.path]),
    );
    if (picked == null) return;
    if (picked.$1.startsWith('@')) return _goToSymbol(query: picked.$1.substring(1));
    await _openFile(picked.$1, line: picked.$2, column: picked.$2 == null ? null : 0);
  }

  Future<void> _commandPalette() {
    final ws = _ws;
    return showPalette(
      context,
      hint: 'Type a command, or @ to find a method in this file',
      empty: 'No commands match',
      prefixes: {'@': (rest) => unawaited(_goToSymbol(query: rest))},
      items: [
        PaletteItem('Go to File', _quickOpen, keys: 'Ctrl+P', icon: Icons.search, group: 'Go'),
        PaletteItem('Go to Line', _goToLine, keys: 'Ctrl+G', icon: Icons.format_list_numbered, group: 'Go'),
        PaletteItem('Go to Symbol in File', _goToSymbol, keys: 'Ctrl+Shift+O', icon: Icons.data_object, group: 'Go'),
        PaletteItem('Next Problem', () => _nextProblem(1), keys: 'F8', icon: Icons.arrow_downward, group: 'Go'),
        PaletteItem('Previous Problem', () => _nextProblem(-1), keys: 'Shift+F8', icon: Icons.arrow_upward, group: 'Go'),
        PaletteItem('Save', _save, keys: 'Ctrl+S', icon: Icons.save_outlined, group: 'File'),
        PaletteItem('Save All', _saveAll, keys: 'Ctrl+Shift+S', icon: Icons.save_outlined, group: 'File'),
        PaletteItem('Close Tab', () {
          if (_ws?.active case final doc?) _closeTab(doc);
        }, keys: 'Ctrl+W', icon: Icons.close, group: 'File'),
        PaletteItem('Open Folder', _pickFolder, icon: Icons.folder_open, group: 'File'),
        PaletteItem('Open File', _pickFile, keys: 'Ctrl+O', icon: Icons.file_open_outlined, group: 'File'),
        PaletteItem('Format Document', _format, keys: 'Shift+Alt+F', icon: Icons.format_align_left, group: 'Editor'),
        PaletteItem('Split Editor', _splitActive, keys: 'Ctrl+\\', icon: Icons.vertical_split_outlined, group: 'Editor'),
        PaletteItem('Toggle Word Wrap', EditorView.toggleWordWrap, keys: 'Alt+Z', icon: Icons.wrap_text, group: 'Editor'),
        PaletteItem('Zoom In', () => EditorView.zoom(1), keys: 'Ctrl+=', icon: Icons.zoom_in, group: 'Editor'),
        PaletteItem('Zoom Out', () => EditorView.zoom(-1), keys: 'Ctrl+-', icon: Icons.zoom_out, group: 'Editor'),
        PaletteItem('Reset Zoom', EditorView.resetZoom, keys: 'Ctrl+0', icon: Icons.zoom_out_map, group: 'Editor'),
        if (_ws?.active case final doc? when doc.canPreview)
          PaletteItem(doc.previewing ? 'Show Code' : 'Open Preview', doc.togglePreview, keys: 'Ctrl+Shift+V', icon: Icons.visibility_outlined, group: 'Editor'),
        PaletteItem('Show Files', () => _showSide(_Side.files), keys: 'Ctrl+Shift+E', icon: Icons.description_outlined, group: 'View'),
        PaletteItem('Show Source Control', () => _showSide(_Side.git), keys: 'Ctrl+Shift+G', icon: Icons.account_tree_outlined, group: 'View'),
        PaletteItem('Show Search', () => _showSide(_Side.search), keys: 'Ctrl+Shift+F', icon: Icons.search, group: 'View'),
        PaletteItem('Show Packages', () => _showSide(_Side.packages), keys: 'Ctrl+Shift+B', icon: Icons.inventory_2_outlined, group: 'View'),
        PaletteItem('Show Run and Debug', () => _showSide(_Side.debug), keys: 'Ctrl+Shift+D', icon: Icons.bug_report_outlined, group: 'View'),
        PaletteItem('Toggle Side Panel', _toggleSide, keys: 'Ctrl+B', icon: Icons.view_sidebar_outlined, group: 'View'),
        PaletteItem('Show Problems', () => _showPanel(_Panel.problems), keys: 'Ctrl+Shift+M', icon: Icons.error_outline, group: 'View'),
        PaletteItem('Show Output', () => _showPanel(_Panel.output), keys: 'Ctrl+Shift+U', icon: Icons.notes, group: 'View'),
        PaletteItem('Show Terminal', () => _showPanel(_Panel.terminal), keys: 'Ctrl+`', icon: Icons.terminal, group: 'View'),
        PaletteItem('Show Widget Inspector', () => _showPanel(_Panel.widgets), icon: Icons.account_tree_outlined, group: 'View'),
        PaletteItem('Toggle Bottom Panel', () => setState(() => _panelOpen = !_panelOpen), keys: 'Ctrl+J', icon: Icons.web_asset, group: 'View'),
        PaletteItem('Toggle Device Screen', () => setState(() => _mirrorOpen = !_mirrorOpen), keys: 'Ctrl+Alt+M', icon: Icons.phone_android, group: 'View'),
        PaletteItem('Run', _run, keys: 'F5', icon: Icons.play_arrow, group: 'Run'),
        PaletteItem('Stop', () => _flutter?.stop(), keys: 'Shift+F5', icon: Icons.stop, group: 'Run'),
        PaletteItem('Hot Reload', () => _flutter?.reload(full: false), keys: 'Ctrl+F5', icon: Icons.bolt, group: 'Run'),
        PaletteItem('Hot Restart', () => _flutter?.reload(full: true), keys: 'Ctrl+Shift+F5', icon: Icons.restart_alt, group: 'Run'),
        PaletteItem('Toggle Breakpoint', () => _pane?.toggleBreakpointAtCursor(), keys: 'F9', icon: Icons.circle_outlined, group: 'Debug'),
        PaletteItem('Continue', _debugger.resume, icon: Icons.play_circle_outline, group: 'Debug'),
        PaletteItem('Pause', _debugger.pause, keys: 'F6', icon: Icons.pause_circle_outline, group: 'Debug'),
        PaletteItem('Step Over', _debugger.stepOver, keys: 'F10', icon: Icons.redo, group: 'Debug'),
        PaletteItem('Step Into', _debugger.stepInto, keys: 'F11', icon: Icons.south_east, group: 'Debug'),
        PaletteItem('Step Out', _debugger.stepOut, keys: 'Shift+F11', icon: Icons.north_east, group: 'Debug'),
        PaletteItem('Toggle Line Blame', EditorView.toggleLineBlame, icon: Icons.person_search_outlined, group: 'Git'),
        PaletteItem('Discard All Changes', () => unawaited(confirmDiscardAll(context, _git)), icon: Icons.undo, group: 'Git'),
        PaletteItem('Flutter Versions (FVM)', () => unawaited(_showFvm()), icon: Icons.layers_outlined, group: 'Flutter'),
        PaletteItem('Firebase', () => unawaited(_showFirebase()), icon: Icons.local_fire_department_outlined, group: 'Flutter'),
        PaletteItem('Pub Get', () => unawaited(_runTool('pub get')), icon: Icons.download_outlined, group: 'Flutter'),
        PaletteItem('Pub Upgrade', () => unawaited(_runTool('pub upgrade')), icon: Icons.upgrade, group: 'Flutter'),
        PaletteItem('Pub Upgrade Package…', () => unawaited(_upgradeOnePackage()), icon: Icons.upgrade, group: 'Flutter'),
        PaletteItem('Pub Upgrade to Latest Majors', () => unawaited(_runTool('pub upgrade --major-versions')), icon: Icons.upgrade, group: 'Flutter'),
        PaletteItem('Pub Outdated', () => unawaited(_runTool('pub outdated')), icon: Icons.update, group: 'Flutter'),
        if (_buildRunner) ...[
          PaletteItem('Generate Code (build_runner)', () => unawaited(_runTool(_buildRunnerBuild)), icon: Icons.auto_fix_high_outlined, group: 'Flutter'),
          PaletteItem('Generate on Every Save (build_runner watch)', () => unawaited(_runTool(_buildRunnerWatch)), icon: Icons.auto_fix_high_outlined, group: 'Flutter'),
        ],
        PaletteItem('Sort pubspec.yaml A–Z', () => unawaited(_sortPubspec()), icon: Icons.sort_by_alpha, group: 'Flutter'),
        PaletteItem('Add Package', () => _showSide(_Side.packages), icon: Icons.add, group: 'Flutter'),
        PaletteItem('Clean', () => unawaited(_runTool('clean')), icon: Icons.cleaning_services_outlined, group: 'Flutter'),
        if (ws != null) PaletteItem('Dart Settings', () => unawaited(_dartSettings(ws)), icon: Icons.tune, group: 'Flutter'),
        ...?EditorCommands.windowCommands?.call(),
        for (final t in appThemes) PaletteItem(t.name, () => setAppTheme(t), group: 'Theme', icon: Icons.palette_outlined),
      ],
    );
  }

  Future<void> _goToSymbol({String query = ''}) async {
    final ws = _ws;
    final doc = ws?.active;
    if (doc == null) return _toast('Open a file first');
    final path = doc.path;
    PaletteItem row(DocSymbol s, String? parent) => PaletteItem(
      s.name,
      () => unawaited(_jump(EditTarget(path, s.line, s.column))),
      detail: parent,
      keys: ':${s.line + 1}',
      icon: symbolIcon(s.kind),
    );
    Iterable<PaletteItem> flatten(List<DocSymbol> symbols, String? parent) sync* {
      for (final s in symbols) {
        yield row(s, parent);
        yield* flatten(s.children, s.name);
      }
    }

    return showPalette(
      context,
      hint: 'Go to method or symbol in ${p.basename(path)}',
      query: query,
      empty: doc.symbols.isEmpty ? 'No symbols yet. The analyzer may still be reading this file.' : 'No symbols match',
      items: flatten(doc.symbols, null).toList(),
    );
  }

  Future<void> _goToLine() async {
    final pane = _pane;
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

  FlutterProject _project(EditorWorkspace ws) {
    final sdk = Settings.instance.text('flutter.sdkPath').trim();
    return FlutterProject(p.basename(ws.root), ws.root, '', usesFvm: projectUsesFvm(ws.root), flutterSdk: sdk.isNotEmpty && Directory(sdk).existsSync() ? sdk : null);
  }

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
    _toolAnchor = _flutter!.lines.length;
    final blocked = Settings.instance.blockedRunArgs();
    if (blocked.isNotEmpty) _toast('Left out of Run, because of its special characters: ${blocked.join(' ')}');
    _showPanel(_Panel.output);
    // Pausing at start gets the breakpoints in before main runs; the debugger resumes once they're set.
    await _flutter!.start(_project(ws), attach: false, extraArgs: [...Settings.instance.runArgs(), if (_debugger.hasBreakpoints) '--start-paused']);
  }

  // A click on a panel can leave nothing focused, and then F9 or F10 reach no one.
  Widget _keepingKeys(Widget child) => Listener(
    onPointerUp: (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageFocus.hasFocus && FocusManager.instance.primaryFocus is FocusScopeNode) _pageFocus.requestFocus();
    }),
    child: child,
  );

  EditTarget? _here() {
    final doc = _ws?.active;
    if (doc == null) return null;
    final sel = doc.controller.selection;
    return EditTarget(doc.path, sel.extentIndex, sel.extentOffset);
  }

  /// A jump Alt+Left can come back from.
  Future<void> _jump(EditTarget target) async {
    final here = _here();
    if (here != null) _back.add(here);
    _forward.clear();
    await _openFile(target.path, line: target.line, column: target.column);
  }

  void _navigate(List<EditTarget> from, List<EditTarget> to) {
    if (from.isEmpty) return;
    final here = _here();
    if (here != null) to.add(here);
    final t = from.removeLast();
    unawaited(_openFile(t.path, line: t.line, column: t.column));
  }

  void _cycleTab(int delta) {
    final ws = _ws, active = ws?.active;
    if (ws == null || active == null) return;
    final docs = ws.focused.docs;
    if (docs.length > 1) ws.activate(docs[(docs.indexOf(active) + delta) % docs.length]);
  }

  void _nextProblem(int delta) {
    final ws = _ws;
    if (ws == null) return;
    final all = ws.allDiagnostics;
    if (all.isEmpty) return;
    final here = _here();
    final at = here == null ? -1 : all.indexWhere((d) => p.equals(d.path, here.path) && d.line == here.line);
    final d = all[(at + delta) % all.length];
    unawaited(_jump(EditTarget(d.path, d.line, d.column)));
  }

  void _showSide(_Side side) {
    ToolTabs.instance.showEditor();
    setState(() {
      _side = side;
      _sideOpen = true;
    });
    _syncGitPoll();
    if (side == _Side.search) _searchFocus.requestFocus();
  }

  void _toggleSide() {
    setState(() => _sideOpen = !_sideOpen);
    _syncGitPoll();
  }

  void _syncGitPoll() {
    _gitPoll?.cancel();
    _gitPoll = null;
    if (_side != _Side.git || !_sideOpen) return;
    unawaited(_git.refresh());
    // Terminals and other tools change the repo too.
    _gitPoll = Timer.periodic(const Duration(seconds: 4), (_) => _git.refresh());
  }

  void _showDiff(GitChange change, bool staged) {
    final path = _git.absolute(change.path);
    final tab = _diffTabs.putIfAbsent(
      '$path:$staged',
      () => AppModule(
        '${p.basename(path)} (diff)',
        Icons.compare_arrows,
        SideBySideDiff(
          git: _git,
          change: change,
          staged: staged,
          onLine: (line) {
            ToolTabs.instance.showEditor();
            if (File(path).existsSync()) unawaited(_jump(EditTarget(path, line, 0)));
          },
        ),
      ),
    );
    ToolTabs.instance.show(tab);
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
    _showSide(_Side.debug);
    unawaited(_openFile(path, line: frame.line, column: frame.column));
  }

  void _checkPackages() {
    final ws = _ws;
    if (ws == null || !mounted) return;
    final buildRunner = usesBuildRunner(ws.root);
    if (buildRunner != _buildRunner) setState(() => _buildRunner = buildRunner);
    final since = _toolBusy ? null : packagesOutOfSyncSince(ws.root);
    final show = since != null && since != _dismissedPackages;
    final showing = _notices.any((n) => n.id == 'packages');
    // Once up, it waits to be closed, even if the packages catch up by themselves meanwhile.
    if (!show || showing) return;
    setState(() {
      _notices = [
        for (final n in _notices)
          if (n.id != 'packages') n,
        if (show)
          EditorNotice(
            id: 'packages',
            icon: Icons.inventory_2_outlined,
            source: 'Dart',
            message: 'Some packages are missing or out of sync for ${p.basename(ws.root)}. Run pub get to update them.',
            actions: [
              NoticeAction('Run pub get', () {
                _dismissNotice('packages');
                unawaited(_runTool('pub get'));
              }),
            ],
          ),
      ];
      if (show) _noticesHidden = false;
    });
  }

  void _dismissNotice(String id) {
    if (id == 'packages') _dismissedPackages = _ws == null ? null : packagesOutOfSyncSince(_ws!.root);
    setState(() => _notices = [
      for (final n in _notices)
        if (n.id != id) n,
    ]);
  }

  /// [args] is a command for `flutter`, unless it starts with `dart`.
  Future<bool> _runTool(String args) {
    final words = args.split(' ');
    return _runCommand(words.first == 'dart' ? words : ['flutter', ...words]);
  }

  /// Runs in the Output panel, and says whether it worked. Each word is passed as it is.
  Future<bool> _runCommand(List<String> words) async {
    final ws = _ws;
    if (ws == null || _toolBusy) return false;
    await ws.saveAll();
    final args = (words.first == 'flutter' ? words.skip(1) : words).join(' ');
    final DartCommand command = switch (words.first) {
      'flutter' => flutterCommand(ws.root),
      'dart' => projectUsesFvm(ws.root) ? DartCommand('fvm', const ['dart'], runInShell: Platform.isWindows) : dartCommand(ws.root),
      _ => DartCommand(words.first, const [], runInShell: Platform.isWindows),
    };
    final arguments = [...command.args, ...words.skip(1)];
    final line = '${command.exe} ${arguments.join(' ')}';
    var ok = false;
    _toolAnchor = _flutter?.lines.length ?? 0;
    setState(() {
      _toolBusy = true;
      _toolArgs = args;
      _toolStopped = false;
      _tool
        ..clear()
        ..add('\$ $line');
    });
    _showPanel(_Panel.output);
    try {
      final process = await Process.start(command.exe, arguments, workingDirectory: ws.root, runInShell: Platform.isWindows);
      _toolProcess = process;
      // Nobody can answer a question asked here, and a waiting program would never end.
      if (!args.contains('watch')) unawaited(process.stdin.close());
      void add(String l) {
        if (mounted) setState(() => _tool.add(l));
      }

      final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(add);
      final err = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(add);
      final code = await process.exitCode;
      await Future.wait([out, err]);
      ok = code == 0 && !_toolStopped;
      add(_toolStopped ? 'Stopped' : (code == 0 ? '✓ Done' : '✗ Exit code $code'));
    } on Exception catch (e) {
      if (mounted) setState(() => _tool.add('Failed: $e'));
    }
    if (mounted) {
      setState(() {
        _toolBusy = false;
        _toolArgs = null;
        if (args.startsWith('pub')) {
          _pubRevision++;
          // Done what it asked. If that didn't help, the check below brings it back.
          _notices = [
            for (final n in _notices)
              if (n.id != 'packages') n,
          ];
        }
      });
    }
    _toolProcess = null;
    // Generated files are new to the tree, and it only looks when asked.
    if (args.contains('build_runner') || args.contains('flutterfire')) unawaited(_treeKey.currentState?.refresh());
    _checkPackages();
    return ok;
  }

  // Watch mode only ever ends this way.
  void _stopTool() {
    final process = _toolProcess;
    if (process == null) return;
    _toolStopped = true;
    unawaited(ChildProcesses.killTree(process));
  }

  Future<void> _upgradeOnePackage() async {
    final ws = _ws;
    if (ws == null || _toolBusy) return;
    await ws.saveAll();
    final List<PubPackage> packages;
    try {
      final lock = File(p.join(ws.root, 'pubspec.lock'));
      packages = parseDeclaredPackages(File(p.join(ws.root, 'pubspec.yaml')).readAsStringSync(), lock.existsSync() ? lock.readAsStringSync() : null);
    } on FileSystemException catch (e) {
      return _toast('pubspec.yaml: ${e.message}');
    }
    if (!mounted) return;
    final names = packages.where((x) => x.fromPubDev && isValidPubName(x.name)).toList()..sort((a, b) => a.name.compareTo(b.name));
    await showPalette(
      context,
      hint: 'Package to upgrade',
      empty: 'No packages match',
      items: [
        for (final x in names)
          PaletteItem(x.name, () => unawaited(_runTool('pub upgrade ${x.name}')), detail: x.current, icon: Icons.inventory_2_outlined),
      ],
    );
  }

  Future<void> _showFvm() async {
    final ws = _ws;
    if (ws == null) return _toast('Open a folder first');
    await showDialog<void>(
      context: context,
      builder: (_) => FvmDialog(
        root: ws.root,
        onRun: (command) async {
          final ok = await _runCommand(command);
          // The analyzer, the terminal and Run all have to move to the new SDK, as reopening does.
          if (ok && command[1] == 'use' && mounted && identical(ws, _ws)) await _openRoot(ws.root);
        },
      ),
    );
  }

  Future<void> _showFirebase() async {
    final ws = _ws;
    if (ws == null) return _toast('Open a folder first');
    await showDialog<void>(
      context: context,
      builder: (_) => FirebaseDialog(
        root: ws.root,
        onRun: (command) => unawaited(_runCommand(command)),
      ),
    );
  }

  Future<void> _sortPubspec() async {
    final ws = _ws;
    if (ws == null || _toolBusy) return;
    await ws.saveAll();
    final file = File(p.join(ws.root, 'pubspec.yaml'));
    try {
      final before = await file.readAsString();
      final after = sortPubspecDependencies(before);
      if (after == before) return _toast('pubspec.yaml is already sorted');
      await file.writeAsString(after, flush: true);
    } on FileSystemException catch (e) {
      return _toast('pubspec.yaml: ${e.message}');
    }
    await ws.documentAt(file.path)?.reloadIfChanged();
    await _runTool('pub get');
  }

  // A beat after typing stops, so a whole word doesn't walk the project once per letter.
  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    final text = query.trim();
    if (text.length >= 2) {
      _searchDebounce = Timer(const Duration(milliseconds: 250), () => _search(text));
      return;
    }
    _searchToken++;
    setState(() {
      _hits = const [];
      _hitsTitle = '';
      _searching = false;
    });
  }

  Future<void> _search(String query) async {
    final ws = _ws;
    _searchDebounce?.cancel();
    final token = ++_searchToken;
    if (ws == null || query.trim().isEmpty) return;
    setState(() => _searching = true);
    final hits = await searchInFiles(ws.root, query.trim());
    // A slower, older search must not replace what's been typed since.
    if (!mounted || token != _searchToken) return;
    setState(() {
      _hits = hits;
      _hitsTitle = '${hits.length}${hits.length >= 1000 ? '+' : ''} results for "${query.trim()}"';
      _searching = false;
    });
  }

  Future<void> _showReferences(List<EditTarget> refs) async {
    _searchDebounce?.cancel();
    _searchToken++;
    final hits = await _ws?.referenceHits(refs) ?? const <SearchHit>[];
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _hitsTitle = '${hits.length} references';
    });
    _showSide(_Side.search);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final ws = _ws;
    final scheme = Theme.of(context).colorScheme;
    if (ws == null) {
      return _workArea(
        Padding(
          padding: const EdgeInsets.fromLTRB(panelGap, 0, panelGap, panelGap),
          child: PanelCard(child: _Welcome(projects: _projects, onOpen: _openRoot, onPick: _pickFolder)),
        ),
        scheme,
      );
    }
    final windowWidth = MediaQuery.sizeOf(context).width;
    // In a small window the panel gives way first: an editor narrower than its gutter is no use.
    final mirror = _mirrorOpen ? _mirrorWidth.clamp(0, windowWidth * .4) : 0;
    final roomLeft = windowWidth - 60 - mirror - ws.groups.length * 200;
    final sideWidth = min(_treeWidth, min(windowWidth * .4, roomLeft)).clamp(0, 600).toDouble();
    return _keepingKeys(Focus(
      focusNode: _pageFocus,
      onKeyEvent: (_, e) => _onKey(e),
      child: Column(
        children: [
          _toolbar(ws, scheme),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
            Padding(
              padding: const EdgeInsets.only(right: panelGap),
              child: Row(
              children: [
                _activityBar(scheme),
                // Kept mounted when closed, so the tree's open folders survive being hidden.
                TweenAnimationBuilder<double>(
                  tween: Tween(end: _sideOpen ? 1 : 0),
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOutCubic,
                  builder: (_, t, child) => Offstage(
                    offstage: t == 0,
                    child: ClipRect(
                      child: SizedBox(
                        width: sideWidth * t,
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          // Squeezed further than this, the panel is cut off rather than crushed.
                          minWidth: max(sideWidth, 240),
                          maxWidth: max(sideWidth, 240),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: max(sideWidth, 240),
                    child: PanelCard(child: IndexedStack(
                      index: _side.index,
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
                        _searchView(ws, scheme),
                        DebugPanel(
                          debugger: _debugger,
                          root: ws.root,
                          onOpen: (path, line, column) => _openFile(path, line: line, column: column),
                        ),
                        PackagesView(
                          key: ValueKey(ws.root),
                          root: ws.root,
                          visible: _sideOpen && _side == _Side.packages,
                          busy: _toolBusy,
                          revision: _pubRevision,
                          onRun: (args) => unawaited(_runTool(args)),
                          onSort: () => unawaited(_sortPubspec()),
                        ),
                      ],
                    )),
                  ),
                ),
                if (_sideOpen)
                  _DragHandle(
                    axis: Axis.horizontal,
                    onDrag: (d) => setState(() => _treeWidth = (_treeWidth + d).clamp(160, 600)),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      if (ws.lspError != null) _errorBanner(ws.lspError!, scheme),
                      Expanded(child: _groups(ws, scheme)),
                      TweenAnimationBuilder<double>(
                        tween: Tween(end: _panelOpen ? 1 : 0),
                        duration: const Duration(milliseconds: 130),
                        curve: Curves.easeOutCubic,
                        builder: (_, t, _) => t == 0
                            ? const SizedBox.shrink()
                            : ClipRect(
                                child: SizedBox(
                                  height: (_panelHeight + 6) * t,
                                  child: OverflowBox(
                                    alignment: Alignment.topCenter,
                                    minHeight: _panelHeight + 6,
                                    maxHeight: _panelHeight + 6,
                                    child: Column(
                                      children: [
                                        _DragHandle(
                                          axis: Axis.vertical,
                                          onDrag: (d) => setState(() => _panelHeight = (_panelHeight - d).clamp(100, 700)),
                                        ),
                                        Expanded(child: _bottomPanel(ws, scheme)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                if (_mirrorOpen) ...[
                  _DragHandle(
                    axis: Axis.horizontal,
                    onDrag: (d) => setState(() => _mirrorWidth = (_mirrorWidth - d).clamp(220, 900)),
                  ),
                  SizedBox(width: _mirrorWidth.clamp(0, windowWidth * .4).toDouble(), child: PanelCard(child: _mirror(scheme))),
                ],
              ],
            ),
            ),
                if (_notices.isNotEmpty && !_noticesHidden)
                  Positioned(
                    right: 12 + (_mirrorOpen ? _mirrorWidth.clamp(0, windowWidth * .4).toDouble() : 0),
                    bottom: 12,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: (windowWidth - 24).clamp(0, 420).toDouble()),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final n in _notices)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: NoticeCard(key: ValueKey(n.id), notice: n, onDismiss: () => _dismissNotice(n.id)),
                            ),
                        ],
                      ),
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

  Future<void> _dartSettings(EditorWorkspace ws) async {
    final picked = await showDialog<DartSettings>(
      context: context,
      builder: (_) => _DartSettingsDialog(root: ws.root, settings: ws.dart),
    );
    if (picked != null) await ws.applyDartSettings(picked);
  }

  Widget _activityBar(ColorScheme scheme) {
    final shape = BorderRadius.circular(9);
    // The count sits under the icon, so no number can ever cover it.
    Widget item(String tip, IconData icon, bool selected, VoidCallback onTap, {String? badge}) => Tooltip(
      message: tip,
      preferBelow: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Material(
          color: selected ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            child: SizedBox(
              height: badge == null ? 42 : 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22, color: selected ? scheme.primary : scheme.onSurfaceVariant),
                  if (badge != null)
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(6)),
                      child: Text(badge, style: TextStyle(fontSize: 9, height: 1.3, fontWeight: FontWeight.w700, color: scheme.onPrimary)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Clicking the open view closes the side panel, as in VS Code.
    void side(_Side which) => _sideOpen && _side == which ? _toggleSide() : _showSide(which);
    final changes = _git.changes.length;
    return Material(
      color: canvasOf(scheme),
      child: SizedBox(
        width: 60,
        child: Column(
        children: [
          // A short window scrolls these, and Extensions stays in reach below them.
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                child: Column(
                  children: [
          item(platformKeys('Files (Ctrl+Shift+E)'), Icons.description_outlined, _sideOpen && _side == _Side.files, () => side(_Side.files)),
          item(
            platformKeys('Source Control (Ctrl+Shift+G)'),
            Icons.call_split,
            _sideOpen && _side == _Side.git,
            () => side(_Side.git),
            badge: changes == 0 ? null : (changes > 99 ? '99+' : '$changes'),
          ),
          item(platformKeys('Search (Ctrl+Shift+F)'), Icons.search, _sideOpen && _side == _Side.search, () => side(_Side.search)),
          item(
            platformKeys('Run and Debug (Ctrl+Shift+D)'),
            Icons.bug_report_outlined,
            _sideOpen && _side == _Side.debug,
            () => side(_Side.debug),
            badge: _debugger.paused ? '!' : null,
          ),
          item(platformKeys('Packages (Ctrl+Shift+B)'), Icons.inventory_2_outlined, _sideOpen && _side == _Side.packages, () => side(_Side.packages)),
          item('Flutter Versions (FVM)', Icons.layers_outlined, false, () => unawaited(_showFvm())),
          item('Firebase', Icons.local_fire_department_outlined, false, () => unawaited(_showFirebase())),
                  ],
                ),
              ),
            ),
          ),
          item(platformKeys('Extensions (Ctrl+Shift+X)'), Icons.extension_outlined, false, () => EditorCommands.openExtensions?.call()),
        ],
      ),
      ),
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
    final narrow = MediaQuery.sizeOf(context).width < 760;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: canvasOf(scheme),
      child: Row(
        children: [
          // Takes all the room that's left, instead of sharing it with a Spacer.
          Expanded(child: Row(children: [Flexible(child: PopupMenuButton<String>(
            tooltip: 'Switch project',
            onSelected: (v) => v.isEmpty ? _pickFolder() : _openRoot(v),
            itemBuilder: (_) => [
              for (final pr in _projects) PopupMenuItem(height: 30, value: pr.path, child: Text(pr.name)),
              const PopupMenuDivider(),
              const PopupMenuItem(height: 30, value: '', child: Text('Open folder…')),
            ],
            child: Row(
              children: [
                if (!narrow) ...[
                  const Icon(Icons.folder_open_outlined, size: 18),
                  const SizedBox(width: 6),
                ],
                Flexible(child: Text(p.basename(ws.root), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          )),
          if (fvm && !narrow)
            Tooltip(
              message: 'Flutter SDK pinned by fvm: ${flutterSdkOf(ws.root) ?? 'not installed yet'}. Click to change it.',
              child: GestureDetector(onTap: () => unawaited(_showFvm()), child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('fvm', style: TextStyle(color: scheme.primary, fontSize: 11, fontWeight: FontWeight.w600)),
              )),
            ),
          ])),
          PopupMenuButton<String>(
            tooltip: active ? 'Stop the app to change the device' : 'Run on…',
            enabled: !active,
            // The list may have changed since it was last read; this shows on the next open.
            onOpened: () => unawaited(_loadAvds()),
            onSelected: _onTarget,
            itemBuilder: (menu) {
              final stopped = [
                if (ExtensionManager.instance.isEnabled('emulators'))
                  for (final a in _avds)
                    if (a.serial == null) a,
              ];
              return [
                for (final t in targets.entries)
                  CheckedPopupMenuItem(
                    value: 'device:${t.key}',
                    checked: t.key == _device,
                    height: 30,
                    child: Text(t.value, style: const TextStyle(fontSize: 13)),
                  ),
                if (stopped.isNotEmpty) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    enabled: false,
                    height: 24,
                    child: Text('Start emulator', style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
                  for (final a in stopped)
                    PopupMenuItem(
                      value: 'start:${a.name}',
                      height: 30,
                      child: Row(
                        children: [
                          Icon(Icons.play_arrow, size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Expanded(child: Text(a.displayName, style: const TextStyle(fontSize: 13))),
                          const SizedBox(width: 16),
                          TextButton(
                            style: TextButton.styleFrom(textStyle: const TextStyle(fontSize: 12)),
                            onPressed: () => Navigator.of(menu).pop('cold:${a.name}'),
                            child: const Text('Cold boot'),
                          ),
                        ],
                      ),
                    ),
                ],
              ];
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  Icon(Icons.smartphone, size: 15, color: active ? scheme.outline : scheme.onSurfaceVariant),
                  if (!narrow) ...[
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        targets[_device] ?? 'No device',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: active ? scheme.outline : scheme.onSurface),
                      ),
                    ),
                  ],
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: platformKeys('Device screen beside the code (Ctrl+Alt+M)'),
            color: _mirrorOpen ? scheme.primary : null,
            onPressed: () => setState(() => _mirrorOpen = !_mirrorOpen),
            icon: const Icon(Icons.phone_android),
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
            tooltip: platformKeys('Hot reload (Ctrl+F5)'),
            onPressed: f?.canReload == true ? f!.reload : null,
            icon: const Icon(Icons.bolt),
          ),
          if (!narrow)
            IconButton(
              tooltip: platformKeys('Hot restart (Ctrl+Shift+F5)'),
              onPressed: f?.canReload == true ? () => f!.reload(full: true) : null,
              icon: const Icon(Icons.restart_alt),
            ),
          if (_toolArgs != null)
            IconButton(
              tooltip: 'Stop ${_toolArgs!}',
              onPressed: _stopTool,
              icon: Icon(Icons.stop_circle_outlined, color: scheme.error),
            )
          else if (_buildRunner)
            PopupMenuButton<String>(
              tooltip: 'Generate code (build_runner)',
              icon: const Icon(Icons.auto_fix_high_outlined, size: 20),
              enabled: !_toolBusy,
              onSelected: _runTool,
              itemBuilder: (_) => const [
                PopupMenuItem(height: 30, value: _buildRunnerBuild, child: Text('Generate code')),
                PopupMenuItem(height: 30, value: _buildRunnerWatch, child: Text('Generate on every save (watch)')),
                PopupMenuItem(height: 30, value: _buildRunnerClean, child: Text('Clear its cache')),
              ],
            ),
          PopupMenuButton<String>(
            tooltip: 'Flutter commands',
            icon: const Icon(Icons.flutter_dash),
            enabled: !_toolBusy,
            onSelected: (v) => v == _pickPackageToUpgrade ? unawaited(_upgradeOnePackage()) : unawaited(_runTool(v)),
            itemBuilder: (_) => const [
              PopupMenuItem(height: 30, value: 'pub get', child: Text('pub get')),
              PopupMenuItem(height: 30, value: 'pub upgrade', child: Text('pub upgrade')),
              PopupMenuItem(height: 30, value: _pickPackageToUpgrade, child: Text('pub upgrade [package]…')),
              PopupMenuItem(height: 30, value: 'pub outdated', child: Text('pub outdated')),
              PopupMenuItem(height: 30, value: 'clean', child: Text('clean')),
              PopupMenuItem(height: 30, value: 'analyze', child: Text('analyze')),
              PopupMenuItem(height: 30, value: 'test', child: Text('test')),
              PopupMenuItem(height: 30, value: 'doctor', child: Text('doctor')),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Editor options',
            icon: const Icon(Icons.tune, size: 20),
            itemBuilder: (_) => [
              const PopupMenuItem(height: 30, value: 'dart', child: Text('Dart settings…')),
              CheckedPopupMenuItem(height: 30, value: 'wrap', checked: EditorView.wordWrap.value, child: const Text('Word wrap (Alt+Z)')),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(height: 30, value: 'reload', checked: _reloadOnSave, child: const Text('Hot reload on save')),
            ],
            onSelected: (v) async {
              if (v == 'dart') await _dartSettings(ws);
              if (v == 'wrap') await EditorView.toggleWordWrap();
              if (v == 'reload') {
                await Settings.instance.update('flutter.hotReloadOnSave', !_reloadOnSave);
              }
              _rebuild();
            },
          ),
        ],
      ),
    );
  }

  /// The code, or a tool in front of it. Tools come up here so the Editor around them never goes away.
  Widget _workArea(Widget editor, ColorScheme scheme) {
    final tools = ToolTabs.instance;
    if (tools.open.isEmpty) return editor;
    Widget tab(String label, IconData icon, bool selected, VoidCallback onTap, {VoidCallback? onClose}) => PillTab(
      selected: selected,
      onTap: onTap,
      padding: EdgeInsets.only(left: 10, right: onClose == null ? 10 : 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: selected ? scheme.primary : scheme.outline),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12.5)),
          if (onClose != null)
            IconButton(
              tooltip: 'Close',
              iconSize: 13,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
    final active = tools.active;
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: panelGap),
            buildDefaultDragHandles: false,
            itemCount: tools.strip.length,
            onReorderItem: tools.move,
            proxyDecorator: (child, _, _) => Material(elevation: 4, color: scheme.surface, borderRadius: BorderRadius.circular(8), child: child),
            itemBuilder: (_, i) {
              final m = tools.strip[i];
              return ReorderableDragStartListener(
                key: ValueKey(m ?? 'editor'),
                index: i,
                child: m == null
                    ? tab('Editor', Icons.code, active == null, tools.showEditor)
                    : tab(m.label, m.icon, m == active, () => tools.show(m), onClose: () => tools.close(m)),
              );
            },
          ),
        ),
        Expanded(
          // IndexedStack keeps each tool's state (scans, logs, printer) while another one is showing.
          child: IndexedStack(
            index: active == null ? 0 : tools.open.indexOf(active) + 1,
            sizing: StackFit.expand,
            children: [
              TickerMode(
                enabled: active == null,
                child: AnimatedOpacity(opacity: active == null ? 1 : 0, duration: const Duration(milliseconds: 120), child: editor),
              ),
              for (final m in tools.open)
                // Disabled TickerMode tells hidden pages to hide native windows (embedded scrcpy) too.
                TickerMode(
                  key: ObjectKey(m),
                  enabled: m == active,
                  child: AnimatedOpacity(
                    opacity: m == active ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(panelGap, 0, panelGap, panelGap),
                      child: PanelCard(child: KeyedSubtree(key: GlobalObjectKey(m), child: m.page)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _loadAvds() async {
    if (!ExtensionManager.instance.isEnabled('emulators')) return;
    try {
      final avds = await AvdService(context.read<DevicesCubit>().adb.tools).list();
      if (mounted) setState(() => _avds = avds);
    } on Exception {
      // No Android SDK here: the menu just has no emulators to offer.
    }
  }

  Future<void> _onTarget(String value) async {
    final split = value.indexOf(':');
    final kind = value.substring(0, split), name = value.substring(split + 1);
    if (kind == 'device') return setState(() => _device = name);
    final avd = _avds.where((a) => a.name == name).firstOrNull;
    if (avd == null) return;
    final cold = kind == 'cold';
    _toast('${cold ? 'Cold booting' : 'Starting'} ${avd.displayName}…');
    final error = await AvdService(context.read<DevicesCubit>().adb.tools).start(avd, coldBoot: cold);
    if (error != null && mounted) _toast(error);
  }

  void _splitActive() {
    final ws = _ws, doc = ws?.active;
    if (ws == null || doc == null) return;
    if (ws.focused.docs.length < 2) return _toast('Open another file first: a file shows in one view at a time');
    ws.moveToGroup(doc, null);
  }

  // Not a LayoutBuilder: that would build the editors during layout, after the status bar watching them.
  Widget _groups(EditorWorkspace ws, ColorScheme scheme) {
    final total = ws.groups.fold<double>(0, (sum, g) => sum + g.weight);
    return Row(
      key: _groupsKey,
      children: [
        for (final (i, g) in ws.groups.indexed) ...[
          if (i > 0)
            _DragHandle(
              axis: Axis.horizontal,
              onDrag: (d) => setState(() {
                final width = _groupsKey.currentContext?.size?.width;
                if (width == null || i >= ws.groups.length) return;
                final left = ws.groups[i - 1];
                final change = d / width * total;
                // Neither side gets too narrow to use.
                final minimum = total * 200 / width;
                if (left.weight + change < minimum || g.weight - change < minimum) return;
                left.weight += change;
                g.weight -= change;
              }),
            ),
          Expanded(flex: (g.weight / total * 10000).round().clamp(1, 10000), child: _group(ws, g, scheme)),
        ],
      ],
    );
  }

  /// The device's screen next to the code, like Android Studio's Running Devices.
  Widget _mirror(ColorScheme scheme) {
    final device = _device;
    final android = device != null && device != _desktopDevice;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.smartphone, size: 14, color: scheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(android ? device : 'Device', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                ),
                IconButton(
                  tooltip: 'Close',
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                  onPressed: () => setState(() => _mirrorOpen = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: android
                ? EmbeddedScrcpy(
                    key: ValueKey(device),
                    adb: context.read<DevicesCubit>().adb,
                    target: device,
                    maxSize: 1280,
                    onFailed: _toast,
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Pick an Android device in the run menu, or start an emulator from it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, color: scheme.outline),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _group(EditorWorkspace ws, EditorGroup group, ColorScheme scheme) {
    if (group.settling) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        group.settling = false;
        _rebuild();
      });
    }
    final inFront = group.settling ? null : group.active;
    // What a tool's tab has in front isn't code, and takes no breadcrumbs or banners.
    final doc = inFront?.module == null ? inFront : null;
    final key = _paneKeys[group] ??= GlobalKey<CodePaneState>();
    return Listener(
      onPointerDown: (_) => ws.focusGroup(group),
      child: PanelCard(child: Column(
        children: [
          if (group.docs.isNotEmpty) _tabs(ws, group, scheme),
          if (doc != null)
            BreadcrumbBar(
              root: ws.root,
              doc: doc,
              onReveal: (line, column) => unawaited(_jump(EditTarget(doc.path, line, column))),
              onOpenFile: _openFile,
            ),
          if (doc != null && isLibrarySource(doc.path)) _readOnlyBanner(scheme),
          if (doc != null && doc.changedOnDisk) _changedBanner(doc, scheme),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (group.active?.module != null)
                  const SizedBox.shrink()
                else if (doc == null)
                  group.settling ? const SizedBox.shrink() : _EmptyEditor(onQuickOpen: _quickOpen)
                else if (doc.binary || doc.previewing)
                  FilePreview(key: ObjectKey(doc), doc: doc)
                else
                  CodePane(
                    key: key,
                    workspace: ws,
                    doc: doc,
                    debugger: _debugger,
                    git: _git,
                    onKey: _onKey,
                    onTarget: _jump,
                    onReferences: _showReferences,
                  ),
                // All of a view's tools stay built, so scans, logs and the printer keep their state behind other tabs.
                for (final tool in group.docs.where((d) => d.module != null))
                  Offstage(
                    offstage: !identical(tool, group.active),
                    // Disabled TickerMode tells hidden pages to hide native windows (embedded scrcpy) too.
                    child: TickerMode(
                      enabled: identical(tool, group.active),
                      child: KeyedSubtree(key: GlobalObjectKey(tool.module!), child: tool.module!.page),
                    ),
                  ),
                // Only there during a drag, so it can never get in the way of the editor.
                if (_draggingTab != null)
                  _TabDropZones(
                    onDrop: (dragged, zone) {
                      switch (zone) {
                        case TabDropZone.left:
                          ws.splitBeside(dragged, group, right: false);
                        case TabDropZone.right:
                          ws.splitBeside(dragged, group, right: true);
                        case TabDropZone.center:
                          ws.placeTab(dragged, group, group.docs.length);
                      }
                      unawaited(_rememberTabs());
                    },
                  ),
              ],
            ),
          ),
        ],
      )),
    );
  }

  Future<void> _tabMenu(Offset global, EditorWorkspace ws, EditorGroup group, EditorDocument doc) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(global);
    final others = [for (final g in ws.groups) if (!identical(g, group)) g];
    final picked = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
      items: [
        if (group.docs.length > 1) PopupMenuItem(height: 30, value: () => ws.moveToGroup(doc, null), child: const Text('Split Right', style: TextStyle(fontSize: 13))),
        for (final (i, g) in others.indexed)
          PopupMenuItem(height: 30, value: () => ws.moveToGroup(doc, g), child: Text('Move to View ${i + 1}', style: const TextStyle(fontSize: 13))),
        if (group.docs.length > 1 || others.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem(height: 30, value: () => _closeTab(doc), child: const Text('Close', style: TextStyle(fontSize: 13))),
        if (group.docs.length > 1)
          PopupMenuItem(
            height: 30,
            value: () {
              for (final d in [...group.docs]) {
                if (d != doc) unawaited(_closeTab(d));
              }
            },
            child: const Text('Close Others', style: TextStyle(fontSize: 13)),
          ),
      ],
    );
    picked?.call();
  }

  Widget _fileTab(EditorWorkspace ws, EditorGroup group, int i, ColorScheme scheme) {
    final d = group.docs[i];
    final selected = d == group.active;
    final (icon, color) = d.module == null ? fileIconOf(d.path) : (d.module!.icon, null);
    final tab = Listener(
      // Middle click closes, as in every other editor.
      onPointerDown: (e) {
        if (e.buttons == 4) _closeTab(d);
        if (e.buttons == 2) unawaited(_tabMenu(e.position, ws, group, d));
      },
      child: PillTab(
        selected: selected,
        active: identical(group, ws.focused),
        onTap: () {
          ws.activate(d);
          unawaited(_rememberTabs());
        },
        padding: const EdgeInsets.only(left: 10, right: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color ?? scheme.outline),
            const SizedBox(width: 5),
            Tooltip(
              message: d.module == null ? d.path : d.name,
              child: Text(
                d.name,
                style: TextStyle(
                  fontSize: 12.5,
                  color: d.diagnostics.any((x) => x.severity == 1) ? scheme.error : null,
                ),
              ),
            ),
            IconButton(
              tooltip: d.dirty ? platformKeys('Unsaved. Close (Ctrl+W)') : platformKeys('Close (Ctrl+W)'),
              iconSize: d.dirty ? 9 : 13,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              onPressed: () => _closeTab(d),
              icon: Icon(d.dirty ? Icons.circle : Icons.close),
            ),
          ],
        ),
      ),
    );
    return DragTarget<EditorDocument>(
      key: ObjectKey(d),
      onWillAcceptWithDetails: (details) => details.data != d,
      onAcceptWithDetails: (details) {
        ws.placeTab(details.data, group, i);
        unawaited(_rememberTabs());
      },
      builder: (_, candidates, _) => DecoratedBox(
        // Shows where the tab would land: just before this one.
        decoration: BoxDecoration(border: Border(left: BorderSide(width: 2, color: candidates.isEmpty ? Colors.transparent : scheme.primary))),
        child: Draggable<EditorDocument>(
          data: d,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragStarted: () => setState(() => _draggingTab = d),
          onDragEnd: (_) => setState(() => _draggingTab = null),
          feedback: Material(
            elevation: 4,
            color: scheme.surface,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: color ?? scheme.outline),
                  const SizedBox(width: 5),
                  Text(d.name, style: const TextStyle(fontSize: 12.5)),
                ],
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: .4, child: tab),
          child: tab,
        ),
      ),
    );
  }

  Widget _tabEnd(EditorWorkspace ws, EditorGroup group, ColorScheme scheme) => DragTarget<EditorDocument>(
    onAcceptWithDetails: (details) {
      ws.placeTab(details.data, group, group.docs.length);
      unawaited(_rememberTabs());
    },
    builder: (_, candidates, _) => Container(
      width: 48,
      decoration: BoxDecoration(border: Border(left: BorderSide(width: 2, color: candidates.isEmpty ? Colors.transparent : scheme.primary))),
    ),
  );

  Widget _tabs(EditorWorkspace ws, EditorGroup group, ColorScheme scheme) => Material(
    color: scheme.surface,
    child: SizedBox(
    height: 34,
    child: Row(
      children: [
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            // One past the tabs: the empty end of the strip takes a tab to the end.
            itemCount: group.docs.length + 1,
            itemBuilder: (_, i) => i == group.docs.length ? _tabEnd(ws, group, scheme) : _fileTab(ws, group, i, scheme),
          ),
        ),
        if (group.active case final active? when active.canPreview)
          IconButton(
            tooltip: platformKeys(active.previewing ? 'Show Code (Ctrl+Shift+V)' : 'Open Preview (Ctrl+Shift+V)'),
            iconSize: 15,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            onPressed: active.togglePreview,
            icon: Icon(active.previewing ? Icons.code : Icons.visibility_outlined),
          ),
        IconButton(
          tooltip: platformKeys('Split Editor (Ctrl+\\)'),
          iconSize: 15,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          onPressed: () {
            ws.focusGroup(group);
            _splitActive();
          },
          icon: const Icon(Icons.vertical_split_outlined),
        ),
      ],
    ),
    ),
  );

  Widget _readOnlyBanner(ColorScheme scheme) => Container(
    color: scheme.surfaceContainer,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    child: Row(
      children: [
        Icon(Icons.lock_outline, size: 13, color: scheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Read-only: SDK or package source', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: canvasOf(scheme),
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
          const SizedBox(width: 10),
          Tooltip(
            message: _notices.isEmpty ? 'No notifications' : (_noticesHidden ? 'Show notifications' : 'Hide notifications'),
            child: InkWell(
              onTap: _notices.isEmpty ? null : () => setState(() => _noticesHidden = !_noticesHidden),
              child: Row(
                children: [
                  Icon(_notices.isEmpty ? Icons.notifications_none : Icons.notifications, size: 14, color: _notices.isEmpty ? scheme.outline : scheme.primary),
                  if (_notices.isNotEmpty) Text(' ${_notices.length}', style: style),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),
          if (ws.analyzing || ws.startingAnalyzer) ...[
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(ws.analyzing ? 'Analyzing…' : 'Starting Dart analyzer…', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
          ],
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
          if (_sdk case final sdk? when MediaQuery.sizeOf(context).width >= 760) ...[
            Tooltip(message: sdk.path, child: Text('Flutter ${sdk.flutter}  •  Dart ${sdk.dart}', style: style)),
            const SizedBox(width: 14),
          ],
          if (doc != null && doc.module == null)
            RebuildAfterFrame(
              listenable: doc.controller,
              builder: (_) {
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomPanel(EditorWorkspace ws, ColorScheme scheme) {
    Widget tab(_Panel panel, String label) => PillTab(
      selected: _panel == panel,
      onTap: () => setState(() => _panel = panel),
      child: Text(label, style: TextStyle(fontSize: 12.5, color: _panel == panel ? scheme.primary : scheme.onSurfaceVariant)),
    );

    return PanelCard(
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: [
                      tab(_Panel.problems, 'Problems (${ws.allDiagnostics.length})'),
                      tab(_Panel.output, 'Output'),
                      tab(_Panel.terminal, 'Terminal'),
                      tab(_Panel.widgets, 'Widgets'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: platformKeys('Hide (Ctrl+J)'),
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _panelOpen = false),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (_panel) {
              _Panel.problems => _problems(ws, scheme),
              _Panel.output => _output(scheme),
              _Panel.terminal => _terminalView(ws),
              _Panel.widgets => WidgetTreeView(inspector: _inspector, onOpen: (target) => unawaited(_jump(target))),
            },
          ),
        ],
      ),
    );
  }

  Widget _problems(EditorWorkspace ws, ColorScheme scheme) {
    final all = ws.allDiagnostics;
    if (all.isEmpty) return Center(child: Text('No problems.', style: TextStyle(color: scheme.outline)));
    return ListView.builder(
      itemCount: all.length,
      itemExtent: 23,
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
    final anchor = _toolAnchor.clamp(0, lines.length);
    if (total == 0) {
      return Center(child: Text('Run the app or a Flutter command to see output here.', style: TextStyle(color: scheme.outline)));
    }
    final query = _outputSearch.text.trim();
    String textAt(int row) {
      final (isTool, index) = outputRow(row, anchor, tool.length);
      return isTool ? tool[index] : lines[index].text;
    }

    final rows = [
      for (var i = 0; i < total; i++)
        if (matchesLogSearch(textAt(i), query)) i,
    ];
    // New lines shouldn't pull you away from what you searched for.
    if (query.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_outputScroll.hasClients) _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          child: TextField(
            controller: _outputSearch,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12.5),
            decoration: InputDecoration(
              hintText: 'Search the output',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              prefixIcon: const Icon(Icons.search, size: 15),
              prefixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 28),
              suffixIconConstraints: const BoxConstraints(minHeight: 24),
              suffixIcon: query.isEmpty
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${rows.length} of $total', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                        IconButton(
                          tooltip: 'Clear',
                          iconSize: 14,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                          onPressed: () => setState(_outputSearch.clear),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        Expanded(child: rows.isEmpty
            ? Center(child: Text('No lines match', style: TextStyle(fontSize: 12.5, color: scheme.outline)))
            : SelectionArea(
      child: ListView.builder(
        controller: _outputScroll,
        padding: const EdgeInsets.all(8),
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final (isTool, index) = outputRow(rows[i], anchor, tool.length);
          final text = isTool ? tool[index] : lines[index].text;
          final kind = isTool ? FlutterLineKind.log : lines[index].kind;
          final level = levelOf(text);
          final color = switch ((kind, level)) {
            (FlutterLineKind.error, _) || (_, LogLevel.error) => scheme.error,
            (_, LogLevel.warning) => const Color(0xFFD97706),
            (FlutterLineKind.success, _) || (_, LogLevel.success) => scheme.primary,
            (_, LogLevel.debug) || (FlutterLineKind.info, _) => scheme.outline,
            _ => scheme.onSurface,
          };
          final ref = _sourceRef.firstMatch(text);
          final line = Text.rich(ansiSpan(text, TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: color)));
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
    )),
      ],
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: TextField(
          controller: _searchCtrl,
          focusNode: _searchFocus,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Search in files',
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            prefixIcon: const Icon(Icons.search, size: 15),
            prefixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 28),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(7),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
          onChanged: _onSearchChanged,
          onSubmitted: _search,
        ),
      ),
      if (_hitsTitle.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Text(_hitsTitle, style: TextStyle(fontSize: 12, color: scheme.outline)),
        ),
      Expanded(
        child: ListView.builder(
          itemCount: _hits.length,
          itemExtent: 38,
          itemBuilder: (_, i) {
            final h = _hits[i];
            return InkWell(
              onTap: () => _jump(EditTarget(h.path, h.line, h.column)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      h.text.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5),
                    ),
                    Text(
                      '${p.isWithin(ws.root, h.path) ? p.relative(h.path, from: ws.root) : p.basename(h.path)}:${h.line + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: scheme.outline),
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

class _DartSettingsDialog extends StatefulWidget {
  const _DartSettingsDialog({required this.root, required this.settings});

  final String root;
  final DartSettings settings;

  @override
  State<_DartSettingsDialog> createState() => _DartSettingsDialogState();
}

class _DartSettingsDialogState extends State<_DartSettingsDialog> {
  late final _length = TextEditingController(text: (_projectWidth ?? widget.settings.lineLength)?.toString() ?? '');
  late final _excluded = TextEditingController(text: widget.settings.excludedFolders.join(', '));
  late var _format = widget.settings.formatOnSave;
  late var _pubGet = widget.settings.pubGetOnSave;
  late var _todos = widget.settings.showTodos;
  late final _projectWidth = projectPageWidth(widget.root);

  @override
  void dispose() {
    _length.dispose();
    _excluded.dispose();
    super.dispose();
  }

  void _save() {
    final length = int.tryParse(_length.text.trim());
    Navigator.pop(
      context,
      DartSettings(
        lineLength: _projectWidth == null ? length?.clamp(40, 400) : widget.settings.lineLength,
        formatOnSave: _format,
        pubGetOnSave: _pubGet,
        showTodos: _todos,
        excludedFolders: _excluded.text.split(',').map((f) => f.trim()).where((f) => f.isNotEmpty).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Dart settings: ${p.basename(widget.root)}'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _length,
            enabled: _projectWidth == null,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Line length',
              hintText: '80',
              helperText: _projectWidth == null ? 'How wide the formatter lets code run. Empty means 80.' : 'Set by page_width in analysis_options.yaml.',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Format on save'),
            value: _format,
            onChanged: (v) => setState(() => _format = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Run pub get when pubspec.yaml is saved'),
            value: _pubGet,
            onChanged: (v) => setState(() => _pubGet = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show TODOs in Problems'),
            value: _todos,
            onChanged: (v) => setState(() => _todos = v),
          ),
          TextField(
            controller: _excluded,
            decoration: const InputDecoration(
              labelText: 'Folders the analyzer skips',
              hintText: 'build, example',
              helperText: 'Comma separated, relative to the project. Saves memory on large repos.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

enum TabDropZone { left, center, right }

/// Which part of a view a dragged tab is over: an edge splits, the middle joins.
TabDropZone tabDropZone(double x, double width) {
  if (x < width * .3) return TabDropZone.left;
  if (x > width * .7) return TabDropZone.right;
  return TabDropZone.center;
}

class _TabDropZones extends StatefulWidget {
  const _TabDropZones({required this.onDrop});

  final void Function(EditorDocument doc, TabDropZone zone) onDrop;

  @override
  State<_TabDropZones> createState() => _TabDropZonesState();
}

class _TabDropZonesState extends State<_TabDropZones> {
  TabDropZone? _zone;

  TabDropZone _zoneAt(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    return tabDropZone(box.globalToLocal(global).dx, box.size.width);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<EditorDocument>(
      onMove: (details) {
        final zone = _zoneAt(details.offset);
        if (zone != _zone) setState(() => _zone = zone);
      },
      onLeave: (_) => setState(() => _zone = null),
      onAcceptWithDetails: (details) {
        final zone = _zoneAt(details.offset);
        setState(() => _zone = null);
        widget.onDrop(details.data, zone);
      },
      builder: (_, _, _) => Align(
        alignment: switch (_zone) {
          TabDropZone.left => Alignment.centerLeft,
          TabDropZone.right => Alignment.centerRight,
          _ => Alignment.center,
        },
        child: _zone == null
            ? const SizedBox.expand()
            : FractionallySizedBox(
                widthFactor: _zone == TabDropZone.center ? 1 : .5,
                heightFactor: 1,
                child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: scheme.primary.withValues(alpha: .6)),
                  ),
                ),
              ),
      ),
    );
  }
}

class _DragHandle extends StatefulWidget {
  const _DragHandle({required this.axis, required this.onDrag});

  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final color = _hover ? Theme.of(context).colorScheme.primary.withValues(alpha: .6) : Colors.transparent;
    return MouseRegion(
      cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: horizontal ? (d) => widget.onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => widget.onDrag(d.delta.dy),
        child: SizedBox(
          width: horizontal ? panelGap : null,
          height: horizontal ? null : panelGap,
          child: Center(
            child: Container(
              width: horizontal ? 2 : 36,
              height: horizontal ? 36 : 2,
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
            ),
          ),
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
        if (projects.isEmpty) Text('Projects from Settings → Projects show up here.', style: TextStyle(color: scheme.outline)),
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
          TextButton(onPressed: onQuickOpen, child: Text(platformKeys('Quick open (Ctrl+P)'))),
        ],
      ),
    );
  }
}

class _QuickOpen extends StatefulWidget {
  const _QuickOpen({required this.root, required this.files, required this.recent});

  final String root;
  final List<String> files;

  /// Open tabs, shown first before anything is typed.
  final List<String> recent;

  @override
  State<_QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<_QuickOpen> {
  static const _rowHeight = 30.0;
  var _query = '';
  int? _line;
  var _index = 0;
  late var _matches = _rank();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<FileMatch> _rank() {
    if (_query.trim().isNotEmpty) return rankFiles(widget.files, widget.root, _query);
    return [
      for (final f in {...widget.recent, ...widget.files}.take(50))
        FileMatch(f, p.basename(f), p.relative(p.dirname(f), from: widget.root), 0, const {}, const {}),
    ];
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _index = (_index + delta) % _matches.length);
    if (!_scroll.hasClients) return;
    final top = _index * _rowHeight;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + _scroll.position.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - _scroll.position.viewportDimension);
    }
  }

  void _open(FileMatch m) => Navigator.pop(context, (m.path, _line));

  Widget _marked(String text, Set<int> hits, TextStyle style, Color accent, {TextOverflow? overflow}) => Text.rich(
    TextSpan(
      children: [
        for (final (i, ch) in text.split('').indexed)
          TextSpan(text: ch, style: hits.contains(i) ? TextStyle(color: accent, fontWeight: FontWeight.w700) : null),
      ],
    ),
    maxLines: 1,
    overflow: overflow,
    style: style,
  );

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
                    _move(1);
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                    _move(-1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search files: online payment, main.dart:42, or @method', isDense: true),
                  onChanged: (v) {
                    // Hands over to the symbols of the open file, where the rest of the typing goes.
                    if (v.startsWith('@')) return Navigator.pop(context, (v, null));
                    setState(() {
                    final (text, line) = splitLineSuffix(v);
                    _query = text;
                    _line = line;
                    _index = 0;
                    _matches = _rank();
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    });
                  },
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) _open(matches[index]);
                  },
                ),
              ),
            ),
            Expanded(
              child: matches.isEmpty
                  ? Center(child: Text('No matching files', style: TextStyle(color: scheme.outline, fontSize: 13)))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: matches.length,
                      itemExtent: _rowHeight,
                      itemBuilder: (_, i) {
                        final m = matches[i];
                        return InkWell(
                          onTap: () => _open(m),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            color: i == index ? scheme.primary.withValues(alpha: .14) : null,
                            child: Row(
                              children: [
                                _marked(m.name, m.nameHits, const TextStyle(fontSize: 13), scheme.primary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _marked(
                                    m.folder,
                                    m.folderHits,
                                    TextStyle(fontSize: 12, color: scheme.outline),
                                    scheme.primary,
                                    overflow: TextOverflow.ellipsis,
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
        ),
      ),
    );
  }
}
