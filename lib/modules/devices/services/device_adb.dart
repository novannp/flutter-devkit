import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/apps.dart';
import '../../../core/tools.dart';
import 'adb_service.dart';

export '../../../core/apps.dart';

/// All adb commands for one device (target = ip:port or USB serial).
class DeviceAdb {
  DeviceAdb(this.adb, this.target);

  final AdbService adb;
  final String target;

  String get _exe => adb.tools.adb!;

  Future<ProcessOutput> run(List<String> args, {Duration timeout = const Duration(seconds: 15)}) =>
      Tools.run(_exe, ['-s', target, ...args], timeout: timeout);

  Future<ProcessOutput> shell(String command, {Duration timeout = const Duration(seconds: 30)}) =>
      run(['shell', command], timeout: timeout);

  Future<String> sh(String command) async => (await shell(command)).stdout.trim();

  Future<Uint8List?> screenshot() =>
      Tools.runBytes(_exe, ['-s', target, 'exec-out', 'screencap', '-p']);

  Future<Process> logcat() => Process.start(_exe, ['-s', target, 'logcat', '-v', 'threadtime', '-T', '1000']);

  Future<void> clearLogcat() => run(['logcat', '-c']);

  Future<ProcessOutput> install(String apk) =>
      run(['install', '-r', '-d', apk], timeout: const Duration(minutes: 5));

  Future<ProcessOutput> push(String local, String remote) =>
      run(['push', local, remote], timeout: const Duration(minutes: 10));

  Future<ProcessOutput> pull(String remote, String local) =>
      run(['pull', remote, local], timeout: const Duration(minutes: 10));

  Future<void> tap(int x, int y) => shell('input tap $x $y');

  Future<void> swipe(int x1, int y1, int x2, int y2, int ms) => shell('input swipe $x1 $y1 $x2 $y2 $ms');

  Future<void> key(String keycode) => shell('input keyevent $keycode');

  Future<void> text(String value) {
    // `input text` reads %s as a space.
    final escaped = value.replaceAll(' ', '%s').replaceAll("'", r"'\''");
    return shell("input text '$escaped'");
  }

  /// pid → package for our running apps.
  Future<Map<int, String>> ourPids() async {
    final out = await sh('for p in \$(pm list packages --user 0 $ourPackagePrefix | cut -d: -f2); do echo "\$p \$(pidof \$p)"; done');
    return {
      for (final line in out.split('\n'))
        for (final pid in line.trim().split(' ').skip(1))
          if (int.tryParse(pid) != null) int.parse(pid): line.trim().split(' ').first,
    };
  }

  /// package → versionName for all of our installed apps.
  Future<Map<String, String>> ourApps() async {
    final out = await sh('for p in \$(pm list packages --user 0 $ourPackagePrefix | cut -d: -f2); do '
        'echo "\$p \$(dumpsys package \$p | grep -m1 versionName | cut -d= -f2)"; done');
    return {
      for (final line in out.split('\n'))
        if (line.trim().isNotEmpty) line.trim().split(' ').first: line.trim().split(' ').skip(1).join(' '),
    };
  }

  Future<List<String>> packages({bool thirdParty = true}) async {
    final out = await sh('pm list packages --user 0 ${thirdParty ? '-3' : ''}');
    return out
        .split('\n')
        .map((l) => l.trim().replaceFirst('package:', ''))
        .where((p) => p.isNotEmpty)
        .toList()
      ..sort();
  }

  /// Activation code stored in the app's station info. Only works on debuggable builds (run-as).
  Future<String?> activationCodeOf(String package) async {
    final bytes = await Tools.runBytes(_exe, [
      '-s',
      target,
      'exec-out',
      'run-as $package cat files/datastore/FlutterSharedPreferences.preferences_pb shared_prefs/FlutterSharedPreferences.xml 2>/dev/null; true',
    ]);
    if (bytes == null || bytes.isEmpty) return null;
    // DataStore (protobuf) stores JSON as-is; XML escapes quotes as &quot;.
    final text = utf8.decode(bytes, allowMalformed: true);
    final m = RegExp(r'activationCode(?:"|&quot;)\s*:\s*(?:"|&quot;)(\d*)').firstMatch(text);
    return m?[1];
  }

  Future<void> launch(String package) =>
      shell('monkey -p $package -c android.intent.category.LAUNCHER 1');

  Future<void> forceStop(String package) => shell('am force-stop $package');

  Future<ProcessOutput> clearData(String package) => shell('pm clear $package');

  Future<ProcessOutput> uninstall(String package) => run(['uninstall', package]);

  Future<void> reboot() => run(['reboot']);
}
