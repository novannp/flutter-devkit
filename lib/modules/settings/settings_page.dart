import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../devices/cubit/devices_cubit.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/apps.dart';
import '../../core/background.dart';
import '../../core/local_builds.dart';
import '../devices/services/adb_service.dart';
import '../devices/services/mdns_service.dart';
import '../devices/services/network_scanner.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<String> _folders = const [];
  List<FlutterProject> _projects = const [];
  List<String> _subnets = const [];
  final _mdnsType = TextEditingController();

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  Future<void> _saveMdnsType(String value) async {
    final type = value.trim();
    final messenger = ScaffoldMessenger.of(context);
    final valid = MdnsService.isValidType(type);
    if (valid) await (await SharedPreferences.getInstance()).setString(MdnsService.serviceTypeKey, type);
    messenger.showSnackBar(
      SnackBar(width: 420, content: Text(valid ? 'Saved. Restart DevKit to apply.' : 'Use a form like _myapp._tcp')),
    );
  }

  Future<void> _add() async {
    final path = await getDirectoryPath(confirmButtonText: 'Select folder');
    if (path == null) return;
    await ProjectFolders.add(path);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tools = context.read<AdbService>().tools;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        Text('Settings', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Saved on this machine only, so each developer can differ.', style: TextStyle(color: scheme.outline)),
        const SizedBox(height: 16),
        ValueListenableBuilder(
          valueListenable: keepRunningOnClose,
          builder: (_, on, _) => Card(
            child: SwitchListTile(
              value: on,
              onChanged: BackgroundRunner.instance.setKeepRunning,
              title: const Text('Keep running when closed'),
              subtitle: const Text(
                'The close button minimizes DevKit so the printer emulator and scans keep running. '
                'Reopen it from the taskbar or tray icon; quit from the tray or the power button in the sidebar.',
              ),
            ),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: DevicesCubit.autoPort5555,
          builder: (_, on, _) => Card(
            child: SwitchListTile(
              value: on,
              onChanged: (v) async {
                DevicesCubit.autoPort5555.value = v;
                await (await SharedPreferences.getInstance()).setBool('auto_port_5555', v);
              },
              title: const Text('Auto-switch devices to port 5555'),
              subtitle: const Text(
                'Devices connected by USB or a random Wireless-debugging port move to ip:5555 by themselves, '
                'so they reconnect over Wi-Fi without pairing (until they reboot).',
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Project folders', style: text.titleMedium),
            const Spacer(),
            FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Pick a folder that contains your repos (e.g. D:\\Work) or a repo folder itself. '
          'Used for Flutter run/attach and Install latest build.',
          style: TextStyle(color: scheme.outline, fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (_folders.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline, color: Colors.orange),
              title: const Text('No project folders yet'),
              subtitle: Text(
                ProjectFolders.guess() == null
                    ? 'Add the folder where you clone repos.'
                    : 'Suggested: ${ProjectFolders.guess()}',
              ),
              trailing: ProjectFolders.guess() == null
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await ProjectFolders.add(ProjectFolders.guess()!);
                        _load();
                      },
                      child: const Text('Use suggestion'),
                    ),
            ),
          ),
        for (final f in _folders)
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f),
              subtitle: Text('${_projects.where((p) => p.path.startsWith(f)).length} Flutter projects'),
              trailing: IconButton(
                tooltip: 'Remove',
                onPressed: () async {
                  await ProjectFolders.remove(f);
                  _load();
                },
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        if (_projects.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in _projects)
                Chip(
                  avatar: Icon(p.usesFvm ? Icons.layers_outlined : Icons.flutter_dash, size: 16),
                  label: Text(p.name),
                ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        Text('Network scan', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          "Scan network covers this PC's subnets and those of devices seen before. Add the others here "
          '(192.168.5, 10.1.0.0/22, up to /20). This PC must have a route to them, and across subnets only '
          'devices on port 5555 are found: Wireless debugging discovery stays within one subnet.',
          style: TextStyle(color: scheme.outline, fontSize: 13),
        ),
        const SizedBox(height: 8),
        _ListSetting(
          values: _subnets,
          hint: 'Add subnet, e.g. 192.168.5',
          error: 'Use 192.168.5, 192.168.5.0/24 or 10.1.0.0/22 (up to /20)',
          isValid: (v) => subnetHosts(v) != null,
          onChanged: (v) async {
            setState(() => _subnets = v);
            await NetworkScanner.setExtraSubnets(v);
          },
        ),
        const SizedBox(height: 28),
        Text('My apps', style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Apps from your project folders count automatically. Add a package prefix for apps you test but '
          "don't have cloned. Devices already listed update after a restart.",
          style: TextStyle(color: scheme.outline, fontSize: 13),
        ),
        const SizedBox(height: 8),
        _ListSetting(
          values: appPrefixes,
          hint: 'Add package prefix, e.g. com.example.',
          error: 'Letters, digits, _ and . only',
          isValid: isValidPackageId,
          onChanged: (v) async {
            await saveAppPrefixes(v);
            setState(() {});
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _mdnsType,
          decoration: const InputDecoration(
            labelText: 'App discovery mDNS service type',
            helperText: 'For apps that announce themselves on the LAN. Press Enter to save.',
          ),
          onSubmitted: _saveMdnsType,
        ),
        const SizedBox(height: 28),
        Text('Tools', style: text.titleMedium),
        const SizedBox(height: 8),
        _ToolRow(name: 'adb', path: tools.adb, hint: 'Install Android SDK Platform-Tools and add it to PATH'),
        _ToolRow(name: 'scrcpy', path: tools.scrcpy, hint: 'Bundled with the app — rebuild if missing'),
      ],
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
        decoration: InputDecoration(
          hintText: widget.hint,
          errorText: _error,
          suffixIcon: IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add),
            onPressed: () => _submit(_ctrl.text),
          ),
        ),
        onSubmitted: _submit,
      ),
    ],
  );
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.name, required this.path, required this.hint});

  final String name;
  final String? path;
  final String hint;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        path != null ? Icons.check_circle : Icons.error_outline,
        color: path != null ? Colors.green : Colors.red,
      ),
      title: Text(name),
      subtitle: Text(path ?? 'Not found. $hint'),
    ),
  );
}
