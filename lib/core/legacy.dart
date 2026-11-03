import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// One-time upgrade from the app's previous name. Delete this file once nobody runs the old build.
const legacyFirewallRule = 'Ravo DevKit';

const _prefsFile = 'shared_preferences.json';

/// Copies old app data into [to] unless it already has preferences. The preferences go last,
/// so an interrupted copy is retried on the next launch. Returns whether a copy happened.
Future<bool> copyLegacyData(Directory from, Directory to) async {
  final oldPrefs = File(p.join(from.path, _prefsFile));
  if (!oldPrefs.existsSync() || File(p.join(to.path, _prefsFile)).existsSync()) return false;
  await for (final e in from.list(recursive: true, followLinks: false)) {
    if (e is! File || e.path == oldPrefs.path) continue;
    final target = File(p.join(to.path, p.relative(e.path, from: from.path)));
    await target.parent.create(recursive: true);
    await e.copy(target.path);
  }
  await to.create(recursive: true);
  await oldPrefs.copy(p.join(to.path, _prefsFile));
  return true;
}

Future<void> migrateFromLegacyName() async {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return;
  try {
    final old = Directory(p.join(appData, 'com.ravo', 'Ravo DevKit'));
    await copyLegacyData(old, await getApplicationSupportDirectory());
  } catch (_) {
    // Starting fresh beats not starting; the old folder is left untouched.
  }
}
