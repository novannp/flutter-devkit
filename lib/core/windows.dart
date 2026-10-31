import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../main.dart' show workspaceArg;
import '../modules/devices/models/device.dart';

final _open = <String, Process>{};

/// Ids of devices with a workspace window open.
final openWorkspaces = ValueNotifier<Set<String>>(const {});

/// Opens a device workspace in its own window (process); if already open, brings it to the front.
Future<void> openWorkspaceWindow(Device d) async {
  final existing = _open[d.id];
  if (existing != null) {
    final alive = await existing.exitCode.timeout(Duration.zero, onTimeout: () => -999) == -999;
    if (alive) {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(New-Object -ComObject WScript.Shell).AppActivate(${existing.pid})',
      ]);
      return;
    }
  }
  final payload = base64Url.encode(utf8.encode(jsonEncode(d.toJson())));
  final p = await Process.start(Platform.resolvedExecutable, [
    '$workspaceArg$payload',
    '--title=${d.displayName} · DevKit',
    '--cascade=${_open.length + 1}',
  ]);
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
