import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/local_builds.dart';
import '../devices/services/adb_service.dart';
import '../emulators/avd_service.dart';
import '../emulators/system_images_dialog.dart';
import 'core_dep_dialog.dart';
import 'core_deps.dart';
import '../../core/history.dart';

const _prefUpdateCmd = 'maint_update_cmd';
const _defaultUpdateCmd = 'flutter pub upgrade {packages}';

final _sep = Platform.pathSeparator;
String get _home => Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
String get _pubCache =>
    Platform.environment['PUB_CACHE'] ?? '${Platform.environment['LOCALAPPDATA'] ?? _home}${_sep}Pub${_sep}Cache';
String get _gradleCaches => '${Platform.environment['GRADLE_USER_HOME'] ?? '$_home$_sep.gradle'}${_sep}caches';

List<Directory> _gitCacheDirs(Set<String> repos) {
  final dirs = <Directory>[];
  for (final base in [Directory('$_pubCache${_sep}git'), Directory('$_pubCache${_sep}git${_sep}cache')]) {
    if (!base.existsSync()) continue;
    for (final d in base.listSync().whereType<Directory>()) {
      final n = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (repos.any((r) => n.startsWith('$r-'))) dirs.add(d);
    }
  }
  return dirs;
}

Future<int> _sizeOf(List<String> paths) => Isolate.run(() {
  var total = 0;
  for (final p in paths) {
    final d = Directory(p);
    if (!d.existsSync()) continue;
    try {
      for (final f in d.listSync(recursive: true, followLinks: false)) {
        if (f is File) total += f.lengthSync();
      }
    } catch (_) {}
  }
  return total;
});

String _fmt(int? b) => b == null
    ? '…'
    : b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  late final _avd = AvdService(context.read<AdbService>().tools);
  List<FlutterProject>? _projects;
  final _deps = <String, List<String>>{};
  final _coreDeps = <String, List<CoreDep>>{};

  /// Local path overrides other than the git packages (those show on their own chips).
  final _otherOverrides = <String, Map<String, String>>{};
  int? _gradleSize, _pubSize, _gitSize, _imagesSize;
  final _log = <String>[];
  final _logScroll = ScrollController();
  String? _running;
  String _updateCmd = _defaultUpdateCmd;

  @override
  void initState() {
    super.initState();
    _loadProjects().then((_) {
      if (mounted) _measure();
    });
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _updateCmd = p.getString(_prefUpdateCmd) ?? _defaultUpdateCmd);
    });
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  Set<String> get _gitNames => {for (final d in _deps.values) ...d};
  Set<String> get _gitRepos => {for (final d in _coreDeps.values) ...d.map((c) => c.repo).nonNulls};

  Future<void> _loadProjects() async {
    final projects = await scanFlutterProjects();
    for (final p in projects) {
      _deps[p.path] = await CoreDeps.gitPackages(p.path);
      _coreDeps[p.path] = await CoreDeps.read(p.path, _deps[p.path]!);
      await _readOverrides(p);
    }
    if (mounted) setState(() => _projects = projects);
  }

  Future<void> _measure() async {
    setState(() => _gradleSize = _pubSize = _gitSize = _imagesSize = null);
    final sdk = _avd.sdkRoot;
    final results = await Future.wait([
      _sizeOf([_gradleCaches]),
      _sizeOf([_pubCache]),
      _sizeOf(_gitCacheDirs(_gitRepos).map((d) => d.path).toList()),
      _sizeOf([if (sdk != null) '$sdk${_sep}system-images']),
    ]);
    if (!mounted) return;
    setState(() {
      _gradleSize = results[0];
      _pubSize = results[1];
      _gitSize = results[2];
      _imagesSize = results[3];
    });
  }

  void _append(String line) {
    _session?.writeln(line);
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  SessionLog? _session;

  Future<bool> _exec(String label, String command, {String? cwd}) async {
    setState(() => _running = label);
    _session ??= await History.session('maintenance', 'output');
    History.activity('maintenance', label, {'command': command, 'cwd': ?cwd});
    _append('\$ $command${cwd == null ? '' : '   ($cwd)'}');
    try {
      final p = await Process.start(command, const [], workingDirectory: cwd, runInShell: true);
      final out = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(_append);
      final err = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(_append);
      final code = await p.exitCode;
      await Future.wait([out, err]);
      _append(code == 0 ? '✓ $label done' : '✗ $label failed (exit $code)');
      return code == 0;
    } catch (e) {
      _append('✗ $e');
      return false;
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _changeDep(FlutterProject p, CoreDep dep) async {
    final change = await showCoreDepDialog(context, project: p.path, dep: dep);
    if (change == null) return;
    try {
      switch (change) {
        case UseRef(:final ref):
          await CoreDeps.setLocal(p.path, dep.name, null);
          await CoreDeps.setRef(p.path, dep.name, ref);
          _append('${dep.name} → git $ref (pubspec.yaml)');
        case UseLocal(:final folder):
          await CoreDeps.setLocal(p.path, dep.name, folder);
          _append('${dep.name} → local $folder (pubspec_overrides.yaml)');
        case UseGit():
          await CoreDeps.setLocal(p.path, dep.name, null);
          _append('${dep.name} → back to git ${dep.ref ?? ''}');
      }
    } catch (e) {
      _append('✗ $e');
      return;
    }
    await _exec('pub upgrade ${dep.name} · ${p.name}', _flutter(p, 'pub upgrade ${dep.name}'), cwd: p.path);
    _coreDeps[p.path] = await CoreDeps.read(p.path, _deps[p.path] ?? const []);
    if (mounted) setState(() {});
  }

  Future<void> _readOverrides(FlutterProject p) async {
    final all = await CoreDeps.localOverrides(p.path);
    _otherOverrides[p.path] = {
      for (final e in all.entries)
        if (!(_deps[p.path] ?? const []).contains(e.key)) e.key: e.value,
    };
  }

  Future<void> _overrideLocal(FlutterProject p) async {
    final folder = await getDirectoryPath(confirmButtonText: 'Use this package');
    if (folder == null) return;
    final name = await CoreDeps.packageName(folder);
    if (name == null) {
      _append('✗ $folder has no pubspec.yaml with a name');
      return;
    }
    if (name == await CoreDeps.packageName(p.path)) {
      _append('✗ That is ${p.name} itself');
      return;
    }
    if (!await CoreDeps.isDirect(p.path, name)) {
      _append('$name is not a direct dependency of ${p.name}; overriding it anyway (affects transitive use)');
    }
    await _setOverride(p, name, folder);
  }

  Future<void> _setOverride(FlutterProject p, String name, String? folder) async {
    try {
      await CoreDeps.setLocal(p.path, name, folder);
      _append(folder == null ? '$name → back to pubspec.yaml' : '$name → local $folder (pubspec_overrides.yaml)');
    } catch (e) {
      _append('✗ $e');
      return;
    }
    await _exec('pub get · ${p.name}', _flutter(p, 'pub get'), cwd: p.path);
    await _readOverrides(p);
    if (mounted) setState(() {});
  }

  String _flutter(FlutterProject p, String args) => '${p.usesFvm ? 'fvm ' : ''}flutter $args';

  Future<void> _updateCore(FlutterProject p) async {
    final pkgs = _deps[p.path] ?? const [];
    if (pkgs.isEmpty) return;
    var cmd = _updateCmd.replaceAll('{packages}', pkgs.join(' '));
    if (p.usesFvm && cmd.startsWith('flutter ')) cmd = 'fvm $cmd';
    await _exec('Update ${pkgs.join(', ')} · ${p.name}', cmd, cwd: p.path);
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 420, child: Text(body)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteDirs(String label, List<Directory> dirs) async {
    setState(() => _running = label);
    History.activity('maintenance', 'Clear $label', {'paths': dirs.map((d) => d.path).join(', ')});
    _append('Deleting $label…');
    for (final d in dirs) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
        _append('  removed ${d.path}');
      } catch (e) {
        _append('  ✗ ${d.path}: $e');
      }
    }
    _append('✓ $label cleared');
    if (mounted) setState(() => _running = null);
    await _measure();
  }

  Future<void> _clearGradle() async {
    if (!await _confirm(
      'Delete Gradle cache?',
      'Removes $_gradleCaches (${_fmt(_gradleSize)}). The next Android build re-downloads dependencies and will be slow. '
          'Close Android Studio / running builds first.',
    )) {
      return;
    }
    await _deleteDirs('Gradle cache', [Directory(_gradleCaches)]);
  }

  Future<void> _clearPub() async {
    if (!await _confirm(
      'Delete the whole pub cache?',
      'Removes $_pubCache (${_fmt(_pubSize)}). Every project needs `pub get` again afterwards.',
    )) {
      return;
    }
    await _exec('Pub cache clean', 'flutter pub cache clean -f');
    await _measure();
  }

  Future<void> _clearGitCache() async {
    if (!await _confirm(
      'Delete cached ${_gitNames.join(' & ')}?',
      'Forces a fresh clone on the next pub get — fixes a stuck/old version (${_fmt(_gitSize)}).',
    )) {
      return;
    }
    await _deleteDirs('Git packages cache', _gitCacheDirs(_gitRepos));
  }

  Future<void> _editUpdateCmd() async {
    final ctrl = TextEditingController(text: _updateCmd);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update command'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(fontFamily: 'Consolas'),
            decoration: const InputDecoration(
              helperText: '{packages} becomes the git packages the project uses. Use && to chain commands.',
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, _defaultUpdateCmd), child: const Text('Reset')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    setState(() => _updateCmd = v);
    await (await SharedPreferences.getInstance()).setString(_prefUpdateCmd, v);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final busy = _running != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Maintenance', style: text.headlineSmall),
                  Text(
                    'Update shared packages and free up disk space',
                    style: text.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
              const Spacer(),
              if (busy) ...[
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(_running!, style: text.bodySmall),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _CacheCard(
                icon: Icons.inventory_2_outlined,
                title: 'Git packages cache',
                subtitle: _gitNames.isEmpty ? 'No git packages in your projects' : _gitNames.join(' & '),
                size: _gitSize,
                action: 'Clear',
                onPressed: busy ? null : _clearGitCache,
              ),
              _CacheCard(
                icon: Icons.layers_outlined,
                title: 'Pub cache',
                subtitle: _pubCache,
                size: _pubSize,
                action: 'Clear all',
                onPressed: busy ? null : _clearPub,
              ),
              _CacheCard(
                icon: Icons.android,
                title: 'Gradle cache',
                subtitle: _gradleCaches,
                size: _gradleSize,
                action: 'Clear',
                onPressed: busy ? null : _clearGradle,
              ),
              _CacheCard(
                icon: Icons.phone_android,
                title: 'System images',
                subtitle: 'Emulator images in the Android SDK',
                size: _imagesSize,
                action: 'Manage',
                destructive: false,
                onPressed: _avd.sdkRoot == null
                    ? null
                    : () async {
                        await showSystemImagesDialog(context, _avd);
                        _measure();
                      },
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('PROJECTS', style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .6)),
              const Spacer(),
              Tooltip(
                message: 'Command used by "Update core"',
                child: TextButton.icon(
                  onPressed: _editUpdateCmd,
                  icon: const Icon(Icons.terminal, size: 16),
                  label: Text(_updateCmd, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
                ),
              ),
              IconButton(
                tooltip: 'Rescan projects',
                onPressed: _loadProjects,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: _projects == null
                        ? const Center(child: CircularProgressIndicator())
                        : _projects!.isEmpty
                        ? Center(
                            child: Text(
                              'No projects found — add your repos folder in Settings',
                              style: TextStyle(color: scheme.outline),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _projects!.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final p = _projects![i];
                              final deps = _deps[p.path] ?? const [];
                              final core = _coreDeps[p.path] ?? const <CoreDep>[];
                              final others = _otherOverrides[p.path] ?? const <String, String>{};
                              return ListTile(
                                title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.path, style: text.bodySmall?.copyWith(color: scheme.outline)),
                                    if (core.isNotEmpty || others.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          for (final dep in core)
                                            ActionChip(
                                              visualDensity: VisualDensity.compact,
                                              avatar: Icon(
                                                dep.localPath != null ? Icons.folder_open : Icons.call_split,
                                                size: 15,
                                                color: dep.localPath != null ? Colors.orange : scheme.primary,
                                              ),
                                              label: Text('${dep.name} · ${dep.source}'),
                                              tooltip: 'Switch branch or use a local folder',
                                              onPressed: busy ? null : () => _changeDep(p, dep),
                                            ),
                                          for (final e in others.entries)
                                            InputChip(
                                              visualDensity: VisualDensity.compact,
                                              avatar: const Icon(Icons.folder_open, size: 15, color: Colors.orange),
                                              label: Text('${e.key} · local ${e.value.split(_sep).last}'),
                                              tooltip: e.value,
                                              deleteButtonTooltipMessage: 'Remove override',
                                              onDeleted: busy ? null : () => _setOverride(p, e.key, null),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                                trailing: Wrap(
                                  spacing: 6,
                                  children: [
                                    if (deps.isNotEmpty)
                                      FilledButton.tonal(
                                        onPressed: busy ? null : () => _updateCore(p),
                                        child: const Text('Update core'),
                                      ),
                                    OutlinedButton(
                                      onPressed: busy
                                          ? null
                                          : () => _exec('pub get · ${p.name}', _flutter(p, 'pub get'), cwd: p.path),
                                      child: const Text('pub get'),
                                    ),
                                    PopupMenuButton<String>(
                                      enabled: !busy,
                                      icon: const Icon(Icons.more_vert, size: 18),
                                      onSelected: (v) => v == 'override'
                                          ? _overrideLocal(p)
                                          : _exec('$v · ${p.name}', _flutter(p, v), cwd: p.path),
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'override',
                                          child: Text('Override package with local path…'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(value: 'pub upgrade', child: Text('pub upgrade (all)')),
                                        PopupMenuItem(value: 'pub outdated', child: Text('pub outdated')),
                                        PopupMenuItem(value: 'clean', child: Text('flutter clean')),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: Container(
                    decoration: BoxDecoration(color: const Color(0xFF0F1115), borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 6, 0),
                          child: Row(
                            children: [
                              const Text('Output', style: TextStyle(color: Colors.white70, fontSize: 12)),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Clear',
                                onPressed: () => setState(_log.clear),
                                icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.white54),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: SelectionArea(
                            child: ListView.builder(
                              controller: _logScroll,
                              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                              itemCount: _log.length,
                              itemBuilder: (_, i) {
                                final l = _log[i];
                                final color = l.startsWith('✓')
                                    ? const Color(0xFF34D399)
                                    : l.startsWith('✗')
                                    ? const Color(0xFFF87171)
                                    : l.startsWith(r'$')
                                    ? const Color(0xFF93C5FD)
                                    : Colors.white70;
                                return Text(
                                  l,
                                  style: TextStyle(fontFamily: 'Consolas', fontSize: 12, color: color),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CacheCard extends StatelessWidget {
  const _CacheCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.size,
    required this.action,
    required this.onPressed,
    this.destructive = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int? size;
  final String action;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                    const SizedBox(height: 4),
                    Text(_fmt(size), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              TextButton(
                style: destructive ? TextButton.styleFrom(foregroundColor: scheme.error) : null,
                onPressed: onPressed,
                child: Text(action),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
