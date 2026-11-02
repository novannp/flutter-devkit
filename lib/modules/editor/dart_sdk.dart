import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

bool projectUsesFvm(String project) =>
    File(p.join(project, '.fvmrc')).existsSync() || Directory(p.join(project, '.fvm')).existsSync();

String? _fvmVersion(String project) {
  for (final (file, key) in [('.fvmrc', 'flutter'), (p.join('.fvm', 'fvm_config.json'), 'flutterSdkVersion')]) {
    try {
      final v = (jsonDecode(File(p.join(project, file)).readAsStringSync()) as Map)[key];
      if (v is String && v.isNotEmpty) return v;
    } on Exception {
      // Missing or half-written config: try the next one.
    }
  }
  return null;
}

/// The Flutter SDK folder a project pins through fvm, or null when it uses whatever is on PATH.
String? flutterSdkOf(String project, {Map<String, String>? environment}) {
  final link = p.join(project, '.fvm', 'flutter_sdk');
  if (Directory(link).existsSync()) return link;
  final version = _fvmVersion(project);
  if (version == null) return null;
  final env = environment ?? Platform.environment;
  final cache = env['FVM_CACHE_PATH'] ?? p.join(env['USERPROFILE'] ?? env['HOME'] ?? '', 'fvm');
  final sdk = p.join(cache, 'versions', version);
  return Directory(sdk).existsSync() ? sdk : null;
}

class DartCommand {
  const DartCommand(this.exe, this.args, {this.runInShell = false});

  final String exe;
  final List<String> args;
  final bool runInShell;
}

/// How to run `dart` with the project's own SDK, so analysis matches its Flutter version.
DartCommand dartCommand(String project) {
  final sdk = flutterSdkOf(project);
  if (sdk != null) {
    final dart = p.join(sdk, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
    if (File(dart).existsSync()) return DartCommand(dart, const []);
  }
  // A fresh SDK has no dart-sdk cache yet; the wrappers download it and need a shell on Windows.
  return projectUsesFvm(project)
      ? DartCommand('fvm', const ['dart'], runInShell: Platform.isWindows)
      : DartCommand('dart', const [], runInShell: Platform.isWindows);
}

/// Environment for terminals in a project: `flutter` and `dart` resolve to its pinned SDK.
Map<String, String> projectEnvironment(String project) {
  final env = Map<String, String>.of(Platform.environment);
  final sdk = flutterSdkOf(project);
  if (sdk == null) return env;
  final key = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
  env[key] = '${p.join(sdk, 'bin')}${Platform.isWindows ? ';' : ':'}${env[key] ?? ''}';
  return env;
}

class SdkVersions {
  const SdkVersions(this.flutter, this.dart, this.path);

  final String flutter, dart, path;
}

Future<String?> _flutterOnPath() async {
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['flutter']);
    final first = '${r.stdout}'.split('\n').first.trim();
    return r.exitCode == 0 && first.isNotEmpty ? p.dirname(p.dirname(first)) : null;
  } on ProcessException {
    return null;
  }
}

/// The SDK a project builds with. Read from the SDK's own files, because `flutter --version` takes seconds.
Future<SdkVersions?> sdkVersionsOf(String project) async {
  final sdk = flutterSdkOf(project) ?? await _flutterOnPath();
  if (sdk == null) return null;
  String? flutter, dart;
  try {
    final json = jsonDecode(File(p.join(sdk, 'bin', 'cache', 'flutter.version.json')).readAsStringSync()) as Map;
    flutter = (json['frameworkVersion'] ?? json['flutterVersion']) as String?;
    dart = json['dartSdkVersion'] as String?;
  } on Exception {
    // Older SDKs don't have this file; the two below cover them.
  }
  String? read(List<String> parts) {
    final f = File(p.joinAll([sdk, ...parts]));
    return f.existsSync() ? f.readAsStringSync().trim() : null;
  }

  flutter ??= read(['version']);
  dart ??= read(['bin', 'cache', 'dart-sdk', 'version']);
  if (flutter == null || dart == null) return null;
  // Can read like "3.13.4 (build 3.13.4-0.0.dev)".
  return SdkVersions(flutter, dart.split(' ').first, sdk);
}
