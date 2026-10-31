import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ProcessOutput {
  const ProcessOutput(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

class Tools {
  Tools._(this.adb, this.scrcpy);

  final String? adb;
  final String? scrcpy;

  /// Folder containing the bundled scrcpy (see windows/CMakeLists.txt).
  static String get bundledDir => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}scrcpy';

  static String? _bundled(String exe) {
    final f = File('$bundledDir${Platform.pathSeparator}$exe');
    return f.existsSync() ? f.path : null;
  }

  // Prefer a system adb so we don't fight an already-running adb server of another version.
  static Future<Tools> resolve() async =>
      Tools._(await _which('adb') ?? _bundled('adb.exe'), _bundled('scrcpy.exe') ?? await _which('scrcpy'));

  static Future<String?> _which(String name) async {
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
      if (r.exitCode != 0) return null;
      final first = LineSplitter.split(r.stdout as String).firstOrNull?.trim();
      return (first == null || first.isEmpty) ? null : first;
    } catch (_) {
      return null;
    }
  }

  static Future<ProcessOutput> run(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 8),
    Map<String, String>? environment,
  }) async {
    final p = await Process.start(exe, args, environment: environment);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode.timeout(
      timeout,
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    return ProcessOutput(code, await out, await err);
  }

  static Future<Uint8List?> runBytes(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final p = await Process.start(exe, args);
    p.stderr.drain<void>();
    final builder = BytesBuilder(copy: false);
    final done = p.stdout.forEach(builder.add);
    final code = await p.exitCode.timeout(
      timeout,
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    await done;
    return code == 0 ? builder.takeBytes() : null;
  }
}
