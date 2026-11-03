import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../modules/devices/view/devices_page.dart';
import '../modules/devices/view/multi_screen_page.dart';
import '../modules/editor/tool_tabs.dart';
import 'emulators/emulators_page.dart';
import 'history/history_page.dart';
import 'maintenance/maintenance_page.dart';
import 'notes/notes_page.dart';
import 'printer/printer_page.dart';
import 'work/work_page.dart';

export '../modules/editor/tool_tabs.dart' show AppModule;

const _prefDisabled = 'extensions_disabled';

class BuiltinExtension {
  const BuiltinExtension({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.menu,
    required this.modules,
    this.onEnable,
    this.onDisable,
  });

  final String id, name, description, menu;
  final IconData icon;
  final List<AppModule> modules;

  /// Starts or stops what runs in the background, such as a network listener.
  final Future<void> Function()? onEnable, onDisable;
}

final builtinExtensions = <BuiltinExtension>[
  const BuiltinExtension(
    id: 'devices',
    name: 'Device Manager',
    description: 'Find, connect and mirror Android devices on USB and your network. Run in the Editor keeps working without it.',
    icon: Icons.devices_other,
    menu: 'Device',
    modules: [
      AppModule('Devices', Icons.devices_other, DevicesPage()),
      AppModule('Multi Screen', Icons.grid_view_rounded, MultiScreenPage()),
    ],
  ),
  const BuiltinExtension(
    id: 'emulators',
    name: 'Emulators',
    description: 'Start and manage Android emulators.',
    icon: Icons.phone_android_outlined,
    menu: 'Device',
    modules: [AppModule('Emulators', Icons.phone_android_outlined, EmulatorsPage())],
  ),
  BuiltinExtension(
    id: 'printer',
    name: 'Printer',
    description: 'A virtual network receipt printer for testing print jobs.',
    icon: Icons.receipt_long_outlined,
    menu: 'Tools',
    modules: const [AppModule('Printer', Icons.receipt_long_outlined, PrinterPage())],
    onEnable: printerServer.init,
    onDisable: printerServer.stop,
  ),
  const BuiltinExtension(
    id: 'notes',
    name: 'Notes',
    description: 'Quick notes that stay on this PC.',
    icon: Icons.sticky_note_2_outlined,
    menu: 'Tools',
    modules: [AppModule('Notes', Icons.sticky_note_2_outlined, NotesPage())],
  ),
  const BuiltinExtension(
    id: 'maintenance',
    name: 'Maintenance',
    description: 'Clean up the caches and emulator images that builds leave behind.',
    icon: Icons.cleaning_services_outlined,
    menu: 'Tools',
    modules: [AppModule('Maintenance', Icons.cleaning_services_outlined, MaintenancePage())],
  ),
  const BuiltinExtension(
    id: 'history',
    name: 'History',
    description: 'Browse past activity, crashes and session logs.',
    icon: Icons.history,
    menu: 'Tools',
    modules: [AppModule('History', Icons.history, HistoryPage())],
  ),
  const BuiltinExtension(
    id: 'work',
    name: 'Work',
    description: 'Jira tickets and Bitbucket pull requests next to your repos.',
    icon: Icons.task_alt,
    menu: 'Team',
    modules: [AppModule('Work', Icons.task_alt, WorkPage())],
  ),
];

/// Which built-in extensions are on. Everything is on until the user turns it off.
class ExtensionManager extends ChangeNotifier {
  ExtensionManager._();

  static final instance = ExtensionManager._();

  var _disabled = <String>{};

  bool isEnabled(String id) => !_disabled.contains(id);

  Future<void> load() async {
    _disabled = ((await SharedPreferences.getInstance()).getStringList(_prefDisabled) ?? const <String>[]).toSet();
    notifyListeners();
  }

  Future<void> setEnabled(BuiltinExtension extension, bool enabled) async {
    if (isEnabled(extension.id) == enabled) return;
    enabled ? _disabled.remove(extension.id) : _disabled.add(extension.id);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setStringList(_prefDisabled, _disabled.toList());
    await (enabled ? extension.onEnable : extension.onDisable)?.call();
  }
}

class ExtensionsPage extends StatelessWidget {
  const ExtensionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final manager = ExtensionManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (_, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Extensions', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Built into HotRestart. Turn off what you don\'t use: it leaves the menus and stops running.', style: TextStyle(color: scheme.outline)),
          const SizedBox(height: 16),
          for (final e in builtinExtensions)
            Card(
              child: SwitchListTile(
                secondary: Icon(e.icon, color: manager.isEnabled(e.id) ? scheme.primary : scheme.outline),
                title: Row(
                  children: [
                    Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(5)),
                      child: Text('Built-in', style: TextStyle(fontSize: 11, color: scheme.outline)),
                    ),
                  ],
                ),
                subtitle: Text(e.description),
                value: manager.isEnabled(e.id),
                onChanged: (v) => manager.setEnabled(e, v),
              ),
            ),
        ],
      ),
    );
  }
}
