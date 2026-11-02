import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const _prefKeepRunning = 'keep_running_on_close';

/// Main window only: X minimizes instead of quitting so the printer server, scans etc. keep running.
final keepRunningOnClose = ValueNotifier(true);

class BackgroundRunner with WindowListener, TrayListener {
  BackgroundRunner._();

  static final instance = BackgroundRunner._();

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    await windowManager.setMinimumSize(const Size(560, 400));
    keepRunningOnClose.value = (await SharedPreferences.getInstance()).getBool(_prefKeepRunning) ?? true;
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('DevKit');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open DevKit'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit'),
          ],
        ),
      );
      trayManager.addListener(this);
    } catch (_) {
      // Tray is a convenience; the taskbar still works without it.
    }
  }

  /// Last words before exit (e.g. tell chat peers we're leaving).
  Future<void> Function()? onQuit;

  Future<void> setKeepRunning(bool v) async {
    keepRunningOnClose.value = v;
    await (await SharedPreferences.getInstance()).setBool(_prefKeepRunning, v);
  }

  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    await onQuit?.call();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onWindowClose() {
    if (keepRunningOnClose.value) {
      windowManager.minimize();
    } else {
      quit();
    }
  }

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) => switch (menuItem.key) {
    'open' => show(),
    'quit' => quit(),
    _ => null,
  };
}
