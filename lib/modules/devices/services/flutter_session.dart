import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';

import '../../../core/local_builds.dart';
import '../../../core/history.dart';
import '../../../core/child_processes.dart';

enum FlutterLineKind { build, log, error, info, success }

class FlutterLine {
  FlutterLine(this.text, this.kind) : time = DateTime.now();

  final String text;
  final FlutterLineKind kind;
  final DateTime time;
}

enum FlutterStatus { idle, starting, running, reloading, stopped }

/// `flutter run/attach --machine` for one device. The JSON daemon protocol is more reliable than sending "r" to stdin.
class FlutterSession extends ChangeNotifier {
  FlutterSession(this.deviceId);

  final String deviceId;
  static const maxLines = 15000;

  final lines = <FlutterLine>[];

  /// Every line there has ever been, which outlasts the trimming of [lines].
  var appended = 0;

  /// Goes up when the log is cleared.
  var generation = 0;
  FlutterProject? project;
  FlutterStatus status = FlutterStatus.idle;
  String? progress;
  String? devToolsUri;
  String? vmServiceUri;
  bool attachMode = false;
  bool reloadOnSave = true;

  Process? _process;
  String? _appId;
  var _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _watchDebounce;
  Timer? _flush;
  var _dirty = false;
  final _stopwatch = Stopwatch();

  bool get active =>
      status == FlutterStatus.starting || status == FlutterStatus.running || status == FlutterStatus.reloading;

  bool get canReload => status == FlutterStatus.running && _appId != null;

  SessionLog? _session;

  void _add(String text, FlutterLineKind kind) {
    _session?.writeln(text);
    lines.add(FlutterLine(text, kind));
    appended++;
    if (lines.length > maxLines + 1000) lines.removeRange(0, lines.length - maxLines);
    _dirty = true;
  }

  void _set(FlutterStatus s, {String? progressText}) {
    status = s;
    progress = progressText;
    notifyListeners();
  }

  List<String> _lastArgs = const [];

  /// Re-run with the last project & arguments (F5).
  Future<void> relaunch() async {
    final p = project;
    if (p != null && !active) await start(p, attach: attachMode, extraArgs: _lastArgs);
  }

  Future<void> start(FlutterProject p, {required bool attach, List<String> extraArgs = const []}) async {
    if (active) return;
    project = p;
    _lastArgs = extraArgs;
    attachMode = attach;
    _appId = null;
    devToolsUri = null;
    vmServiceUri = null;
    _flush ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_dirty) return;
      _dirty = false;
      notifyListeners();
    });
    final args = [attach ? 'attach' : 'run', '--machine', '-d', deviceId, ...extraArgs];
    await _session?.close();
    _session = await History.session('flutter', '${deviceId}_${p.name}');
    History.activity('flutter', '${attach ? 'Attach' : 'Run'} ${p.name} on $deviceId', {
      'project': p.path,
      'args': extraArgs.join(' '),
      'log': _session!.file.path,
    });
    final sdk = p.flutterSdk;
    final (exe, fullArgs) = sdk != null
        ? (path.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'), args)
        : (p.usesFvm ? ('fvm', ['flutter', ...args]) : ('flutter', args));
    _add('\$ ${exe == 'fvm' ? 'fvm flutter' : exe} ${args.join(' ')}   (${p.path})', FlutterLineKind.info);
    _set(FlutterStatus.starting, progressText: attach ? 'Waiting for debug app on device…' : 'Building…');
    try {
      // flutter.bat needs a shell on Windows.
      _process = await Process.start(exe, fullArgs, workingDirectory: p.path, runInShell: Platform.isWindows);
    } catch (e) {
      _add('Failed to run flutter: $e', FlutterLineKind.error);
      _set(FlutterStatus.stopped);
      return;
    }
    _stopwatch
      ..reset()
      ..start();
    _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => _add(l, FlutterLineKind.error));
    _process!.exitCode.then((code) {
      _add('flutter process exited (exit $code)', code == 0 ? FlutterLineKind.info : FlutterLineKind.error);
      _process = null;
      _appId = null;
      vmServiceUri = null;
      _stopWatching();
      _set(FlutterStatus.stopped);
    });
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[{')) {
      if (trimmed.isNotEmpty) _add(line, FlutterLineKind.build);
      return;
    }
    List<dynamic> msgs;
    try {
      msgs = jsonDecode(trimmed) as List<dynamic>;
    } catch (_) {
      _add(line, FlutterLineKind.build);
      return;
    }
    for (final m in msgs.cast<Map<String, dynamic>>()) {
      final id = m['id'];
      if (id is int && _pending.containsKey(id)) {
        _pending.remove(id)!.complete(m);
        continue;
      }
      _onEvent(m['event'] as String?, (m['params'] as Map?)?.cast<String, dynamic>() ?? const {});
    }
  }

  void _onEvent(String? event, Map<String, dynamic> p) {
    switch (event) {
      case 'app.start':
        _appId = p['appId'] as String?;
      case 'app.started':
        _add('✓ App running (${(_stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)', FlutterLineKind.success);
        _set(FlutterStatus.running);
        _startWatching();
      case 'app.log':
        final text = (p['log'] as String? ?? '').trimRight();
        final error = p['error'] == true;
        for (final l in text.split('\n')) {
          _add(l, error ? FlutterLineKind.error : FlutterLineKind.log);
        }
        final stack = p['stackTrace'] as String?;
        if (stack != null && stack.isNotEmpty) {
          for (final l in stack.trimRight().split('\n')) {
            _add(l, FlutterLineKind.error);
          }
        }
      case 'app.progress':
        if (p['finished'] == true) {
          if (status == FlutterStatus.starting) progress = null;
        } else if (p['message'] is String) {
          progress = p['message'] as String;
          _add(progress!, FlutterLineKind.build);
        }
        notifyListeners();
      case 'app.devTools':
        devToolsUri = p['uri'] as String?;
        notifyListeners();
      case 'app.debugPort':
        _add('VM service: ${p['wsUri']}', FlutterLineKind.info);
        vmServiceUri = p['wsUri'] as String?;
        notifyListeners();
      case 'daemon.logMessage':
        final level = p['level'];
        _add('${p['message']}', level == 'error' ? FlutterLineKind.error : FlutterLineKind.build);
      case 'app.stop':
        if (p['error'] != null) _add('${p['error']}', FlutterLineKind.error);
      default:
    }
  }

  Future<Map<String, dynamic>?> _request(String method, Map<String, dynamic> params) async {
    final p = _process;
    if (p == null) return null;
    final id = ++_nextId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    p.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    return c.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pending.remove(id);
        return {'error': 'timeout'};
      },
    );
  }

  Future<void> reload({bool full = false}) async {
    if (!canReload) return;
    final label = full ? 'Hot restart' : 'Hot reload';
    _set(FlutterStatus.reloading, progressText: '$label…');
    final sw = Stopwatch()..start();
    final r = await _request('app.restart', {'appId': _appId, 'fullRestart': full, 'pause': false, 'reason': 'manual'});
    final result = (r?['result'] as Map?)?.cast<String, dynamic>();
    final ok = result != null && result['code'] == 0;
    final msg = result?['message'] ?? r?['error'] ?? 'failed';
    _add(
      ok ? '⚡ $label done (${sw.elapsedMilliseconds} ms)' : '$label failed: $msg',
      ok ? FlutterLineKind.success : FlutterLineKind.error,
    );
    if (_process != null) _set(FlutterStatus.running);
  }

  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    _add(attachMode ? 'Detach…' : 'Stop app…', FlutterLineKind.info);
    if (_appId != null) await _request(attachMode ? 'app.detach' : 'app.stop', {'appId': _appId});
    // Fallback: kill the whole process tree (cmd → flutter → dart).
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_process != null) await _killTree(p);
  }

  Future<void> _killTree(Process p) async {
    await ChildProcesses.killTree(p);
  }

  void note(String text, {bool error = false}) {
    _add(text, error ? FlutterLineKind.error : FlutterLineKind.info);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    generation++;
    notifyListeners();
  }

  void setReloadOnSave(bool v) {
    if (v == reloadOnSave) return;
    reloadOnSave = v;
    v && status == FlutterStatus.running ? _startWatching() : _stopWatching();
    notifyListeners();
  }

  void _startWatching() {
    if (!reloadOnSave || _watch != null || project == null) return;
    final lib = Directory('${project!.path}${Platform.pathSeparator}lib');
    if (!lib.existsSync()) return;
    _watch = lib.watch(recursive: true).where((e) => e.path.endsWith('.dart')).listen((_) {
      _watchDebounce?.cancel();
      _watchDebounce = Timer(const Duration(milliseconds: 400), () {
        if (canReload) reload();
      });
    });
  }

  void _stopWatching() {
    _watch?.cancel();
    _watch = null;
    _watchDebounce?.cancel();
  }

  @override
  void dispose() {
    final p = _process;
    if (p != null) _killTree(p);
    _stopWatching();
    _flush?.cancel();
    super.dispose();
  }
}
