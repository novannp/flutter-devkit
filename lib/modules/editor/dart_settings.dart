import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings.dart';

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
  const DartSettings({
    this.lineLength,
    this.formatOnSave = true,
    this.pubGetOnSave = true,
    this.showTodos = false,
    this.excludedFolders = const [],
    this.organizeImportsOnSave = false,
    this.fixAllOnSave = false,
    this.completeFunctionCalls = false,
    this.enableSnippets = true,
    this.updateImportsOnRename = true,
    this.documentation = 'full',
  });

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
  final bool organizeImportsOnSave;
  final bool fixAllOnSave;
  final bool completeFunctionCalls;
  final bool enableSnippets;
  final bool updateImportsOnRename;
  final String documentation;

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
    'completeFunctionCalls': completeFunctionCalls,
    'enableSnippets': enableSnippets,
    'updateImportsOnRename': updateImportsOnRename,
    'documentation': documentation,
  };

  /// A project's file wins, then what older versions kept per project, then your own settings.
  static Future<DartSettings> load(String root) async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    final all = raw == null ? const <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final legacy = all[p.normalize(root)] as Map<String, dynamic>? ?? const {};
    final s = Settings.instance;
    Object? pick(String key, [String? old]) => s.valueIn(SettingScope.project, 'dart.$key') ?? legacy[old ?? key] ?? s.value('dart.$key');
    return DartSettings(
      lineLength: pick('lineLength') as int?,
      formatOnSave: pick('formatOnSave') as bool? ?? true,
      pubGetOnSave: pick('pubGetOnSave') as bool? ?? true,
      showTodos: pick('showTodos') as bool? ?? false,
      excludedFolders: (pick('excludedFolders') as List?)?.cast<String>() ?? const [],
      organizeImportsOnSave: s.flag('dart.organizeImportsOnSave'),
      fixAllOnSave: s.flag('dart.fixAllOnSave'),
      completeFunctionCalls: s.flag('dart.completeFunctionCalls'),
      enableSnippets: s.flag('dart.enableSnippets'),
      updateImportsOnRename: s.flag('dart.updateImportsOnRename'),
      documentation: s.text('dart.documentation'),
    );
  }

  /// The Dart settings dialog is about one project, so what it changes goes in that project's file.
  Future<void> save(String root) async {
    final before = await load(root);
    final s = Settings.instance;
    if (s.root != null && p.equals(s.root!, root)) {
      if (lineLength != before.lineLength) await s.set(SettingScope.project, 'dart.lineLength', lineLength);
      if (formatOnSave != before.formatOnSave) await s.set(SettingScope.project, 'dart.formatOnSave', formatOnSave);
      if (pubGetOnSave != before.pubGetOnSave) await s.set(SettingScope.project, 'dart.pubGetOnSave', pubGetOnSave);
      if (showTodos != before.showTodos) await s.set(SettingScope.project, 'dart.showTodos', showTodos);
      if (excludedFolders.join('\n') != before.excludedFolders.join('\n')) await s.set(SettingScope.project, 'dart.excludedFolders', excludedFolders);
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final all = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    all[p.normalize(root)] = toJson();
    await prefs.setString(_prefKey, jsonEncode(all));
  }
}
