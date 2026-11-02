import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/local_builds.dart';
import '../../core/tools.dart';

/// Where a core package currently comes from in a project.
class CoreDep {
  const CoreDep({required this.name, this.url, this.ref, this.localPath});

  final String name;
  final String? url;
  final String? ref;

  /// Set when pubspec_overrides.yaml points this package at a local folder.
  final String? localPath;

  /// Repo folder name; pub caches it as `<repo>-<hash>`.
  String? get repo => url?.split(RegExp(r'[/:]')).last.replaceFirst(RegExp(r'\.git$'), '');

  String get source => localPath != null ? 'local ${p.basename(localPath!)}' : (ref ?? 'default');
}

class CoreDeps {
  static File _pubspec(String project) => File(p.join(project, 'pubspec.yaml'));
  static File _overrides(String project) => File(p.join(project, 'pubspec_overrides.yaml'));

  /// Lines of the `  name:` block under dependencies, as [start, end) indexes.
  static (int, int)? _block(List<String> lines, String name) {
    final start = lines.indexWhere((l) => RegExp('^  $name:\\s*\$').hasMatch(l));
    if (start < 0) return null;
    var end = start + 1;
    // Block continues while lines are indented deeper (comments like "#    path:" included).
    while (end < lines.length && (lines[end].startsWith('   ') || RegExp(r'^#\s{3,}').hasMatch(lines[end]))) {
      end++;
    }
    return (start, end);
  }

  /// Packages the project pulls from git, the ones teams usually share and pin by branch.
  static Future<List<String>> gitPackages(String project) async {
    final lines = (await _pubspec(project).readAsString()).split('\n');
    return {
      for (final m in lines.map(RegExp(r'^  (\w+):\s*$').firstMatch).nonNulls)
        if (_block(lines, m[1]!) case (final s, final e))
          if (lines.sublist(s, e).any((l) => RegExp(r'^\s+git:').hasMatch(l))) m[1]!,
    }.toList();
  }

  static Future<List<CoreDep>> read(String project, List<String> names) async {
    final lines = (await _pubspec(project).readAsString()).split('\n');
    final overrides = _overrides(project).existsSync() ? await _overrides(project).readAsString() : '';
    return [
      for (final n in names)
        if (_block(lines, n) case (final s, final e))
          () {
            final block = lines.sublist(s, e).where((l) => !l.trimLeft().startsWith('#')).join('\n');
            final local = RegExp('^  $n:\\s*\\n\\s+path:\\s*(.+)\$', multiLine: true).firstMatch(overrides)?[1]?.trim();
            return CoreDep(
              name: n,
              url: RegExp(r'(?:url|git):[ \t]*(\S+)').firstMatch(block)?[1],
              ref: RegExp(r'ref:\s*(\S+)').firstMatch(block)?[1],
              localPath: local == null ? null : p.normalize(p.join(project, local)),
            );
          }(),
    ];
  }

  /// Branches from the remote; empty if the remote can't be reached (no SSH key, placeholder URL…).
  static Future<List<String>> branches(String url) async {
    final r = await Tools.run('git', ['ls-remote', '--heads', url], timeout: const Duration(seconds: 20));
    if (!r.ok) return [];
    return [for (final m in RegExp(r'refs/heads/(\S+)').allMatches(r.stdout)) m[1]!]..sort();
  }

  /// Rewrites `ref:` inside the package's git block in pubspec.yaml.
  static bool isHttps(String? url) => url != null && url.startsWith('http');

  /// `https://user:token@bitbucket.org/team/repo.git` → `git@bitbucket.org:team/repo.git`.
  static String? toSsh(String url) {
    final m = RegExp(r'^https?://(?:[^@/]+@)?([^/]+)/(.+?)(?:\.git)?/?$').firstMatch(url);
    return m == null ? null : 'git@${m[1]}:${m[2]}.git';
  }

  static Future<void> setUrl(String project, String name, String url) async {
    final file = _pubspec(project);
    final lines = (await file.readAsString()).split('\n');
    final (s, e) = _block(lines, name) ?? (throw StateError('$name not found in pubspec.yaml'));
    for (var i = s; i < e; i++) {
      if (RegExp(r'^\s+url:').hasMatch(lines[i])) lines[i] = lines[i].replaceFirst(RegExp(r'url:.*'), 'url: $url');
    }
    await file.writeAsString(lines.join('\n'));
  }

  static Future<void> setRef(String project, String name, String ref) async {
    final file = _pubspec(project);
    final lines = (await file.readAsString()).split('\n');
    final (s, e) = _block(lines, name) ?? (throw StateError('$name not found in pubspec.yaml'));
    final refIdx = [for (var i = s; i < e; i++) i].where((i) => RegExp(r'^\s+ref:').hasMatch(lines[i])).firstOrNull;
    if (refIdx != null) {
      lines[refIdx] = lines[refIdx].replaceFirst(RegExp(r'ref:.*'), 'ref: $ref');
    } else {
      final urlIdx = [for (var i = s; i < e; i++) i].firstWhere((i) => RegExp(r'^\s+url:').hasMatch(lines[i]));
      final indent = RegExp(r'^\s*').firstMatch(lines[urlIdx])![0]!;
      lines.insert(urlIdx + 1, '${indent}ref: $ref');
    }
    await file.writeAsString(lines.join('\n'));
  }

  /// Points the package at a local folder via pubspec_overrides.yaml (null removes the override).
  static Future<void> setLocal(String project, String name, String? folder) async {
    final file = _overrides(project);
    var lines = file.existsSync() ? (await file.readAsString()).split('\n') : <String>[];
    if (_block(lines, name) case (final s, final e)) lines.removeRange(s, e);
    if (folder != null) {
      var rel = p.relative(folder, from: project).replaceAll(r'\', '/');
      if (!rel.startsWith('.')) rel = './$rel';
      if (!lines.any((l) => l.startsWith('dependency_overrides:'))) {
        lines = ['dependency_overrides:', ...lines.where((l) => l.trim().isNotEmpty)];
      }
      final at = lines.indexWhere((l) => l.startsWith('dependency_overrides:')) + 1;
      lines.insertAll(at, ['  $name:', '    path: $rel']);
    }
    final meaningful = lines.where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#')).toList();
    if (meaningful.length <= 1) {
      if (file.existsSync()) await file.delete();
      return;
    }
    await file.writeAsString('${lines.where((l) => l.trim().isNotEmpty).join('\n')}\n');
    await _excludeLocally(project);
  }

  // Keep the override out of commits even in repos that don't gitignore it.
  static Future<void> _excludeLocally(String project) async {
    final r = await Tools.run('git', ['-C', project, 'check-ignore', '-q', 'pubspec_overrides.yaml']);
    if (r.exitCode == 0) return;
    final exclude = File(p.join(project, '.git', 'info', 'exclude'));
    if (!exclude.parent.existsSync()) return;
    await exclude.writeAsString('\npubspec_overrides.yaml\n', mode: FileMode.append);
  }

  /// Every package pubspec_overrides.yaml points at a local folder: name → absolute path.
  static Future<Map<String, String>> localOverrides(String project) async {
    final file = _overrides(project);
    if (!file.existsSync()) return {};
    final re = RegExp(r'^  (\w+):\s*\n\s+path:\s*(.+)$', multiLine: true);
    return {
      for (final m in re.allMatches(await file.readAsString())) m[1]!: p.normalize(p.join(project, m[2]!.trim())),
    };
  }

  /// The `name:` in [folder]'s pubspec.yaml, or null when it isn't a Dart package.
  static Future<String?> packageName(String folder) async {
    final pubspec = _pubspec(folder);
    if (!pubspec.existsSync()) return null;
    return RegExp(r'^name:\s*(\w+)', multiLine: true).firstMatch(await pubspec.readAsString())?[1];
  }

  /// Whether [name] is a direct dependency (regular or dev) of the project.
  static Future<bool> isDirect(String project, String name) async =>
      RegExp('^  $name:', multiLine: true).hasMatch(await _pubspec(project).readAsString());

  /// Local clones of [name] found in the configured project folders.
  static Future<List<String>> localClones(String name) async {
    final found = <String>{};
    for (final root in await ProjectFolders.get()) {
      for (final dir in [Directory(root), ...Directory(root).listSync().whereType<Directory>()]) {
        final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
        if (!pubspec.existsSync()) continue;
        if (RegExp('^name:\\s*$name\\s*\$', multiLine: true).hasMatch(await pubspec.readAsString())) {
          found.add(dir.path);
        }
      }
    }
    return found.toList();
  }
}
