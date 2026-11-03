import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../main.dart' show workspaceArg;
import '../modules/devices/models/device.dart';
import '../modules/devices/services/flutter_hub.dart';

final _open = <String, Process>{};

const projectWindowArg = '--project=';

/// The folder this window was opened for. Empty is a new window with no project yet, and null is the first window.
String? startupProject;

String? startupProjectOf(List<String> args) {
  final arg = args.where((a) => a.startsWith(projectWindowArg)).firstOrNull;
  return arg?.substring(projectWindowArg.length);
}

/// What another window of this app starts with. A debugger's engine switches stay behind:
/// with `start-paused` the new window would wait forever for a debugger that isn't attached to it.
Map<String, String> windowEnvironment(Map<String, String> environment) => {
  for (final e in environment.entries)
    if (!e.key.toUpperCase().startsWith('FLUTTER_ENGINE_SWITCH')) e.key: e.value,
};

/// Another window of the IDE, with its own analyzer, terminal and runs. It lives on after this one closes.
Future<void> openProjectWindow([String folder = '']) async {
  await Process.start(
    Platform.resolvedExecutable,
    ['$projectWindowArg$folder'],
    mode: ProcessStartMode.detached,
    environment: windowEnvironment(Platform.environment),
    includeParentEnvironment: false,
  );
}

/// Ids of devices with a workspace window open.
final openWorkspaces = ValueNotifier<Set<String>>(const {});

/// Opens a device workspace in its own window (process); if already open, brings it to the front.
Future<void> openWorkspaceWindow(Device d) async {
  final existing = _open[d.id];
  if (existing != null) {
    final alive = await existing.exitCode.timeout(Duration.zero, onTimeout: () => -999) == -999;
    if (alive) {
      if (Platform.isMacOS) {
        await Process.run('osascript', ['-e', 'tell application "System Events" to set frontmost of (first process whose unix id is ${existing.pid}) to true']);
      } else {
        await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '(New-Object -ComObject WScript.Shell).AppActivate(${existing.pid})',
        ]);
      }
      return;
    }
  }
  final payload = base64Url.encode(utf8.encode(jsonEncode(d.toJson())));
  final p = await Process.start(Platform.resolvedExecutable, [
    '$workspaceArg$payload',
    '--title=${d.displayName} · HotRestart',
    '--cascade=${_open.length + 1}',
  ], environment: {...windowEnvironment(Platform.environment), ...FlutterHub.instance.childEnvironment}, includeParentEnvironment: false);
  // Child window output is unused; drained so the pipe buffer doesn't fill up.
  p.stdout.drain<void>();
  p.stderr.drain<void>();
  _open[d.id] = p;
  openWorkspaces.value = {..._open.keys};
  p.exitCode.then((_) {
    if (_open[d.id] == p) _open.remove(d.id);
    openWorkspaces.value = {..._open.keys};
  });
}
