import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/local_builds.dart';
import '../../modules/devices/services/adb_service.dart';
import '../emulators/avd_service.dart';
import '../emulators/system_images_dialog.dart';
import 'core_deps.dart';
import '../../core/history.dart';

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
  final _deps = <String, List<String>>{};
  final _coreDeps = <String, List<CoreDep>>{};
  int? _gradleSize, _pubSize, _gitSize, _imagesSize;
  final _log = <String>[];
  final _logScroll = ScrollController();
  String? _running;

  @override
  void initState() {
    super.initState();
    _loadProjects().then((_) {
      if (mounted) _measure();
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
    }
    if (mounted) setState(() {});
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
          Expanded(
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
