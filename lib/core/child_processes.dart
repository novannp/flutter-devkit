import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'tools.dart';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createJobObject = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)
    >('CreateJobObjectW');
final _setInformationJobObject = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('SetInformationJobObject');
final _assignProcessToJobObject = _kernel32
    .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
      'AssignProcessToJobObject',
    );
final _openProcess = _kernel32
    .lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');
final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

const _jobObjectExtendedLimitInformation = 9;
const _extendedLimitSize =
    144; // sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) on x64
const _limitFlagsOffset = 16;
const _killOnJobClose = 0x2000;
const _processSetQuota = 0x0100;
const _processTerminate = 0x0001;

/// (scrcpy pid, pid of the Slipway that started it) from `ps -axo pid=,command=`.
Iterable<(int, int)> embeddedScrcpyIn(String ps) sync* {
  final line = RegExp(
    r'^\s*(\d+)\s+.*scrcpy\b.*slipway-embed-(\d+)-',
    multiLine: true,
  );
  for (final m in line.allMatches(ps)) {
    yield (int.parse(m[1]!), int.parse(m[2]!));
  }
}

/// Child processes that must die with Slipway (embedded scrcpy windows would otherwise float orphaned).
class ChildProcesses {
  static int? _job;

  // macOS has no job objects, so children are ended by hand on the way out.
  static final _bound = <int>{};

  static int? _jobHandle() {
    if (!Platform.isWindows) return null;
    if (_job != null) return _job;
    final job = _createJobObject(nullptr, nullptr);
    if (job == 0) return null;
    final info = calloc<Uint8>(_extendedLimitSize);
    try {
      (info + _limitFlagsOffset).cast<Uint32>().value = _killOnJobClose;
      if (_setInformationJobObject(
            job,
            _jobObjectExtendedLimitInformation,
            info.cast(),
            _extendedLimitSize,
          ) ==
          0) {
        return null;
      }
    } finally {
      calloc.free(info);
    }
    // Never closed on purpose: the OS closes it when Slipway exits, which kills every assigned child.
    return _job = job;
  }

  static void bind(Process p) => bindPid(p.pid);

  static void killBound() {
    for (final pid in _bound) {
      Process.killPid(pid);
    }
    _bound.clear();
  }

  /// A process and whatever it started.
  static Future<void> killTree(Process p) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/T', '/F', '/PID', '${p.pid}']);
    } else {
      await Process.run('pkill', ['-TERM', '-P', '${p.pid}']);
      p.kill();
    }
  }

  static void bindPid(int pid) {
    if (Platform.isMacOS) {
      _bound.add(pid);
      return;
    }
    final job = _jobHandle();
    if (job == null) return;
    final h = _openProcess(_processSetQuota | _processTerminate, 0, pid);
    if (h == 0) return;
    _assignProcessToJobObject(job, h);
    _closeHandle(h);
  }

  /// Kills embedded scrcpy left by Slipway runs that are gone (title `slipway-embed-<pid>-n`).
  static Future<void> killOrphans() async {
    if (Platform.isMacOS) {
      final listed = await Tools.run('ps', ['-axo', 'pid=,command=']);
      for (final (pid, owner) in embeddedScrcpyIn(listed.stdout)) {
        final alive = await Tools.run('kill', ['-0', '$owner']);
        if (!alive.ok) Process.killPid(pid);
      }
      return;
    }
    if (!Platform.isWindows) return;
    await Tools.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"Get-CimInstance Win32_Process -Filter 'Name=''scrcpy.exe''' | Where-Object { $_.CommandLine -match 'slipway-embed-(\d+)-' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
    ], timeout: const Duration(seconds: 20));
  }
}
