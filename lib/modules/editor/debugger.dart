import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

String? packageNameOf(String root) {
  try {
    return RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(File(p.join(root, 'pubspec.yaml')).readAsStringSync())?[1];
  } on FileSystemException {
    return null;
  }
}

/// The URI the VM knows a source file by. On a device only `package:` URIs match, file paths are the host's.
String scriptUriOf(String root, String? package, String path) {
  final lib = p.join(root, 'lib');
  if (package == null || !p.isWithin(lib, path)) return p.toUri(path).toString();
  return 'package:$package/${p.split(p.relative(path, from: lib)).join('/')}';
}

String? localPathOf(String root, String? package, String uri) {
  if (package != null && uri.startsWith('package:$package/')) {
    return p.joinAll([root, 'lib', ...uri.substring('package:$package/'.length).split('/')]);
  }
  return uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : null;
}

/// Where breakpoints land after an edit changed the line count; [cursor] is the cursor line after the edit.
Set<int> shiftLines(Set<int> lines, {required int cursor, required int delta, required bool atLineStart}) {
  if (delta == 0) return lines;
  if (delta > 0) {
    final from = cursor - delta + (atLineStart ? 0 : 1);
    return {for (final l in lines) l >= from ? l + delta : l};
  }
  // Lines inside the deleted range collapse onto the line that swallowed them.
  return {for (final l in lines) l > cursor - delta ? l + delta : (l > cursor ? cursor : l)};
}

enum DebugState { disconnected, running, paused }

class DebugFrame {
  const DebugFrame(this.index, this.function, this.uri, this.path, this.line, this.column);

  final int index;
  final String function, uri;
  final String? path;
  final int line, column;
}

class DebugVariable {
  DebugVariable(this.name, Object? raw) : ref = raw is vm.InstanceRef ? raw : null, value = _describe(raw);

  final String name, value;
  final vm.InstanceRef? ref;

  bool get expandable => switch (ref?.kind) {
    null || vm.InstanceKind.kNull || vm.InstanceKind.kBool || vm.InstanceKind.kInt => false,
    vm.InstanceKind.kDouble || vm.InstanceKind.kString => false,
    _ => true,
  };

  static String _describe(Object? raw) {
    if (raw is! vm.InstanceRef) return '<not available>';
    final text = raw.valueAsString;
    final more = raw.valueAsStringIsTruncated == true ? '…' : '';
    if (raw.kind == vm.InstanceKind.kString) return '"$text$more"';
    if (text != null) return text;
    final type = raw.classRef?.name ?? raw.kind ?? '?';
    return raw.length == null ? type : '$type (${raw.length})';
  }
}

/// Talks to a running app over the VM service. Breakpoints outlive the session, so they're there for the next run.
class Debugger extends ChangeNotifier {
  final breakpoints = <String, Set<int>>{};
  ValueChanged<String>? onMessage;

  DebugState state = DebugState.disconnected;
  String pauseReason = '';
  String exceptionMode = vm.ExceptionPauseMode.kUnhandled;
  List<DebugFrame> frames = const [];
  List<DebugVariable> variables = const [];
  var selectedFrame = 0;

  vm.VmService? _service;
  var _root = '';
  String? _package;
  final _subs = <StreamSubscription<vm.Event>>[];
  final _adopted = <String, Future<void>>{};
  final _installed = <String, Map<String, String>>{};
  String? _pausedIsolate;
  bool _atAsync = false;
  List<vm.Frame> _rawFrames = const [];
  Future<void> _queue = Future.value();
  var _disposed = false;

  bool get connected => _service != null;
  bool get paused => state == DebugState.paused;
  bool get hasBreakpoints => breakpoints.values.any((s) => s.isNotEmpty);
  DebugFrame? get currentFrame => paused ? frames.elementAtOrNull(selectedFrame) : null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool hasBreakpoint(String path, int line) => breakpoints[path]?.contains(line) == true;

  void toggleBreakpoint(String path, int line) {
    final set = breakpoints.putIfAbsent(path, () => {});
    if (!set.remove(line)) set.add(line);
    if (set.isEmpty) breakpoints.remove(path);
    _changed();
    unawaited(_syncAll());
  }

  void shiftBreakpoints(String path, {required int cursor, required int delta, required bool atLineStart}) {
    final set = breakpoints[path];
    if (set == null) return;
    breakpoints[path] = shiftLines(set, cursor: cursor, delta: delta, atLineStart: atLineStart);
    _changed();
  }

  Future<void> connect(String wsUri, String root) async {
    await disconnect();
    _root = root;
    _package = packageNameOf(root);
    final service = await vmServiceConnectUri(wsUri);
    _service = service;
    state = DebugState.running;
    _subs
      ..add(service.onDebugEvent.listen(_onDebug))
      ..add(service.onIsolateEvent.listen(_onIsolate));
    unawaited(
      service.onDone.then((_) {
        if (identical(_service, service)) unawaited(disconnect());
      }),
    );
    await service.streamListen(vm.EventStreams.kDebug);
    await service.streamListen(vm.EventStreams.kIsolate);
    final info = await service.getVM();
    for (final ref in info.isolates ?? const <vm.IsolateRef>[]) {
      await _safely(() async {
        final isolate = await service.getIsolate(ref.id!);
        if (isolate.pauseEvent case final event?) await _onPause(ref.id!, event);
      });
    }
    _changed();
  }

  Future<void> disconnect() async {
    final service = _service;
    _service = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _adopted.clear();
    _installed.clear();
    _clearPause();
    state = DebugState.disconnected;
    _changed();
    await service?.dispose();
  }

  void _clearPause() {
    _pausedIsolate = null;
    _rawFrames = const [];
    frames = const [];
    variables = const [];
    selectedFrame = 0;
    pauseReason = '';
  }

  // The isolate may be gone, or the app closed, by the time a call lands.
  Future<void> _safely(Future<void> Function() call) async {
    try {
      await call();
    } on vm.SentinelException {
      // Isolate exited.
    } on vm.RPCError catch (e) {
      onMessage?.call('Debugger: ${e.details ?? e.message}');
    } on StateError {
      // Service closed mid-call.
    }
  }

  Future<void> _adopt(String id) => _adopted[id] ??= _safely(() async {
    await _service?.setIsolatePauseMode(id, exceptionPauseMode: exceptionMode);
    await _syncIsolate(id);
  });

  Future<void> _syncAll({bool reinstall = false}) => _queue = _queue.then((_) async {
    for (final id in _adopted.keys.toList()) {
      await _syncIsolate(id, reinstall: reinstall);
    }
  });

  Future<void> _syncIsolate(String id, {bool reinstall = false}) async {
    final service = _service;
    if (service == null) return;
    final installed = _installed.putIfAbsent(id, () => {});
    final wanted = {
      for (final e in breakpoints.entries)
        for (final line in e.value) '${scriptUriOf(_root, _package, e.key)}:${line + 1}',
    };
    for (final key in installed.keys.where((k) => reinstall || !wanted.contains(k)).toList()) {
      final bp = installed.remove(key)!;
      await _safely(() => service.removeBreakpoint(id, bp));
    }
    for (final key in wanted.where((k) => !installed.containsKey(k))) {
      final split = key.lastIndexOf(':');
      await _safely(() async {
        final bp = await service.addBreakpointWithScriptUri(id, key.substring(0, split), int.parse(key.substring(split + 1)));
        installed[key] = bp.id!;
      });
    }
  }

  void _onIsolate(vm.Event e) {
    final id = e.isolate?.id;
    if (id == null) return;
    switch (e.kind) {
      case vm.EventKind.kIsolateRunnable:
        unawaited(_adopt(id));
      case vm.EventKind.kIsolateExit:
        _adopted.remove(id);
        _installed.remove(id);
        if (_pausedIsolate == id) {
          _clearPause();
          state = DebugState.running;
          _changed();
        }
      // A reload moves code, so the old positions no longer hold.
      case vm.EventKind.kIsolateReload:
        unawaited(_syncAll(reinstall: true));
    }
  }

  void _onDebug(vm.Event e) {
    final id = e.isolate?.id;
    if (id == null) return;
    if (e.kind == vm.EventKind.kResume) {
      if (_pausedIsolate == id) {
        _clearPause();
        state = DebugState.running;
        _changed();
      }
      return;
    }
    unawaited(_onPause(id, e));
  }

  Future<void> _onPause(String id, vm.Event e) async {
    switch (e.kind) {
      // Paused so breakpoints can go in before any code runs.
      case vm.EventKind.kPauseStart:
        await _adopt(id);
        await _safely(() async => _service?.resume(id));
      case vm.EventKind.kPauseExit:
        await _safely(() async => _service?.resume(id));
      case vm.EventKind.kPauseBreakpoint || vm.EventKind.kPauseException || vm.EventKind.kPauseInterrupted || vm.EventKind.kPausePostRequest:
        await _adopt(id);
        _pausedIsolate = id;
        _atAsync = e.atAsyncSuspension == true;
        pauseReason = switch (e.kind) {
          vm.EventKind.kPauseException => 'Exception: ${DebugVariable('', e.exception).value}',
          vm.EventKind.kPauseBreakpoint => 'Breakpoint',
          _ => 'Paused',
        };
        await _loadStack(id);
      default:
        await _adopt(id);
    }
  }

  Future<void> _loadStack(String id) async {
    final service = _service;
    if (service == null) return;
    await _safely(() async {
      final stack = await service.getStack(id, limit: 100);
      _rawFrames = stack.frames ?? const [];
      final raw = (stack.asyncCausalFrames ?? _rawFrames).where((f) => f.location?.script?.uri != null).toList();
      final uris = {for (final f in raw) f.location!.script!.uri!}.toList();
      final resolved = <String, String?>{for (final u in uris) u: localPathOf(_root, _package, u)};
      final unknown = uris.where((u) => resolved[u] == null).toList();
      if (unknown.isNotEmpty) {
        final local = await service.lookupResolvedPackageUris(id, unknown, local: true);
        for (final (i, u) in unknown.indexed) {
          final hit = local.uris?.elementAtOrNull(i);
          if (hit != null && hit.startsWith('file:')) resolved[u] = Uri.parse(hit).toFilePath();
        }
      }
      frames = [
        for (final (i, f) in raw.indexed)
          DebugFrame(
            f.index ?? i,
            _functionName(f),
            f.location!.script!.uri!,
            resolved[f.location!.script!.uri!],
            (f.location!.line ?? 1) - 1,
            (f.location!.column ?? 1) - 1,
          ),
      ];
      state = DebugState.paused;
      selectFrame(0);
    });
    _changed();
  }

  String _functionName(vm.Frame f) {
    final fn = f.function;
    final owner = fn?.owner;
    final name = fn?.name ?? f.code?.name ?? '<unknown>';
    return owner is vm.ClassRef && owner.name != null ? '${owner.name}.$name' : name;
  }

  void selectFrame(int i) {
    selectedFrame = i;
    final index = frames.elementAtOrNull(i)?.index;
    final raw = _rawFrames.where((f) => f.index == index).firstOrNull;
    variables = [for (final v in raw?.vars ?? const <vm.BoundVariable>[]) DebugVariable(v.name ?? '?', v.value)];
    _changed();
  }

  Future<List<DebugVariable>> children(DebugVariable v) async {
    final service = _service, id = _pausedIsolate, ref = v.ref;
    if (service == null || id == null || ref?.id == null) return const [];
    try {
      final o = await service.getObject(id, ref!.id!, count: 200);
      if (o is! vm.Instance) return const [];
      return [
        for (final f in o.fields ?? const <vm.BoundField>[]) DebugVariable('${f.name ?? '?'}', f.value),
        for (final (i, e) in (o.elements ?? const []).indexed) DebugVariable('[$i]', e),
        for (final a in o.associations ?? const <vm.MapAssociation>[])
          DebugVariable('[${DebugVariable('', a.key).value}]', a.value),
      ];
    } on vm.RPCError {
      return const [];
    } on vm.SentinelException {
      return const [];
    }
  }

  Future<String> evaluate(String expression) async {
    final service = _service, id = _pausedIsolate, frame = currentFrame;
    if (service == null || id == null || frame == null) return 'Pause the app to evaluate';
    try {
      final r = await service.evaluateInFrame(id, frame.index, expression);
      return r is vm.ErrorRef ? (r.message ?? 'Error') : DebugVariable('', r).value;
    } on vm.RPCError catch (e) {
      return e.details ?? e.message;
    } on vm.SentinelException {
      return '<not available>';
    }
  }

  Future<void> resume() => _resume(null);
  Future<void> stepInto() => _resume(vm.StepOption.kInto);
  Future<void> stepOut() => _resume(vm.StepOption.kOut);
  Future<void> stepOver() => _resume(_atAsync ? vm.StepOption.kOverAsyncSuspension : vm.StepOption.kOver);

  Future<void> _resume(String? step) async {
    final service = _service, id = _pausedIsolate;
    if (service == null || id == null) return;
    // Don't wait for the Resume event: a second Step press in between would act on stale frames.
    _clearPause();
    state = DebugState.running;
    _changed();
    await _safely(() async => service.resume(id, step: step));
  }

  Future<void> pause() async {
    final service = _service;
    if (service == null || paused) return;
    for (final id in _adopted.keys.toList()) {
      await _safely(() async => service.pause(id));
    }
  }

  Future<void> setExceptionMode(String mode) async {
    exceptionMode = mode;
    _changed();
    for (final id in _adopted.keys.toList()) {
      await _safely(() async => _service?.setIsolatePauseMode(id, exceptionPauseMode: mode));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
