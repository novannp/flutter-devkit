import 'package:flutter/material.dart';

class AppModule {
  const AppModule(this.label, this.icon, this.page);

  final String label;
  final IconData icon;
  final Widget page;
}

/// Tools opened next to the code. The Editor stays the main window: a tool is a tab in its work area.
class ToolTabs extends ChangeNotifier {
  ToolTabs._();

  static final instance = ToolTabs._();

  final open = <AppModule>[];

  /// Null while the code is showing.
  AppModule? active;

  void show(AppModule module) {
    if (!open.contains(module)) open.add(module);
    active = module;
    notifyListeners();
  }

  void showEditor() {
    if (active == null) return;
    active = null;
    notifyListeners();
  }

  /// Closing a tab disposes its page, so whatever the tool was running stops with it.
  void close(AppModule module) {
    final at = open.indexOf(module);
    if (at < 0) return;
    open.removeAt(at);
    if (active == module) active = open.isEmpty ? null : open[at.clamp(0, open.length - 1)];
    notifyListeners();
  }
}
