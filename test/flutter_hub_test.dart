import 'dart:async';
import 'dart:io';

import 'package:hotrestart/core/local_builds.dart';
import 'package:hotrestart/modules/devices/services/flutter_hub.dart';
import 'package:hotrestart/modules/devices/services/flutter_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FlutterHub hub;
  late RemoteFlutterSession remote;
  final local = <FlutterSession>[];

  Future<void> until(bool Function() ok, String what) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue, reason: 'timed out waiting for $what');
  }

  setUp(() async {
    hub = FlutterHub(address: null, create: _FakeSession.new);
    await hub.start();
    remote = RemoteFlutterSession('device-1', hub.childEnvironment.values.single);
    local
      ..clear()
      ..add(hub.session('device-1'));
    // A line there and back says the window is connected.
    remote.note('ready');
    await until(() => remote.lines.any((l) => l.text == 'ready'), 'the window to connect');
    local.first.clear();
    await until(() => remote.lines.isEmpty, 'a clean start');
  });

  tearDown(() async {
    remote.dispose();
    await hub.close();
  });

  test('both sides see the same log, from either side', () async {
    local.first.note('from the IDE');
    await until(() => remote.lines.any((l) => l.text == 'from the IDE'), 'the IDE line');
    remote.note('from the device window', error: true);
    await until(() => local.first.lines.any((l) => l.text == 'from the device window'), 'the window line');
    expect(local.first.lines.last.kind, FlutterLineKind.error);
    await until(() => remote.lines.any((l) => l.text == 'from the device window'), 'its own line back');
    expect(remote.lines.where((l) => l.text == 'from the IDE').length, 1, reason: 'each line once');

    remote.clear();
    await until(() => local.first.lines.isEmpty && remote.lines.isEmpty, 'both to clear');
    local.first.note('after');
    await until(() => remote.lines.length == 1, 'only the new line');
  });

  test('a window that opens late still gets what came before', () async {
    local.first.note('early');
    final late_ = RemoteFlutterSession('device-1', hub.childEnvironment.values.single);
    addTearDown(late_.dispose);
    await until(() => late_.lines.any((l) => l.text == 'early'), 'the earlier line');
  });

  test('a session is per device', () async {
    expect(identical(hub.session('device-1'), local.first), isTrue);
    expect(identical(hub.session('device-2'), local.first), isFalse);
    hub.session('device-2').note('elsewhere');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(remote.lines, isEmpty);
  });

  test('a run started in the window happens in the main window, and shows on both sides', () async {
    const project = FlutterProject('p', 'C:/p', 'com.example.p', usesFvm: true);
    await remote.start(project, attach: false, extraArgs: const ['--flavor=dev']);
    final session = local.first as _FakeSession;
    await until(() => session.started != null, 'the run to start');
    expect((session.started!.path, session.started!.usesFvm), ('C:/p', true));
    expect(session.args, ['--flavor=dev']);
    await until(() => remote.status == FlutterStatus.running && remote.canReload, 'the window to follow');
    expect(remote.project?.name, 'p');

    await remote.reload(full: true);
    await until(() => session.reloads.isNotEmpty, 'hot restart');
    expect(session.reloads.single, isTrue);

    await remote.stop();
    await until(() => remote.status == FlutterStatus.stopped, 'the stop');
    expect(remote.canReload, isFalse);
  });

  test('a run started in the IDE shows in a window opened later', () async {
    const project = FlutterProject('p', 'C:/p', '', usesFvm: false);
    await local.first.start(project, attach: false);
    final late_ = RemoteFlutterSession('device-1', hub.childEnvironment.values.single);
    addTearDown(late_.dispose);
    await until(() => late_.status == FlutterStatus.running && late_.project?.path == 'C:/p', 'the window to see the run');
  });

  test('a wrong token gets nothing, and can do nothing', () async {
    final port = int.parse(hub.childEnvironment.values.single.split(':').first);
    final intruder = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(intruder.destroy);
    final closed = Completer<void>();
    final got = <int>[];
    intruder.listen(got.addAll, onDone: closed.complete, onError: (_) {});
    intruder.writeln('wrong');
    intruder.writeln('{"t":"sub","device":"device-1"}');
    await closed.future.timeout(const Duration(seconds: 5));
    expect(got, isEmpty);
  });

  test('losing the main window leaves the device window usable, and stopped', () async {
    await hub.close();
    await until(() => remote.status == FlutterStatus.stopped, 'the window to notice');
    expect(remote.canReload, isFalse);
  });
}

class _FakeSession extends FlutterSession {
  _FakeSession(super.deviceId);

  FlutterProject? started;
  List<String>? args;
  final reloads = <bool>[];
  var _running = false;

  @override
  bool get canReload => _running;

  @override
  Future<void> start(FlutterProject p, {required bool attach, List<String> extraArgs = const []}) async {
    started = project = p;
    args = extraArgs;
    _running = true;
    status = FlutterStatus.running;
    notifyListeners();
  }

  @override
  Future<void> reload({bool full = false}) async => reloads.add(full);

  @override
  Future<void> stop() async {
    _running = false;
    status = FlutterStatus.stopped;
    notifyListeners();
  }
}
