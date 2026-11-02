import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _prefKey = 'editor_dart_settings';

/// `formatter: page_width:` from a project's analysis_options.yaml, which `dart format` honours too.
int? projectPageWidth(String root) {
  try {
    final text = File(p.join(root, 'analysis_options.yaml')).readAsStringSync();
    return int.tryParse(RegExp(r'^formatter:\s*\n(?:\s+.*\n)*?\s+page_width:\s*(\d+)', multiLine: true).firstMatch(text)?[1] ?? '');
  } on FileSystemException {
    return null;
  }
}

/// Dart settings for one project.
class DartSettings {
  const DartSettings({this.lineLength, this.formatOnSave = true, this.pubGetOnSave = true, this.showTodos = false, this.excludedFolders = const []});

  factory DartSettings.fromJson(Map<String, dynamic> json) => DartSettings(
    lineLength: json['lineLength'] as int?,
    formatOnSave: json['formatOnSave'] as bool? ?? true,
    pubGetOnSave: json['pubGetOnSave'] as bool? ?? true,
    showTodos: json['showTodos'] as bool? ?? false,
    excludedFolders: (json['excludedFolders'] as List?)?.cast<String>() ?? const [],
  );

  /// Null keeps the formatter's default of 80.
  final int? lineLength;
  final bool formatOnSave;
  final bool pubGetOnSave;
  final bool showTodos;

  /// Relative to the project, as typed.
  final List<String> excludedFolders;

  Map<String, dynamic> toJson() => {
    'lineLength': lineLength,
    'formatOnSave': formatOnSave,
    'pubGetOnSave': pubGetOnSave,
    'showTodos': showTodos,
    'excludedFolders': excludedFolders,
  };

  /// What the analysis server gets for `workspace/configuration`. A project's own page_width wins.
  Map<String, dynamic> toServerConfig(String root) => {
    if (lineLength != null && projectPageWidth(root) == null) 'lineLength': lineLength,
    'showTodos': showTodos,
    'analysisExcludedFolders': [for (final f in excludedFolders) p.normalize(p.join(root, f))],
  };

  static Future<DartSettings> load(String root) async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    final all = raw == null ? const <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final json = all[p.normalize(root)] as Map<String, dynamic>?;
    return json == null ? const DartSettings() : DartSettings.fromJson(json);
  }

  Future<void> save(String root) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final all = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    all[p.normalize(root)] = toJson();
    await prefs.setString(_prefKey, jsonEncode(all));
  }
}
