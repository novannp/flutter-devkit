import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/clipboard_image.dart';
import '../../../../core/files.dart';
import '../../../../core/local_builds.dart';
import '../../../../core/tools.dart';
import '../../../../core/windows.dart';
import '../../../stores/store_codes_cubit.dart';
import '../../../stores/view/code_picker_dialog.dart';
import '../../models/device.dart';
import '../../services/adb_service.dart';
import '../../services/device_adb.dart';
import '../../services/flutter_session.dart';
import '../../services/logcat_controller.dart';
import 'apps_tab.dart';
import 'dev_tab.dart';
import 'embedded_scrcpy.dart';
import 'files_tab.dart';
import 'flutter_tab.dart';
import 'info_tab.dart';
import 'logcat_tab.dart';
import 'screen_panel.dart';
import 'shell_tab.dart';
import 'terminal_tab.dart';
import '../../../../core/history.dart';

class DeviceWorkspacePage extends StatefulWidget {
  const DeviceWorkspacePage({super.key, required this.device, this.standalone = false, this.panelOnly = false});

  /// true = right panel only (no screen), used in Multi Screen which already renders the screen.
  final bool panelOnly;

  final Device device;

  /// true = standalone window per device (no back button).
  final bool standalone;

  @override
  State<DeviceWorkspacePage> createState() => _DeviceWorkspacePageState();
}

enum _TaskStatus { running, ok, failed }

class _Task {
  _Task(this.label);

  final String label;
  _TaskStatus status = _TaskStatus.running;
  String? detail;
}

class _ScrcpyOption {
  const _ScrcpyOption(this.label, this.flag);

  final String label;
  final String flag;
}

const _scrcpyOptions = [
  _ScrcpyOption('Stay awake', '--stay-awake'),
  _ScrcpyOption('Show touches', '--show-touches'),
  _ScrcpyOption('Turn device screen off', '--turn-screen-off'),
  _ScrcpyOption('No audio', '--no-audio'),
  _ScrcpyOption('Always on top', '--always-on-top'),
];

const _shortcuts = [
  ('F5', 'Flutter run/attach again (last project)'),
  ('Ctrl + F5', 'Hot reload'),
  ('Ctrl + Shift + F5', 'Hot restart'),
  ('Shift + F5', 'Stop flutter'),
  ('Ctrl + 1…7', 'Switch tab'),
  ('Ctrl + S', 'Screenshot (save + copy image)'),
  ('Ctrl + Shift + S', 'Screenshot, save as…'),
  ('Ctrl + B', 'Bug report (screenshot + log + info)'),
  ('Ctrl + K', 'Type store code on device'),
  ('Ctrl + I', 'Install latest build'),
  ('Ctrl + R', 'Restart focused app'),
  ('Ctrl + L', 'Clear logcat'),
  ('Ctrl + M', 'Open remote (scrcpy)'),
  ('Click screen', 'Laptop keyboard types directly on device (Ctrl+V = paste)'),
];

const _prefTab = 'ws_tab';
const _prefPanel = 'ws_panel_width';
const _prefPanelAuto = 'ws_panel_auto';
const _prefFast = 'ws_fast_screen';
String _prefFocus(String id) => 'ws_focus_$id';

class _DeviceWorkspacePageState extends State<DeviceWorkspacePage> {
  late final dev = DeviceAdb(context.read<AdbService>(), widget.device.adbTarget!);
  late final _log = LogcatController(dev)..start();
  late final _flutter = FlutterSession(dev.target);
  final _focus = ValueNotifier<String?>(null);
  final _filesDir = ValueNotifier('/sdcard/Download');
  final _filesRefresh = ValueNotifier(0);
  final _keyboard = FocusNode(debugLabel: 'workspace');
  Map<String, String> _installed = const {};
  List<LocalBuild> _builds = const [];
  final _tasks = <_Task>[];
  final _scrcpyFlags = <String>{'--stay-awake', '--no-audio'};
  StreamSubscription<LogLine>? _crashSub;
  String? _android;
  var _record = false;
  var _tab = 0;
  var _panelWidth = 520.0;

  /// Size the screen area to the device's shape (no black bars) until the user drags the divider.
  var _autoWidth = true;
  Size? _screenSize;
  Timer? _sizeProbe;

  Future<void> _probeScreenSize() async {
    final bytes = await dev.screenshot();
    if (!mounted || bytes == null || bytes.length < 24) return;
    final v = ByteData.sublistView(bytes);
    final size = Size(v.getUint32(16).toDouble(), v.getUint32(20).toDouble());
    if (size != _screenSize) setState(() => _screenSize = size);
  }

  var _dragging = false;
  var _fast = true;

  static const _tabs = ['Flutter', 'Logcat', 'Apps', 'Dev', 'Info', 'Shell', 'Files', 'Terminal'];
  static const _filesTab = 6;

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    if (!widget.panelOnly) {
      _probeScreenSize();
      // Re-check now and then so rotating the device resizes the screen area.
      _sizeProbe = Timer.periodic(const Duration(seconds: 8), (_) => _probeScreenSize());
    }
    dev.sh('getprop ro.build.version.release; getprop ro.build.version.sdk').then((v) {
      final p = v.split('\n');
      if (mounted && p.length >= 2) setState(() => _android = 'Android ${p[0].trim()} (API ${p[1].trim()})');
    });
    _flutter.addListener(_onFlutter);
    _loadInstalled();
    _loadBuilds();
    _crashSub = _log.onCrash.listen((line) {
      final app = _log.ourPids[line.pid];
      _toast(
        '💥 Crash${app != null ? ' in ${appName(app)}' : ''}: ${line.message}',
        action: SnackBarAction(label: 'Bug report', onPressed: _bugReport),
      );
      setState(() {});
    });
    _focus.addListener(() async {
      final prefs = await SharedPreferences.getInstance();
      final v = _focus.value;
      v == null ? prefs.remove(_prefFocus(widget.device.id)) : prefs.setString(_prefFocus(widget.device.id), v);
    });
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _tab = (prefs.getInt(_prefTab) ?? 0).clamp(0, _tabs.length - 1);
      _panelWidth = prefs.getDouble(_prefPanel) ?? _panelWidth;
      _autoWidth = prefs.getBool(_prefPanelAuto) ?? true;
      _fast = (prefs.getBool(_prefFast) ?? true) && dev.adb.tools.scrcpy != null;
    });
    _focus.value ??= prefs.getString(_prefFocus(widget.device.id));
  }

  void _onFlutter() {
    if (mounted) setState(() {});
  }

  Future<void> _loadInstalled() async {
    final apps = await dev.ourApps();
    if (!mounted) return;
    setState(() => _installed = apps);
    // If only one of our apps is installed, focus it right away.
    if (_focus.value == null && apps.length == 1) _focus.value = apps.keys.first;
  }

  Future<void> _loadBuilds() async {
    final builds = await LocalBuilds.scan();
    if (mounted) setState(() => _builds = builds);
  }

  @override
  void dispose() {
    _sizeProbe?.cancel();
    _crashSub?.cancel();
    _flutter.removeListener(_onFlutter);
    _flutter.dispose();
    _log.dispose();
    _focus.dispose();
    _filesDir.dispose();
    _filesRefresh.dispose();
    _keyboard.dispose();
    super.dispose();
  }

  void _toast(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action, behavior: SnackBarBehavior.floating, width: 520));
  }

  Future<void> _runTask(String label, Future<ProcessOutput> Function() job) async {
    final task = _Task(label);
    setState(() => _tasks.insert(0, task));
    final r = await job();
    if (label.startsWith('Install')) _loadInstalled();
    final out = '${r.stdout}\n${r.stderr}'.trim();
    final failed = !r.ok || out.contains('Failure') || out.contains('error:');
    History.activity('task', '$label on ${widget.device.displayName}: ${failed ? 'failed' : 'ok'}', {
      'device': dev.target,
      if (failed) 'output': out,
    });
    if (!mounted) return;
    setState(() {
      task.status = failed ? _TaskStatus.failed : _TaskStatus.ok;
      task.detail = failed ? out.split('\n').last : null;
    });
    Future.delayed(Duration(seconds: failed ? 15 : 4), () {
      if (mounted) setState(() => _tasks.remove(task));
    });
  }

  String _name(String path) => path.split(RegExp(r'[\\/]')).last;

  Future<void> _install(String path) => _runTask('Install ${_name(path)}', () => dev.install(path));

  Future<void> _installLatest() async {
    await _loadBuilds();
    if (_builds.isEmpty) {
      return _toast('No APKs in project build folders yet. Set project folders in the Install menu.');
    }
    final build = _builds.where((b) => b.package == _focus.value).firstOrNull ?? _builds.first;
    _install(build.apk.path);
  }

  Future<void> _pickProjectsRoot() async {
    final path = await getDirectoryPath(confirmButtonText: 'Select project folder');
    if (path == null) return;
    await ProjectFolders.add(path);
    await _loadBuilds();
    _toast('${_builds.length} builds found in $path');
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final dir = _tab == _filesTab ? _filesDir.value : '/sdcard/Download';
    for (final file in details.files) {
      final path = file.path;
      if (await FileSystemEntity.isDirectory(path) == false && path.toLowerCase().endsWith('.apk')) {
        _install(path);
      } else {
        await _runTask('Push ${_name(path)} → $dir', () => dev.push(path, '$dir/'));
        _filesRefresh.value++;
      }
    }
  }

  Future<void> _pickApk() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'APK', extensions: ['apk']),
      ],
    );
    if (file != null) _install(file.path);
  }

  String get _baseName => safeFileName(widget.device.displayName);

  Future<void> _screenshot({bool saveAs = false}) async {
    final bytes = await dev.screenshot();
    if (bytes == null) return _toast('Failed to take screenshot');
    String path;
    if (saveAs) {
      final loc = await getSaveLocation(
        suggestedName: '${_baseName}_${timestamp()}.png',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG', extensions: ['png']),
        ],
      );
      if (loc == null) return;
      path = loc.path.toLowerCase().endsWith('.png') ? loc.path : '${loc.path}.png';
    } else {
      path = '${(await outputDir()).path}${Platform.pathSeparator}${_baseName}_${timestamp()}.png';
    }
    await File(path).writeAsBytes(bytes);
    History.activity('screenshot', 'Screenshot ${widget.device.displayName}', {'file': path});
    final copied = await copyImageToClipboard(path);
    _toast(
      copied ? 'Screenshot copied — just Ctrl+V. File: ${_name(path)}' : 'Screenshot saved: $path',
      action: SnackBarAction(label: 'Open folder', onPressed: () => revealInExplorer(path)),
    );
  }

  Future<void> _bugReport() async {
    final codes = context.read<StoreCodesCubit>();
    _toast('Creating bug report…');
    final dir = await Directory(
      '${(await outputDir()).path}${Platform.pathSeparator}bugreport_${_baseName}_${timestamp()}',
    ).create(recursive: true);
    final sep = Platform.pathSeparator;
    History.activity('bugreport', 'Bug report ${widget.device.displayName}', {'folder': dir.path});
    final shot = await dev.screenshot();
    if (shot != null) await File('${dir.path}${sep}screenshot.png').writeAsBytes(shot);
    await File('${dir.path}${sep}logcat.txt').writeAsString(_log.dump());
    if (_flutter.lines.isNotEmpty) {
      await File('${dir.path}${sep}flutter.txt').writeAsString(_flutter.lines.map((l) => l.text).join('\n'));
    }

    final props = await dev.sh(
      'getprop ro.product.manufacturer; getprop ro.product.model; '
      'getprop ro.build.version.release; getprop ro.serialno',
    );
    final p = props.split('\n').map((s) => s.trim()).toList();
    final apps = await dev.ourApps();
    final appLines = <String>[];
    for (final e in apps.entries) {
      final code = await dev.activationCodeOf(e.key);
      appLines.add(
        '- ${appName(e.key)} ${e.value}${code != null ? ' · ${describeCode(codes.byActivationCode(code), code)}' : ''}',
      );
    }
    final summary = [
      '*Device:* ${widget.device.displayName} (${p.elementAtOrNull(0) ?? ''} ${p.elementAtOrNull(1) ?? ''}, Android ${p.elementAtOrNull(2) ?? '?'})',
      '*Serial:* ${p.elementAtOrNull(3) ?? '-'} · *ADB:* ${dev.target}',
      '*Time:* ${DateTime.now()}',
      '*App:*',
      if (appLines.isEmpty) '- (none of our apps installed)' else ...appLines,
      if (_log.crashes.isNotEmpty) '*Last crash:* ${_log.crashes.last.time} ${_log.crashes.last.message}',
      '*Attachments:* screenshot.png, logcat.txt${_flutter.lines.isNotEmpty ? ', flutter.txt' : ''} (${dir.path})',
    ].join('\n');
    await File('${dir.path}${sep}info.txt').writeAsString(summary);
    await Clipboard.setData(ClipboardData(text: summary));
    _toast(
      'Bug report ready — summary copied, paste it into Jira',
      action: SnackBarAction(label: 'Open folder', onPressed: () => revealInExplorer('${dir.path}${sep}info.txt')),
    );
  }

  Future<void> _restartFocusApp() async {
    final pkg = _focus.value ?? (_installed.length == 1 ? _installed.keys.first : null);
    if (pkg == null) return _toast('Select a focus app first');
    await dev.forceStop(pkg);
    await dev.launch(pkg);
    _toast('${appName(pkg)} restarted');
  }

  Future<void> _codePicker() async {
    final msg = await showCodePicker(context, dev);
    if (msg != null) _toast(msg);
  }

  Future<void> _openScrcpy() async {
    final flags = [..._scrcpyFlags];
    if (_record) {
      flags.add('--record=${(await outputDir()).path}${Platform.pathSeparator}${_baseName}_${timestamp()}.mp4');
    }
    final error = await dev.adb.remote(dev.target, title: widget.device.displayName, options: flags);
    _toast(error ?? (_record ? 'scrcpy opened, recording saves when the window closes' : 'scrcpy opened'));
  }

  void _setTab(int i) {
    setState(() => _tab = i);
    SharedPreferences.getInstance().then((p) => p.setInt(_prefTab, i));
  }

  void _flutterRun() {
    if (_flutter.project != null && !_flutter.active) {
      _flutter.relaunch();
    } else {
      _setTab(0);
    }
  }

  void _showShortcuts() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Shortcut'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, desc) in _shortcuts)
              ListTile(
                dense: true,
                leading: SizedBox(
                  width: 140,
                  child: Text(
                    key,
                    style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(desc),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    for (var i = 0; i < _tabs.length; i++)
      SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): () => _setTab(i),
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _screenshot,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): () => _screenshot(saveAs: true),
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): _bugReport,
    const SingleActivator(LogicalKeyboardKey.keyK, control: true): _codePicker,
    const SingleActivator(LogicalKeyboardKey.keyI, control: true): _installLatest,
    const SingleActivator(LogicalKeyboardKey.keyR, control: true): _restartFocusApp,
    const SingleActivator(LogicalKeyboardKey.keyL, control: true): _log.clear,
    const SingleActivator(LogicalKeyboardKey.keyM, control: true): _openScrcpy,
    const SingleActivator(LogicalKeyboardKey.slash, control: true): _showShortcuts,
    const SingleActivator(LogicalKeyboardKey.f5): _flutterRun,
    const SingleActivator(LogicalKeyboardKey.f5, control: true): () => _flutter.reload(),
    const SingleActivator(LogicalKeyboardKey.f5, control: true, shift: true): () => _flutter.reload(full: true),
    const SingleActivator(LogicalKeyboardKey.f5, shift: true): _flutter.stop,
  };

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final scheme = Theme.of(context).colorScheme;

    return CallbackShortcuts(
      bindings: _bindings,
      child: Focus(
        focusNode: _keyboard,
        // Multi Screen shows many panels at once; don't fight over focus.
        autofocus: !widget.panelOnly,
        child: Scaffold(
          body: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _handleDrop,
            child: Stack(
              children: [
                if (widget.panelOnly)
                  Column(
                    children: [
                      _buildCompactBar(d, scheme),
                      const Divider(height: 1),
                      Expanded(child: _buildPanel(d)),
                    ],
                  )
                else
                  Column(
                    children: [
                      _buildTopBar(d, scheme),
                      const Divider(height: 1),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            const toolbarW = 54.0, handleW = 7.0, pad = 16.0;
                            var panelW = _panelWidth;
                            final shape = _screenSize;
                            if (_autoWidth && shape != null) {
                              final screenW = (box.maxHeight - pad) * shape.width / shape.height + pad;
                              panelW = (box.maxWidth - screenW - toolbarW - handleW).clamp(380.0, 1100.0);
                            }
                            return Row(
                              children: [
                                Expanded(
                                  child: _fast
                                      ? Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: EmbeddedScrcpy(
                                            key: ValueKey(dev.target),
                                            adb: dev.adb,
                                            target: dev.target,
                                            onFailed: (reason) => _toast('Fast mode failed: $reason'),
                                          ),
                                        )
                                      : ScreenPanel(dev: dev),
                                ),
                                DeviceToolbar(
                                  dev: dev,
                                  onScreenshot: _screenshot,
                                  recording: _record,
                                  onRecord: () {
                                    setState(() => _record = !_record);
                                    _toast(_record ? 'Recording on: click Remote to start recording' : 'Recording off');
                                  },
                                ),
                                _ResizeHandle(
                                  onDrag: (dx) => setState(() {
                                    _autoWidth = false;
                                    _panelWidth = (panelW - dx).clamp(380.0, 1100.0);
                                  }),
                                  onEnd: () => SharedPreferences.getInstance().then((p) {
                                    p.setDouble(_prefPanel, _panelWidth);
                                    p.setBool(_prefPanelAuto, false);
                                  }),
                                  onDoubleTap: () {
                                    setState(() => _autoWidth = true);
                                    SharedPreferences.getInstance().then((p) => p.setBool(_prefPanelAuto, true));
                                  },
                                ),
                                SizedBox(width: panelW, child: _buildPanel(d)),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                if (_dragging) const _DropOverlay(),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [for (final t in _tasks) _TaskCard(task: t)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(Device d, ColorScheme scheme) {
    final f = _flutter;
    final statusText = switch (f.status) {
      FlutterStatus.starting => f.progress ?? 'Starting…',
      FlutterStatus.reloading => f.progress ?? 'Reloading…',
      FlutterStatus.running => '${f.project?.name ?? ''} running',
      FlutterStatus.stopped => 'Flutter stopped',
      FlutterStatus.idle => 'Flutter not running',
    };
    final statusColor = switch (f.status) {
      FlutterStatus.running => Colors.green,
      FlutterStatus.starting || FlutterStatus.reloading => Colors.orange,
      _ => scheme.outline,
    };

    return SizedBox(
      height: 52,
      child: Row(
        children: [
          if (widget.standalone)
            const SizedBox(width: 14)
          else
            IconButton(onPressed: () => Navigator.maybePop(context), icon: const Icon(Icons.arrow_back)),
          Text(
            'DevKit',
            style: TextStyle(color: Colors.green.shade400, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 14),
          Icon(Icons.smartphone, size: 16, color: scheme.outline),
          const SizedBox(width: 4),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: d.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: '  ${[d.model, _android, dev.target].nonNulls.join(' · ')}',
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          _FocusAppPicker(focus: _focus, installed: _installed),
          IconButton(
            tooltip: 'Restart app (Ctrl+R)',
            onPressed: _restartFocusApp,
            icon: const Icon(Icons.replay, size: 20),
          ),
          const VerticalDivider(indent: 14, endIndent: 14),
          // Flutter controls always visible, no need to open the Flutter tab.
          Icon(Icons.circle, size: 9, color: statusColor),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(statusText, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ),
          if (f.active)
            IconButton(
              tooltip: 'Stop (Shift+F5)',
              onPressed: f.stop,
              icon: const Icon(Icons.stop, color: Colors.red),
            )
          else
            IconButton(
              tooltip: f.project == null ? 'Run / Attach (opens Flutter tab)' : 'Run ${f.project!.name} again (F5)',
              onPressed: _flutterRun,
              icon: const Icon(Icons.play_arrow, color: Colors.green),
            ),
          IconButton(
            tooltip: 'Hot reload (Ctrl+F5)',
            onPressed: f.canReload ? () => f.reload() : null,
            icon: Icon(Icons.bolt, color: f.canReload ? Colors.amber : null),
          ),
          IconButton(
            tooltip: 'Hot restart (Ctrl+Shift+F5)',
            onPressed: f.canReload ? () => f.reload(full: true) : null,
            icon: const Icon(Icons.restart_alt),
          ),
          if (f.devToolsUri != null)
            IconButton(
              tooltip: 'Open DevTools',
              onPressed: () => Process.run('explorer', [f.devToolsUri!]),
              icon: const Icon(Icons.insights),
            ),
          const VerticalDivider(indent: 14, endIndent: 14),
          IconButton(tooltip: 'Type store code (Ctrl+K)', onPressed: _codePicker, icon: const Icon(Icons.pin_outlined)),
          _ScreenshotButton(onShot: _screenshot),
          IconButton(
            tooltip: 'Bug report (Ctrl+B)',
            onPressed: _bugReport,
            icon: const Icon(Icons.bug_report_outlined),
          ),
          _InstallButton(
            builds: _builds,
            installed: _installed,
            onOpen: _loadBuilds,
            onInstall: _install,
            onPick: _pickApk,
            onSetRoot: _pickProjectsRoot,
          ),
          IconButton(
            tooltip: 'Shortcut (Ctrl+/)',
            onPressed: _showShortcuts,
            icon: const Icon(Icons.keyboard_outlined),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: _fast
                ? 'Fast mode: embedded scrcpy (60 fps). Click for lite mode.'
                : 'Lite mode: periodic screenshots, type via DevKit. Click for fast mode.',
            child: TextButton.icon(
              onPressed: () {
                setState(() => _fast = !_fast);
                SharedPreferences.getInstance().then((p) => p.setBool(_prefFast, _fast));
              },
              icon: Icon(_fast ? Icons.bolt : Icons.photo_outlined, size: 18, color: _fast ? Colors.amber : null),
              label: Text(_fast ? 'Fast' : 'Lite'),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _openScrcpy,
            icon: Icon(_record ? Icons.fiber_manual_record : Icons.cast, size: 18, color: _record ? Colors.red : null),
            label: Text(_record ? 'Remote + Record' : 'Remote'),
          ),
          PopupMenuButton<String>(
            tooltip: 'scrcpy options',
            icon: const Icon(Icons.tune, size: 20),
            itemBuilder: (_) => [
              for (final o in _scrcpyOptions)
                CheckedPopupMenuItem(value: o.flag, checked: _scrcpyFlags.contains(o.flag), child: Text(o.label)),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'record', checked: _record, child: const Text('Record to file (.mp4)')),
            ],
            onSelected: (v) => setState(() {
              if (v == 'record') {
                _record = !_record;
              } else if (!_scrcpyFlags.remove(v)) {
                _scrcpyFlags.add(v);
              }
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// Compact top bar for narrow panels in Multi Screen.
  Widget _buildCompactBar(Device d, ColorScheme scheme) {
    final f = _flutter;
    final statusColor = switch (f.status) {
      FlutterStatus.running => Colors.green,
      FlutterStatus.starting || FlutterStatus.reloading => Colors.orange,
      _ => scheme.outline,
    };
    Widget icon(IconData i, String tip, VoidCallback? onTap, {Color? color}) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      icon: Icon(i, size: 19, color: onTap == null ? null : color),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: d.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                TextSpan(
                  text: '  ${[d.model, _android].nonNulls.join(' · ')}',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ],
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _FocusAppPicker(focus: _focus, installed: _installed),
              icon(Icons.replay, 'Restart app (Ctrl+R)', _restartFocusApp),
              Container(
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: statusColor),
                    const SizedBox(width: 4),
                    const Text('Flutter', style: TextStyle(fontSize: 12)),
                    f.active
                        ? icon(Icons.stop, 'Stop (Shift+F5)', f.stop, color: Colors.red)
                        : icon(Icons.play_arrow, 'Run / Attach (F5)', _flutterRun, color: Colors.green),
                    icon(
                      Icons.bolt,
                      'Hot reload (Ctrl+F5)',
                      f.canReload ? () => f.reload() : null,
                      color: Colors.amber,
                    ),
                    icon(
                      Icons.restart_alt,
                      'Hot restart (Ctrl+Shift+F5)',
                      f.canReload ? () => f.reload(full: true) : null,
                    ),
                  ],
                ),
              ),
              icon(Icons.pin_outlined, 'Type store code (Ctrl+K)', _codePicker),
              _ScreenshotButton(onShot: _screenshot),
              icon(Icons.bug_report_outlined, 'Bug report (Ctrl+B)', _bugReport),
              _InstallButton(
                builds: _builds,
                installed: _installed,
                onOpen: _loadBuilds,
                onInstall: _install,
                onPick: _pickApk,
                onSetRoot: _pickProjectsRoot,
              ),
              icon(Icons.open_in_new, 'Open in separate window', () => openWorkspaceWindow(d)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(Device d) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Wrap(
            children: [
              for (var i = 0; i < _tabs.length; i++)
                _PanelTab(
                  label: _tabs[i],
                  selected: _tab == i,
                  badge: switch (i) {
                    0 when _flutter.status == FlutterStatus.running => '●',
                    1 when _log.crashes.isNotEmpty => '${_log.crashes.length}',
                    _ => null,
                  },
                  tooltip: 'Ctrl+${i + 1}',
                  onTap: () => _setTab(i),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          // IndexedStack keeps each tab's state (log, flutter run) alive when switching tabs.
          child: IndexedStack(
            index: _tab,
            children: [
              FlutterTab(session: _flutter, focus: _focus),
              LogcatTab(log: _log, deviceName: d.displayName, focus: _focus),
              AppsTab(dev: dev, onInstall: _pickApk),
              DevTab(dev: dev),
              InfoTab(dev: dev),
              ShellTab(dev: dev, focus: _focus),
              FilesTab(dev: dev, dir: _filesDir, refresh: _filesRefresh),
              TerminalTab(dev: dev, focus: _focus, active: _tab == _tabs.length - 1),
            ],
          ),
        ),
      ],
    );
  }
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({required this.label, required this.selected, required this.onTap, this.badge, this.tooltip});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selected ? Colors.green : Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? scheme.onSurface : scheme.outline,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Text(badge!, style: TextStyle(fontSize: 11, color: badge == '●' ? Colors.green : Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onDrag, required this.onEnd, this.onDoubleTap});

  final void Function(double dx) onDrag;
  final VoidCallback onEnd;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (e) => onDrag(e.delta.dx),
      onHorizontalDragEnd: (_) => onEnd(),
      onDoubleTap: onDoubleTap,
      child: SizedBox(
        width: 7,
        child: Center(child: VerticalDivider(width: 1, color: Theme.of(context).dividerColor)),
      ),
    ),
  );
}

class _ScreenshotButton extends StatelessWidget {
  const _ScreenshotButton({required this.onShot});

  final Future<void> Function({bool saveAs}) onShot;

  @override
  Widget build(BuildContext context) => PopupMenuButton<bool>(
    tooltip: 'Screenshot (Ctrl+S)',
    icon: const Icon(Icons.photo_camera_outlined),
    onSelected: (saveAs) => onShot(saveAs: saveAs),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: false,
        child: ListTile(
          leading: Icon(Icons.content_paste),
          title: Text('Screenshot + copy image'),
          subtitle: Text('Ctrl+S · then Ctrl+V in Slack/Jira'),
        ),
      ),
      PopupMenuItem(
        value: true,
        child: ListTile(leading: Icon(Icons.save_as_outlined), title: Text('Save as…'), subtitle: Text('Ctrl+Shift+S')),
      ),
    ],
  );
}

class _InstallButton extends StatelessWidget {
  const _InstallButton({
    required this.builds,
    required this.installed,
    required this.onOpen,
    required this.onInstall,
    required this.onPick,
    required this.onSetRoot,
  });

  final List<LocalBuild> builds;
  final Map<String, String> installed;
  final VoidCallback onOpen;
  final void Function(String path) onInstall;
  final VoidCallback onPick;
  final VoidCallback onSetRoot;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'Install',
      icon: const Icon(Icons.install_mobile),
      onOpened: onOpen,
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        const PopupMenuItem(enabled: false, height: 32, child: Text('Latest project builds (Ctrl+I)')),
        if (builds.isEmpty) const PopupMenuItem(enabled: false, child: Text('No APKs in build/app/outputs yet')),
        for (final b in builds)
          PopupMenuItem(
            value: () => onInstall(b.apk.path),
            child: ListTile(
              leading: Icon(
                isOurApp(b.package) ? Icons.star : Icons.android,
                color: isOurApp(b.package) ? Colors.amber : null,
              ),
              title: Text(isOurApp(b.package) ? appName(b.package) : b.project),
              subtitle: Text(
                '${b.fileName} · ${timeAgo(b.modified)}'
                '${installed[b.package] != null ? ' · installed ${installed[b.package]}' : ''}',
                style: TextStyle(color: outline),
              ),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: onPick,
          child: const ListTile(leading: Icon(Icons.file_open_outlined), title: Text('Choose APK…')),
        ),
        PopupMenuItem(
          value: onSetRoot,
          child: const ListTile(leading: Icon(Icons.folder_open), title: Text('Set project folders…')),
        ),
      ],
    );
  }
}

class _FocusAppPicker extends StatelessWidget {
  const _FocusAppPicker({required this.focus, required this.installed});

  final ValueNotifier<String?> focus;
  final Map<String, String> installed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Installed apps first, then known apps not yet on the device.
    final packages = {...installed.keys, ...knownApps.map((a) => a.package)};
    return ValueListenableBuilder(
      valueListenable: focus,
      builder: (_, value, _) => Container(
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('App: ', style: TextStyle(color: scheme.outline, fontSize: 12)),
            DropdownButton<String?>(
              value: value,
              underline: const SizedBox.shrink(),
              isDense: true,
              style: const TextStyle(fontSize: 13),
              borderRadius: BorderRadius.circular(8),
              items: [
                const DropdownMenuItem(value: null, child: Text('All our apps')),
                for (final p in packages)
                  DropdownMenuItem(
                    value: p,
                    child: Text(
                      installed.containsKey(p) ? '${appName(p)}  ${installed[p]}' : '${appName(p)} (not installed)',
                      style: installed.containsKey(p) ? null : TextStyle(color: scheme.outline),
                    ),
                  ),
              ],
              onChanged: (v) => focus.value = v,
            ),
          ],
        ),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            border: Border.all(color: scheme.primary, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined, size: 56, color: scheme.primary),
                const SizedBox(height: 8),
                Text('Drop here', style: Theme.of(context).textTheme.titleLarge),
                const Text('.apk → install  ·  other files → push to device'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final _Task task;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (task.status) {
      _TaskStatus.running => (null, null),
      _TaskStatus.ok => (Icons.check_circle, Colors.green),
      _TaskStatus.failed => (Icons.error, Colors.red),
    };
    return Card(
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (icon == null)
              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.label, overflow: TextOverflow.ellipsis),
                  if (task.detail != null)
                    Text(task.detail!, style: const TextStyle(color: Colors.red, fontSize: 12), maxLines: 3),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
