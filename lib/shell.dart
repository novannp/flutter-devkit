import 'dart:io';

import 'package:flutter/material.dart';

import 'core/background.dart';
import 'core/theme.dart';
import 'modules/console/console_page.dart';
import 'modules/devices/view/devices_page.dart';
import 'modules/devices/view/multi_screen_page.dart';
import 'modules/emulators/emulators_page.dart';
import 'modules/help/connection_guide.dart';
import 'modules/maintenance/maintenance_page.dart';
import 'modules/printer/printer_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/stores/view/stores_page.dart';
import 'modules/terminal/terminal_page.dart';

class _Module {
  const _Module(this.label, this.icon, this.page, {this.phase});

  final String label;
  final IconData icon;
  final Widget? page;
  final int? phase;
}

class _Group {
  const _Group(this.title, this.modules);

  final String title;
  final List<_Module> modules;
}

const _groups = [
  _Group('Device', [
    _Module('Devices', Icons.devices_other, DevicesPage()),
    _Module('Multi Screen', Icons.grid_view_rounded, MultiScreenPage()),
    _Module('Emulators', Icons.phone_android_outlined, EmulatorsPage()),
  ]),
  _Group('Tools', [
    _Module('Terminal', Icons.terminal, ConsolePage()),
    _Module('Printer', Icons.receipt_long_outlined, PrinterPage()),
    _Module('Store Codes', Icons.storefront_outlined, StoresPage()),
    _Module('Maintenance', Icons.cleaning_services_outlined, MaintenancePage()),
    _Module('PAX Terminals', Icons.point_of_sale, TerminalPage()),
    _Module('Firebase', Icons.local_fire_department_outlined, null, phase: 4),
    _Module('Release', Icons.rocket_launch_outlined, null, phase: 4),
  ]),
  _Group('Other', [_Module('Settings', Icons.settings_outlined, SettingsPage())]),
];

final _modules = [for (final g in _groups) ...g.modules];

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  var _index = 0;
  final _visited = {0};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(selected: _index, onSelect: (i) => setState(() => _visited.add(_index = i))),
          Expanded(
            // IndexedStack keeps page state (scans, logs, printer) alive when switching menus.
            child: IndexedStack(
              index: _index,
              children: [
                // Disabled TickerMode tells hidden pages to hide native windows (embedded scrcpy) too.
                // Built on first visit so e.g. Multi Screen doesn't start scrcpy at launch.
                for (final (i, m) in _modules.indexed)
                  TickerMode(
                    enabled: i == _index,
                    child: _visited.contains(i) ? (m.page ?? _ComingSoon(module: m)) : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    var i = 0;

    return Container(
      width: 208,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [scheme.primary, brandColor.withValues(alpha: .7)]),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.bolt_rounded, color: scheme.onPrimary, size: 20),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ravo DevKit', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text('Testing toolkit', style: text.labelSmall?.copyWith(color: scheme.outline)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final g in _groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                    child: Text(
                      g.title.toUpperCase(),
                      style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .8),
                    ),
                  ),
                  for (final m in g.modules) _NavItem(module: m, index: i++, selected: selected, onSelect: onSelect),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => showConnectionGuide(context),
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('Guide'),
                    style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                  ),
                ),
                IconButton(
                  tooltip: 'Take a break 🎮',
                  onPressed: () => _takeABreak(context),
                  icon: const Icon(Icons.sports_esports_outlined, size: 20),
                ),
                IconButton(
                  tooltip: 'Quit DevKit',
                  onPressed: BackgroundRunner.instance.quit,
                  icon: const Icon(Icons.power_settings_new, size: 20),
                ),
                ValueListenableBuilder(
                  valueListenable: themeMode,
                  builder: (_, mode, _) {
                    final dark = mode == ThemeMode.dark;
                    return IconButton(
                      tooltip: dark ? 'Light mode' : 'Dark mode',
                      onPressed: () => setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
                      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Easter egg: opens Steam for a well-earned break.
Future<void> _takeABreak(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final reg = await Process.run('reg', ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamExe']);
  final installed = reg.exitCode == 0;
  if (installed) await Process.run('explorer', ['steam://open/main']);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        width: 420,
        content: Text(
          installed
              ? 'Break time 🎮 — the devices will still be here when you get back.'
              : "Steam isn't installed… maybe get a coffee instead ☕",
        ),
      ),
    );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.module, required this.index, required this.selected, required this.onSelect});

  final _Module module;
  final int index;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = index == selected;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? scheme.primary.withValues(alpha: .10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSelect(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(module.icon, size: 19, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    module.label,
                    style: TextStyle(color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w500),
                  ),
                ),
                if (module.page == null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('Soon', style: TextStyle(fontSize: 10, color: scheme.outline)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.module});

  final _Module module;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(module.icon, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(module.label, style: text.titleLarge),
          Text('Coming soon · Phase ${module.phase}', style: text.bodyMedium),
        ],
      ),
    );
  }
}
