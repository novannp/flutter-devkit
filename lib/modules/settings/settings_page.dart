import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/background.dart';
import '../../core/local_builds.dart';
import '../devices/services/adb_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<String> _folders = const [];
  List<FlutterProject> _projects = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final folders = await ProjectFolders.get();
    final projects = await scanFlutterProjects();
    if (mounted) {
      setState(() {
        _folders = folders;
        _projects = projects;
      });
    }
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
        const SizedBox(height: 24),
        Row(
          children: [
            Text('Project folders', style: text.titleMedium),
            const Spacer(),
            FilledButton.icon(onPressed: _add, icon: const Icon(Icons.create_new_folder_outlined), label: const Text('Add folder')),
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
              subtitle: Text(ProjectFolders.guess() == null ? 'Add the folder where you clone repos.' : 'Suggested: ${ProjectFolders.guess()}'),
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
        Text('Tools', style: text.titleMedium),
        const SizedBox(height: 8),
        _ToolRow(name: 'adb', path: tools.adb, hint: 'Install Android SDK Platform-Tools and add it to PATH'),
        _ToolRow(name: 'scrcpy', path: tools.scrcpy, hint: 'Bundled with the app — rebuild if missing'),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.name, required this.path, required this.hint});

  final String name;
  final String? path;
  final String hint;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(path != null ? Icons.check_circle : Icons.error_outline, color: path != null ? Colors.green : Colors.red),
          title: Text(name),
          subtitle: Text(path ?? 'Not found. $hint'),
        ),
      );
}
