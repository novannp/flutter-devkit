import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/apps.dart';
import '../../core/background.dart';
import '../../core/compact_dropdown.dart';
import '../../core/local_builds.dart';
import '../../core/theme.dart';
import '../../core/tools.dart';
import '../../extensions/emulators/avd_service.dart';
import '../devices/cubit/devices_cubit.dart';
import '../devices/services/adb_service.dart';
import '../devices/services/mdns_service.dart';
import '../devices/services/network_scanner.dart';
import '../editor/editor_page.dart' show EditorCommands;
import '../editor/editor_view.dart';
import '../../core/platform_keys.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _Setting {
  const _Setting(this.title, this.description, {this.trailing, this.below});

  final String title, description;
  final Widget? trailing, below;
}

class _Section {
  const _Section(this.label, this.icon, this.settings);

  final String label;
  final IconData icon;
  final List<_Setting> settings;
}

class _SettingsPageState extends State<SettingsPage> {
  static const _navBelow = 640.0;

  List<String> _folders = const [];
  List<FlutterProject> _projects = const [];
  List<String> _subnets = const [];
  final _mdnsType = TextEditingController();
  final _search = TextEditingController();
  var _selected = 0;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  Future<void> _load() async {
    final folders = await ProjectFolders.get();
    final projects = await scanFlutterProjects();
    await loadApps();
    final subnets = await NetworkScanner.extraSubnets();
    _mdnsType.text = await MdnsService.serviceType();
    if (mounted) {
      setState(() {
        _folders = folders;
        _projects = projects;
        _subnets = subnets;
      });
    }
  }

  @override
  void dispose() {
    _mdnsType.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _saveMdnsType(String value) async {
    final type = value.trim();
    final messenger = ScaffoldMessenger.of(context);
    final valid = MdnsService.isValidType(type);
    if (valid) await (await SharedPreferences.getInstance()).setString(MdnsService.serviceTypeKey, type);
    messenger.showSnackBar(
      SnackBar(width: 420, content: Text(valid ? 'Saved. Restart Flutter DevKit to apply.' : 'Use a form like _myapp._tcp')),
    );
  }

  Future<void> _add() async {
    final path = await getDirectoryPath(confirmButtonText: 'Select folder');
    if (path == null) return;
    await ProjectFolders.add(path);
    _load();
  }

  List<_Section> _sections(BuildContext context) {
    final tools = context.read<AdbService>().tools;
    return [
      _Section('General', Icons.tune, [
        _Setting(
          'Theme',
          'The colors of the whole app.',
          trailing: ValueListenableBuilder(
            valueListenable: appTheme,
            builder: (_, current, _) => SizedBox(
              width: 180,
              child: CompactDropdown<AppTheme>(
                key: ValueKey(current.id),
                value: current,
                isExpanded: true,
                items: [for (final t in appThemes) DropdownMenuItem(value: t, child: Text(t.name))],
                onChanged: (t) {
                  if (t != null) setAppTheme(t);
                },
              ),
            ),
          ),
        ),
        _Setting(
          'Keep running when closed',
          'The close button hides the window, so the printer and scans keep going. Quit from the File menu or the tray.',
          trailing: ValueListenableBuilder(
            valueListenable: keepRunningOnClose,
            builder: (_, on, _) => Switch(value: on, onChanged: BackgroundRunner.instance.setKeepRunning),
          ),
        ),
      ]),
      _Section('Editor', Icons.code, [
        _Setting(
          'Font size',
          platformKeys('Also Ctrl+plus or Ctrl+minus in the editor.'),
          trailing: ValueListenableBuilder(
            valueListenable: EditorView.fontSize,
            builder: (_, size, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(tooltip: 'Smaller', visualDensity: VisualDensity.compact, onPressed: () => EditorView.zoom(-1), icon: const Icon(Icons.remove, size: 18)),
                SizedBox(width: 28, child: Text('${size.round()}', textAlign: TextAlign.center)),
                IconButton(tooltip: 'Larger', visualDensity: VisualDensity.compact, onPressed: () => EditorView.zoom(1), icon: const Icon(Icons.add, size: 18)),
              ],
            ),
          ),
        ),
        _Setting(
          'Word wrap',
          platformKeys('Long lines continue on the next row. Also Alt+Z.'),
          trailing: ValueListenableBuilder(
            valueListenable: EditorView.wordWrap,
            builder: (_, on, _) => Switch(value: on, onChanged: (_) => EditorView.toggleWordWrap()),
          ),
        ),
        _Setting(
          'Dart settings',
          'Line length, format on save and more, for the open project.',
          trailing: OutlinedButton(onPressed: () => EditorCommands.openDartSettings?.call(), child: const Text('Open')),
        ),
      ]),
      _Section('Projects', Icons.folder_outlined, [
        _Setting(
          'Project folders',
          'Folders holding your repos, or a repo itself. Their projects show on the start page and in Run and Install latest build.',
          trailing: OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 16), label: const Text('Add folder')),
          below: _folderList(),
        ),
        _Setting(
          'My apps',
          "Apps in your project folders count automatically. Add a package prefix for apps you test but haven't cloned. Listed devices update after a restart.",
          below: _ListSetting(
            values: appPrefixes,
            hint: 'com.example.',
            error: 'Letters, digits, _ and . only',
            isValid: isValidPackageId,
            onChanged: (v) async {
              await saveAppPrefixes(v);
              setState(() {});
            },
          ),
        ),
      ]),
      _Section('Devices', Icons.devices_outlined, [
        _Setting(
          'Auto-switch to port 5555',
          'Devices on USB or a random Wireless debugging port move to ip:5555, so they reconnect over Wi-Fi without pairing until they reboot.',
          trailing: ValueListenableBuilder(
            valueListenable: DevicesCubit.autoPort5555,
            builder: (_, on, _) => Switch(
              value: on,
              onChanged: (v) async {
                DevicesCubit.autoPort5555.value = v;
                await (await SharedPreferences.getInstance()).setBool('auto_port_5555', v);
              },
            ),
          ),
        ),
        _Setting(
          'Network scan subnets',
          "Other subnets to scan besides this PC's own and those of devices seen before. This PC needs a route to them, and only devices on port 5555 are found there.",
          below: _ListSetting(
            values: _subnets,
            hint: '192.168.5 or 10.1.0.0/22',
            error: 'Use 192.168.5, 192.168.5.0/24 or 10.1.0.0/22 (up to /20)',
            isValid: (v) => subnetHosts(v) != null,
            onChanged: (v) async {
              setState(() => _subnets = v);
              await NetworkScanner.setExtraSubnets(v);
            },
          ),
        ),
        _Setting(
          'App discovery service',
          'The mDNS type of apps that announce themselves on the network. Press Enter to save.',
          trailing: SizedBox(
            width: 180,
            child: TextField(
              controller: _mdnsType,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(isDense: true, hintText: '_myapp._tcp'),
              onSubmitted: _saveMdnsType,
            ),
          ),
        ),
      ]),
      _Section('Tools', Icons.build_outlined, [
        _tool('adb', tools.adb, 'It comes with the app, so reinstalling brings it back.'),
        _tool('scrcpy', tools.scrcpy, 'It comes with the app, so reinstalling brings it back.'),
        _androidSdk(tools),
      ]),
    ];
  }

  _Setting _tool(String name, String? path, String hint) => _Setting(
    name,
    path ?? 'Not found. $hint',
    trailing: Tooltip(
      message: path == null ? 'Not found' : 'Found',
      child: Icon(path == null ? Icons.error_outline : Icons.check_circle, size: 18, color: path == null ? Colors.red : Colors.green),
    ),
  );

  _Setting _androidSdk(Tools tools) {
    final found = AvdService(tools).sdkRoot;
    final custom = AvdService.customSdk.value;
    return _Setting(
      'Android SDK',
      found ?? (custom == null ? 'Not found. Emulators need it; choose its folder if it isn\'t in the usual place.' : "$custom has no emulator in it. Choose the SDK's folder."),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (custom != null)
            TextButton(
              onPressed: () async {
                await AvdService.setCustomSdk(null);
                setState(() {});
              },
              child: const Text('Use detected'),
            ),
          OutlinedButton(
            onPressed: () async {
              final path = await getDirectoryPath(confirmButtonText: 'Use this SDK');
              if (path == null) return;
              await AvdService.setCustomSdk(path);
              setState(() {});
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  Widget _folderList() {
    final scheme = Theme.of(context).colorScheme;
    final guess = ProjectFolders.guess();
    if (_folders.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Text(guess == null ? 'No folders yet.' : 'No folders yet. Suggested: $guess', style: TextStyle(fontSize: 13, color: scheme.outline)),
          ),
          if (guess != null)
            TextButton(
              onPressed: () async {
                await ProjectFolders.add(guess);
                _load();
              },
              child: const Text('Use it'),
            ),
        ],
      );
    }
    return Column(
      children: [
        for (final f in _folders)
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 16, color: scheme.outline),
              const SizedBox(width: 8),
              Expanded(child: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
              Text('${_projects.where((p) => p.path.startsWith(f)).length} projects', style: TextStyle(fontSize: 12, color: scheme.outline)),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await ProjectFolders.remove(f);
                  _load();
                },
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
      ],
    );
  }

  Widget _navItem(ColorScheme scheme, _Section s, int index) {
    final on = index == _selected;
    return Material(
      color: on ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          _search.clear();
          setState(() => _selected = index);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(s.icon, size: 16, color: on ? scheme.primary : scheme.outline),
              const SizedBox(width: 8),
              Text(s.label, style: TextStyle(fontSize: 13, color: on ? scheme.primary : null, fontWeight: on ? FontWeight.w600 : null)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sections = _sections(context);
    final words = _search.text.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    final searching = words.isNotEmpty;
    final shown = searching
        ? [
            for (final s in sections)
              (s.label, s.settings.where((x) {
                final hay = '${s.label} ${x.title} ${x.description}'.toLowerCase();
                return words.every(hay.contains);
              }).toList()),
          ].where((e) => e.$2.isNotEmpty).toList()
        : [(sections[_selected].label, sections[_selected].settings)];

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        if (shown.isEmpty) Padding(padding: const EdgeInsets.only(top: 24), child: Center(child: Text('No settings match', style: TextStyle(color: scheme.outline)))),
        for (final (label, settings) in shown) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          for (final s in settings) _SettingRow(s),
          const SizedBox(height: 12),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (_, box) {
        final narrow = box.maxWidth < _navBelow;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search settings',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                  suffixIcon: searching ? IconButton(tooltip: 'Clear', onPressed: _search.clear, icon: const Icon(Icons.close, size: 15)) : null,
                ),
              ),
            ),
            if (narrow)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [for (var i = 0; i < sections.length; i++) _navItem(scheme, sections[i], i)]),
              ),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(
              child: narrow
                  ? content
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 170,
                          child: ListView(
                            padding: const EdgeInsets.all(8),
                            children: [for (var i = 0; i < sections.length; i++) _navItem(scheme, sections[i], i)],
                          ),
                        ),
                        VerticalDivider(width: 1, color: scheme.outlineVariant),
                        Expanded(child: content),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(this.setting);

  final _Setting setting;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(setting.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(setting.description, style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
              ),
              if (setting.trailing != null) ...[const SizedBox(width: 16), setting.trailing!],
            ],
          ),
          if (setting.below != null) ...[const SizedBox(height: 8), setting.below!],
        ],
      ),
    );
  }
}

/// Removable chips plus a field that adds to them.
class _ListSetting extends StatefulWidget {
  const _ListSetting({
    required this.values,
    required this.hint,
    required this.error,
    required this.isValid,
    required this.onChanged,
  });

  final List<String> values;
  final String hint;
  final String error;
  final bool Function(String) isValid;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_ListSetting> createState() => _ListSettingState();
}

class _ListSettingState extends State<_ListSetting> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit(String input) {
    final v = input.trim();
    if (v.isEmpty) return;
    if (!widget.isValid(v)) return setState(() => _error = widget.error);
    setState(() => _error = null);
    _ctrl.clear();
    if (!widget.values.contains(v)) widget.onChanged([...widget.values, v]);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.values.isNotEmpty) ...[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final v in widget.values)
              InputChip(
                label: Text(v),
                onDeleted: () => widget.onChanged(widget.values.where((x) => x != v).toList()),
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
      TextField(
        controller: _ctrl,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          errorText: _error,
          suffixIcon: IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add, size: 16),
            onPressed: () => _submit(_ctrl.text),
          ),
        ),
        onSubmitted: _submit,
      ),
    ],
  );
}
