import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/panels.dart';
import '../../core/settings.dart';
import '../editor/tool_tabs.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/apps.dart';
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
  var _scope = SettingScope.global;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    Settings.instance.addListener(_onSettings);
    _load();
  }

  void _onSettings() {
    if (mounted) setState(() {});
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
    Settings.instance.removeListener(_onSettings);
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
      SnackBar(content: Text(valid ? 'Saved. Restart Slipway to apply.' : 'Use a form like _myapp._tcp')),
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
      _Section('General', Icons.tune, _generated('app')),
      _Section('Editor', Icons.code, _generated('editor')),
      _Section('Dart', Icons.data_object, _generated('dart')),
      _Section('Flutter', Icons.bolt_outlined, _generated('flutter')),
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

  List<_Setting> _generated(String section) => [
    for (final def in settingDefs)
      if (def.section == section) _settingFor(def),
  ];

  _Setting _settingFor(SettingDef def) {
    final store = Settings.instance;
    // What can't be set per project always goes in your own file.
    final scope = def.projectable ? _scope : SettingScope.global;
    void put(Object? value) => unawaited(store.set(scope, def.key, value));
    final own = store.valueIn(scope, def.key) != null;
    final source = store.sourceOf(def.key);
    final note = !def.projectable && _scope == SettingScope.project
        ? ' Applies to all projects.'
        : (_scope == SettingScope.global && source == SettingScope.project ? ' This project overrides it.' : '');
    final reset = own
        ? TextButton(onPressed: () => put(null), child: Text(scope == SettingScope.project ? 'Use my setting' : 'Reset'))
        : null;
    Widget? control;
    Widget? below;
    switch (def.type) {
      case SettingType.boolean:
        control = Switch(value: store.flag(def.key), onChanged: put);
      case SettingType.choice:
        final choices = def.key == 'app.theme' ? {for (final t in appThemes) t.id: t.name} : def.choices;
        final current = choices.containsKey(store.text(def.key)) ? store.text(def.key) : (def.key == 'app.theme' ? appTheme.value.id : choices.keys.first);
        control = SizedBox(
          width: 180,
          child: CompactDropdown<String>(
            key: ValueKey('${def.key}/$current'),
            value: current,
            isExpanded: true,
            items: [for (final e in choices.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) {
              if (v != null) put(v);
            },
          ),
        );
      case SettingType.integer || SettingType.number:
        final value = store.value(def.key) as num?;
        control = _FieldSetting(
          key: ValueKey('${def.key}/$value'),
          width: 80,
          value: value == null ? '' : (def.type == SettingType.integer ? '${value.toInt()}' : '$value'),
          onSaved: (text) {
            final parsed = def.type == SettingType.integer ? int.tryParse(text) : double.tryParse(text);
            final min = def.min, max = def.max;
            if (parsed == null) return put(null);
            final limited = parsed.clamp(min ?? parsed, max ?? parsed);
            put(def.type == SettingType.integer ? limited.toInt() : limited.toDouble());
          },
        );
      case SettingType.text:
        control = _FieldSetting(key: ValueKey('${def.key}/${store.text(def.key)}'), width: 220, value: store.text(def.key), onSaved: (text) => put(text.trim().isEmpty ? null : text.trim()));
      case SettingType.list:
        below = _ListSetting(
          key: ValueKey('${def.key}/${store.list(def.key).join('|')}'),
          values: store.list(def.key),
          hint: 'Add…',
          error: "Quotes and characters like & | < > can't be used here",
          isValid: isSafeRunArg,
          onChanged: put,
        );
    }
    return _Setting(
      def.title,
      '${def.description}$note',
      trailing: (reset == null && control == null) ? null : Row(mainAxisSize: MainAxisSize.min, children: [?reset, ?control]),
      below: below,
    );
  }

  Widget _scopeBar(ColorScheme scheme) {
    final store = Settings.instance;
    final root = store.root;
    final inProject = _scope == SettingScope.project && root != null;
    final error = inProject ? store.projectError : store.globalError;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                height: 34,
                child: PillTab(selected: !inProject, onTap: () => setState(() => _scope = SettingScope.global), child: const Text('My settings', style: TextStyle(fontSize: 13))),
              ),
              if (root != null)
                Flexible(
                  child: SizedBox(
                    height: 34,
                    child: PillTab(
                      selected: inProject,
                      onTap: () => setState(() => _scope = SettingScope.project),
                      child: Text('This project: ${p.basename(root)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final path = await store.ensureFile(inProject ? SettingScope.project : SettingScope.global);
                  if (path == null) return;
                  ToolTabs.instance.showEditor();
                  await EditorCommands.openPath?.call(path);
                },
                icon: const Icon(Icons.data_object, size: 16),
                label: const Text('Open settings.json'),
              ),
            ],
          ),
          Text(
            inProject ? 'Saved in .slipway/settings.json, so it can be committed and shared with the team. It wins over your own settings.' : 'Saved on this computer, and used in every project.',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text("settings.json can't be read, so its last good values stay in use: $error", style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
        ],
      ),
    );
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
        _scopeBar(scheme),
        const SizedBox(height: 8),
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

/// Saves when Enter is pressed or focus moves on.
class _FieldSetting extends StatefulWidget {
  const _FieldSetting({super.key, required this.width, required this.value, required this.onSaved});

  final double width;
  final String value;
  final ValueChanged<String> onSaved;

  @override
  State<_FieldSetting> createState() => _FieldSettingState();
}

class _FieldSettingState extends State<_FieldSetting> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  void _save() {
    if (_controller.text != widget.value) widget.onSaved(_controller.text);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(isDense: true),
      onSubmitted: (_) => _save(),
    ),
  );
}

/// Removable chips plus a field that adds to them.
class _ListSetting extends StatefulWidget {
  const _ListSetting({
    super.key,
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
