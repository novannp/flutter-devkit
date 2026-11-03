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

  Future<Uint8List?> screenshot() => Tools.runBytes(_exe, ['-s', target, 'exec-out', 'screencap', '-p']);

  Future<Process> logcat() => Process.start(_exe, ['-s', target, 'logcat', '-v', 'threadtime', '-T', '1000']);

  Future<void> clearLogcat() => run(['logcat', '-c']);

  Future<ProcessOutput> install(String apk) => run(['install', '-r', '-d', apk], timeout: const Duration(minutes: 5));

  Future<ProcessOutput> push(String local, String remote) =>
      run(['push', local, remote], timeout: const Duration(minutes: 10));

  Future<ProcessOutput> pull(String remote, String local) =>
      run(['pull', remote, local], timeout: const Duration(minutes: 10));

  /// Wakes the screen, vibrates and blinks the brightness for a few seconds so the device stands out on a desk.
  Future<void> find(String message) {
    final m = message.replaceAll(RegExp(r'''['"\\$`]'''), '');
    const blink =
        r'b=$(settings get system screen_brightness); a=$(settings get system screen_brightness_mode); '
        r'settings put system screen_brightness_mode 0; i=0; while [ $i -lt 8 ]; do '
        r'settings put system screen_brightness 255; cmd vibrator_manager synced oneshot 250 || cmd vibrator vibrate 250; '
        r'sleep 0.4; settings put system screen_brightness 1; sleep 0.4; i=$((i+1)); done; '
        r'settings put system screen_brightness $b; settings put system screen_brightness_mode $a';
    return shell(
      "input keyevent KEYCODE_WAKEUP; cmd notification post -S bigtext -t 'Here I am' slipway_find '$m' > /dev/null 2>&1; "
      "nohup sh -c '$blink' > /dev/null 2>&1 &",
    );
  }

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
    final out = await sh(
      'for p in \$(${ourPackagesShell()}); do echo "\$p \$(pidof \$p)"; done',
    );
    return {
      for (final line in out.split('\n'))
        for (final pid in line.trim().split(' ').skip(1))
          if (int.tryParse(pid) != null) int.parse(pid): line.trim().split(' ').first,
    };
  }

  /// package → versionName for all of our installed apps.
  Future<Map<String, String>> ourApps() async {
    final out = await sh(
      'for p in \$(${ourPackagesShell()}); do '
      'echo "\$p \$(dumpsys package \$p | grep -m1 versionName | cut -d= -f2)"; done',
    );
    return {
      for (final line in out.split('\n'))
        if (line.trim().isNotEmpty) line.trim().split(' ').first: line.trim().split(' ').skip(1).join(' '),
    };
  }

  Future<List<String>> packages({bool thirdParty = true}) async {
    final out = await sh('pm list packages --user 0 ${thirdParty ? '-3' : ''}');
    return out.split('\n').map((l) => l.trim().replaceFirst('package:', '')).where((p) => p.isNotEmpty).toList()
      ..sort();
  }

  Future<void> launch(String package) => shell('monkey -p $package -c android.intent.category.LAUNCHER 1');

  Future<void> forceStop(String package) => shell('am force-stop $package');

  Future<ProcessOutput> clearData(String package) => shell('pm clear $package');

  Future<ProcessOutput> uninstall(String package) => run(['uninstall', package]);

  Future<void> reboot() => run(['reboot']);
}
