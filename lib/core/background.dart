import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'child_processes.dart';

/// Saves what's open and ends every child process, whichever way the app is asked to close.
class BackgroundRunner with WindowListener {
  BackgroundRunner._();

  static final instance = BackgroundRunner._();

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: Platform.isMacOS);
    await windowManager.setMinimumSize(const Size(560, 400));
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
  }

  /// A device's window has its own process. Closing it ends that, or its scrcpy would stay behind:
  /// on Windows children die with the process, and only with the process.
  Future<void> initDeviceWindow() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(_DeviceWindowCloser());
  }

  /// Last words before exit, such as saving open files.
  Future<void> Function()? onQuit;

  Future<void> quit() async {
    await onQuit?.call();
    ChildProcesses.killBound();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onWindowClose() => quit();
}

class _DeviceWindowCloser with WindowListener {
  @override
  void onWindowClose() {
    ChildProcesses.killBound();
    exit(0);
  }
}
