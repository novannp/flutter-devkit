import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class LocalBuild {
  const LocalBuild(this.package, this.project, this.apk, this.modified);

  final String package;
  final String project;
  final File apk;
  final DateTime modified;

  String get fileName => apk.uri.pathSegments.last;
}

class FlutterProject {
  const FlutterProject(this.name, this.path, this.package, {required this.usesFvm, this.flutterSdk});

  final String name;
  final String path;
  final String package;
  final bool usesFvm;

  /// An SDK chosen in settings, which goes before fvm or PATH.
  final String? flutterSdk;
}

/// Project folders are stored per machine since each developer keeps repos in a different place.
class ProjectFolders {
  static const _key = 'project_folders';
  static const _legacyKey = 'projects_root';

  static Future<List<String>> get() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key) ?? [?prefs.getString(_legacyKey)];
    return saved.where((p) => Directory(p).existsSync()).toList();
  }

  static Future<void> set(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, folders.toSet().toList());
    await prefs.remove(_legacyKey);
  }

  static Future<void> add(String folder) async => set([...await get(), folder]);

  static Future<void> remove(String folder) async => set((await get()).where((f) => f != folder).toList());

  /// Initial guess: the DevKit repo's parent folder, if DevKit runs from a repo build.
  static String? guess() {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      if (File(_join([dir.path, 'pubspec.yaml'])).existsSync()) return dir.parent.path;
      dir = dir.parent;
    }
    return null;
  }
}

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

final _appIdRe = RegExp(r'''applicationId\s*=?\s*["']([^"']+)["']''');
final _namespaceRe = RegExp(r'''namespace\s*=?\s*["']([^"']+)["']''');
final _pubspecNameRe = RegExp(r'^name:\s*(\S+)', multiLine: true);

// Repos are matched by applicationId, so folder names can be anything.
Future<String?> _applicationId(Directory project) async {
  for (final name in ['build.gradle', 'build.gradle.kts']) {
    final f = File(_join([project.path, 'android', 'app', name]));
    if (!f.existsSync()) continue;
    final src = await f.readAsString();
    return (_appIdRe.firstMatch(src) ?? _namespaceRe.firstMatch(src))?[1];
  }
  return null;
}

const _skipDirs = {'build', 'node_modules', 'ios', 'android', 'lib', 'test', 'windows', 'macos', 'linux', 'web'};

Stream<Directory> _walk(Directory dir, int depth) async* {
  yield dir;
  if (depth == 0 || File(_join([dir.path, 'pubspec.yaml'])).existsSync()) return;
  try {
    await for (final d in dir.list()) {
      if (d is! Directory) continue;
      final n = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (n.startsWith('.') || _skipDirs.contains(n)) continue;
      yield* _walk(d, depth - 1);
    }
  } on FileSystemException {
    // Unreadable folders are skipped.
  }
}

/// All Flutter repos (with android/app) in the configured folders, up to 3 levels deep.
Future<List<FlutterProject>> scanFlutterProjects() async {
  final found = <String, FlutterProject>{};
  for (final root in await ProjectFolders.get()) {
    await for (final dir in _walk(Directory(root), 3)) {
      final pubspec = File(_join([dir.path, 'pubspec.yaml']));
      if (!pubspec.existsSync()) continue;
      final appId = await _applicationId(dir);
      if (appId == null) continue;
      final name =
          _pubspecNameRe.firstMatch(await pubspec.readAsString())?[1] ??
          dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final fvm = File(_join([dir.path, '.fvmrc'])).existsSync() || Directory(_join([dir.path, '.fvm'])).existsSync();
      found[dir.path] = FlutterProject(name, dir.path, appId, usesFvm: fvm);
    }
  }
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

class LocalBuilds {
  /// Latest APK per project, newest first.
  static Future<List<LocalBuild>> scan() async {
    final builds = <LocalBuild>[];
    for (final p in await scanFlutterProjects()) {
      final outputs = Directory(_join([p.path, 'build', 'app', 'outputs']));
      if (!outputs.existsSync()) continue;
      final apks = <File>[
        await for (final f in outputs.list(recursive: true))
          if (f is File && f.path.toLowerCase().endsWith('.apk')) f,
      ];
      if (apks.isEmpty) continue;
      final stats = {for (final f in apks) f: f.lastModifiedSync()};
      apks.sort((a, b) => stats[b]!.compareTo(stats[a]!));
      builds.add(LocalBuild(p.package, p.name, apks.first, stats[apks.first]!));
    }
    builds.sort((a, b) => b.modified.compareTo(a.modified));
    return builds;
  }
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
