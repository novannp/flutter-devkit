import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/local_builds.dart';
import '../../../core/settings.dart';
import 'flutter_session.dart';

const _hubVariable = 'HOTRESTART_FLUTTER_HUB';

Map<String, Object?> _projectToJson(FlutterProject? p) => p == null
    ? const {}
    : {'name': p.name, 'path': p.path, 'package': p.package, 'usesFvm': p.usesFvm, 'flutterSdk': p.flutterSdk};

FlutterProject? _projectFromJson(Map<String, dynamic>? j) => j == null || j['path'] == null
    ? null
    : FlutterProject(j['name'] as String, j['path'] as String, j['package'] as String? ?? '', usesFvm: j['usesFvm'] == true, flutterSdk: j['flutterSdk'] as String?);

/// One `flutter run` per device, whoever started it. The main window owns the sessions, and a device's
/// window is another process, so it reaches them over a socket on this computer.
class FlutterHub {
  FlutterHub({String? address, FlutterSession Function(String device)? create})
    : _address = address ?? Platform.environment[_hubVariable],
      _create = create ?? FlutterSession.new;

  static final instance = FlutterHub();

  /// Set in a device's window: where the main window's hub is.
  final String? _address;
  final FlutterSession Function(String device) _create;
  final _sessions = <String, FlutterSession>{};
  ServerSocket? _server;
  String? _token;
  final _clients = <Socket>{};

  /// For a device window's process, to find this hub. The token keeps out anything else on the computer,
  /// since whoever gets in can start programs.
  Map<String, String> get childEnvironment => _server == null ? const {} : {_hubVariable: '${_server!.port}:$_token'};

  Future<void> start() async {
    if (_address != null || _server != null) return;
    final random = Random.secure();
    _token = base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
    final server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  FlutterSession session(String device) {
    final address = _address;
    if (address != null) return RemoteFlutterSession(device, address);
    return _sessions[device] ??= _create(device)..reloadOnSave = Settings.instance.flag('flutter.hotReloadOnSave');
  }

  /// When a window is done with a session. An app it started stays running: the IDE can still reach it.
  void release(FlutterSession session) {
    if (session is RemoteFlutterSession) session.dispose();
  }

  /// Ends every running app, when the whole program quits.
  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await _server?.close();
    _server = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }

  void _serve(Socket socket) {
    _clients.add(socket);
    var trusted = false;
    FlutterSession? session;
    VoidCallback? listener;
    void finish() {
      _clients.remove(socket);
      if (listener != null) session?.removeListener(listener!);
    }

    socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (!trusted) {
          trusted = line == _token;
          if (!trusted) socket.destroy();
          return;
        }
        final Map<String, dynamic> m;
        try {
          m = jsonDecode(line) as Map<String, dynamic>;
        } on FormatException {
          return;
        }
        if (m['t'] == 'sub') {
          final subscribed = session = this.session(m['device'] as String);
          var sent = subscribed.appended - subscribed.lines.length;
          var generation = subscribed.generation;
          void push() {
            if (subscribed.generation != generation) {
              generation = subscribed.generation;
              sent = subscribed.appended;
              _send(socket, {'t': 'clear'});
            }
            final fresh = subscribed.appended - sent;
            sent = subscribed.appended;
            _send(socket, {
              't': 'state',
              'status': subscribed.status.name,
              'progress': subscribed.progress,
              'devTools': subscribed.devToolsUri,
              'vmService': subscribed.vmServiceUri,
              'attach': subscribed.attachMode,
              'reloadOnSave': subscribed.reloadOnSave,
              'canReload': subscribed.canReload,
              'project': _projectToJson(subscribed.project),
              'lines': [
                for (final l in subscribed.lines.skip(max<int>(0, subscribed.lines.length - fresh))) {'text': l.text, 'kind': l.kind.name},
              ],
            });
          }

          listener = push;
          subscribed.addListener(push);
          push();
        } else if (session case final target?) {
          _command(target, m);
        }
      },
      onDone: finish,
      onError: (_) => finish(),
      cancelOnError: true,
    );
  }

  void _command(FlutterSession s, Map<String, dynamic> m) {
    switch (m['t']) {
      case 'start':
        final project = _projectFromJson((m['project'] as Map?)?.cast<String, dynamic>());
        if (project != null) unawaited(s.start(project, attach: m['attach'] == true, extraArgs: (m['args'] as List).cast<String>()));
      case 'relaunch':
        unawaited(s.relaunch());
      case 'reload':
        unawaited(s.reload(full: m['full'] == true));
      case 'stop':
        unawaited(s.stop());
      case 'clear':
        s.clear();
      case 'note':
        s.note(m['text'] as String, error: m['error'] == true);
      case 'reloadOnSave':
        final on = m['on'] == true;
        s.setReloadOnSave(on);
        // The same switch as the IDE's: settings.json is what both read.
        unawaited(Settings.instance.update('flutter.hotReloadOnSave', on));
    }
  }

  void _send(Socket socket, Map<String, Object?> message) {
    try {
      socket.writeln(jsonEncode(message));
    } on Object {
      // Its window just closed: onDone tidies up.
    }
  }
}

/// A session in the main window, seen and driven from a device's window.
class RemoteFlutterSession extends FlutterSession {
  RemoteFlutterSession(super.deviceId, String address) {
    final split = address.indexOf(':');
    final port = int.tryParse(address.substring(0, max(split, 0)));
    if (port == null) return;
    unawaited(_connect(port, address.substring(split + 1)));
  }

  Socket? _socket;
  final _waiting = <Map<String, Object?>>[];
  var _canReload = false;
  var _closed = false;

  @override
  bool get canReload => _canReload;

  Future<void> _connect(int port, String token) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      if (_closed) return socket.destroy();
      _socket = socket;
      socket.writeln(token);
      socket.writeln(jsonEncode({'t': 'sub', 'device': deviceId}));
      for (final m in _waiting) {
        socket.writeln(jsonEncode(m));
      }
      _waiting.clear();
      socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        _onMessage,
        onDone: _onLost,
        onError: (_) => _onLost(),
        cancelOnError: true,
      );
    } on SocketException {
      _onLost();
    }
  }

  void _onMessage(String line) {
    if (_closed) return;
    final m = jsonDecode(line) as Map<String, dynamic>;
    if (m['t'] == 'clear') {
      lines.clear();
      return notifyListeners();
    }
    status = FlutterStatus.values.byName(m['status'] as String);
    progress = m['progress'] as String?;
    devToolsUri = m['devTools'] as String?;
    vmServiceUri = m['vmService'] as String?;
    attachMode = m['attach'] == true;
    reloadOnSave = m['reloadOnSave'] == true;
    _canReload = m['canReload'] == true;
    project = _projectFromJson((m['project'] as Map?)?.cast<String, dynamic>());
    for (final l in (m['lines'] as List).cast<Map<String, dynamic>>()) {
      lines.add(FlutterLine(l['text'] as String, FlutterLineKind.values.byName(l['kind'] as String)));
    }
    notifyListeners();
  }

  void _onLost() {
    if (_closed) return;
    status = FlutterStatus.stopped;
    _canReload = false;
    notifyListeners();
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) {
      _waiting.add(message);
    } else {
      socket.writeln(jsonEncode(message));
    }
  }

  @override
  Future<void> start(FlutterProject p, {required bool attach, List<String> extraArgs = const []}) async =>
      _send({'t': 'start', 'project': _projectToJson(p), 'attach': attach, 'args': extraArgs});

  @override
  Future<void> relaunch() async => _send({'t': 'relaunch'});

  @override
  Future<void> reload({bool full = false}) async => _send({'t': 'reload', 'full': full});

  @override
  Future<void> stop() async => _send({'t': 'stop'});

  @override
  void clear() => _send({'t': 'clear'});

  @override
  void note(String text, {bool error = false}) => _send({'t': 'note', 'text': text, 'error': error});

  @override
  void setReloadOnSave(bool v) => _send({'t': 'reloadOnSave', 'on': v});

  @override
  void dispose() {
    _closed = true;
    _socket?.destroy();
    super.dispose();
  }
}
