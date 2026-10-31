import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'tools.dart';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createJobObject = _kernel32
    .lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Utf16>), int Function(Pointer<Void>, Pointer<Utf16>)>(
      'CreateJobObjectW',
    );
final _setInformationJobObject = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32), int Function(int, int, Pointer<Void>, int)>(
      'SetInformationJobObject',
    );
final _assignProcessToJobObject = _kernel32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
  'AssignProcessToJobObject',
);
final _openProcess = _kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>(
  'OpenProcess',
);
final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

const _jobObjectExtendedLimitInformation = 9;
const _extendedLimitSize = 144; // sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) on x64
const _limitFlagsOffset = 16;
const _killOnJobClose = 0x2000;
const _processSetQuota = 0x0100;
const _processTerminate = 0x0001;

/// Child processes that must die with DevKit (embedded scrcpy windows would otherwise float orphaned).
class ChildProcesses {
  static int? _job;

  static int? _jobHandle() {
    if (!Platform.isWindows) return null;
    if (_job != null) return _job;
    final job = _createJobObject(nullptr, nullptr);
    if (job == 0) return null;
    final info = calloc<Uint8>(_extendedLimitSize);
    try {
      (info + _limitFlagsOffset).cast<Uint32>().value = _killOnJobClose;
      if (_setInformationJobObject(job, _jobObjectExtendedLimitInformation, info.cast(), _extendedLimitSize) == 0) {
        return null;
      }
    } finally {
      calloc.free(info);
    }
    // Never closed on purpose: the OS closes it when DevKit exits, which kills every assigned child.
    return _job = job;
  }

  static void bind(Process p) {
    final job = _jobHandle();
    if (job == null) return;
    final h = _openProcess(_processSetQuota | _processTerminate, 0, p.pid);
    if (h == 0) return;
    _assignProcessToJobObject(job, h);
    _closeHandle(h);
  }

  /// Kills embedded scrcpy left by DevKit runs that are gone (title `devkit-embed-<pid>-n`).
  static Future<void> killOrphans() async {
    if (!Platform.isWindows) return;
    await Tools.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"Get-CimInstance Win32_Process -Filter 'Name=''scrcpy.exe''' | Where-Object { $_.CommandLine -match 'devkit-embed-(\d+)-' -and -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
    ], timeout: const Duration(seconds: 20));
  }
}
