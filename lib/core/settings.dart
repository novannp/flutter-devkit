import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SettingType { boolean, integer, number, text, list, choice }

class SettingDef {
  const SettingDef(this.key, this.type, this.fallback, this.title, this.description, {this.choices = const {}, this.min, this.max, this.projectable = true});

  final String key;
  final SettingType type;
  final Object? fallback;
  final String title, description;
  final Map<String, String> choices;
  final num? min, max;

  /// False for what a cloned repo must not decide for you, or that belongs to the machine.
  final bool projectable;

  String get section => key.split('.').first;
}

const settingDefs = <SettingDef>[
  SettingDef('app.theme', SettingType.choice, null, 'Theme', 'The colors of the whole app.'),
  SettingDef('app.reopenLastProject', SettingType.boolean, true, 'Reopen the last project', 'Start where you left off, instead of on the start page.', projectable: false),

  SettingDef('editor.fontSize', SettingType.number, 14.0, 'Font size', 'The size of code. Ctrl+plus and Ctrl+minus change it too.', min: 8, max: 36),
  SettingDef('editor.fontFamily', SettingType.text, '', 'Font', 'A font installed on this computer. Empty uses the built-in choice.'),
  SettingDef('editor.lineHeight', SettingType.number, 1.4, 'Line height', 'The space between lines, as a multiple of the font size.', min: 1, max: 3),
  SettingDef('editor.wordWrap', SettingType.boolean, false, 'Word wrap', 'Long lines continue on the next row. Alt+Z changes it too.'),
  SettingDef('editor.lineBlame', SettingType.boolean, false, 'Line blame', "Show who last changed the caret's line, at the end of it."),
  SettingDef('editor.trimTrailingWhitespace', SettingType.boolean, false, 'Trim trailing spaces on save', 'Removes spaces at the ends of lines when a file is saved.'),
  SettingDef('editor.insertFinalNewline', SettingType.boolean, false, 'End files with a newline', 'Adds one when a file is saved without it.'),
  SettingDef('editor.autoSave', SettingType.choice, 'off', 'Auto save', 'Save a second after you stop typing. Format on save only runs when you save yourself.', choices: {'off': 'Off', 'afterDelay': 'After a delay'}),

  SettingDef('dart.lineLength', SettingType.integer, null, 'Line length', "Where the formatter wraps. Empty uses Dart's 80. A project's analysis_options.yaml wins.", min: 40, max: 400),
  SettingDef('dart.formatOnSave', SettingType.boolean, true, 'Format on save', 'Runs the Dart formatter whenever you save.'),
  SettingDef('dart.organizeImportsOnSave', SettingType.boolean, false, 'Organize imports on save', 'Sorts imports and removes unused ones whenever you save.'),
  SettingDef('dart.fixAllOnSave', SettingType.boolean, false, 'Apply fixes on save', 'Applies the fixes the analyzer is sure of whenever you save.'),
  SettingDef('dart.pubGetOnSave', SettingType.boolean, true, 'Run pub get on save', 'Runs it whenever pubspec.yaml is saved.'),
  SettingDef('dart.showTodos', SettingType.boolean, false, 'Show TODOs in Problems', 'Lists TODO comments next to errors and warnings.'),
  SettingDef('dart.completeFunctionCalls', SettingType.boolean, false, 'Complete function calls', 'Accepting a function suggestion also fills in its required arguments.'),
  SettingDef('dart.enableSnippets', SettingType.boolean, true, 'Code snippets', 'Suggest snippets such as stl and stf.'),
  SettingDef('dart.updateImportsOnRename', SettingType.boolean, true, 'Update imports on rename', "Fix other files' imports when a file is renamed."),
  SettingDef('dart.documentation', SettingType.choice, 'full', 'Documentation in tooltips', 'How much of the docs hover and suggestions show.', choices: {'none': 'None', 'summary': 'Summary', 'full': 'Full'}),
  SettingDef('dart.excludedFolders', SettingType.list, <String>[], 'Folders the analyzer skips', 'Relative to the project, such as build/generated.'),

  SettingDef('flutter.hotReloadOnSave', SettingType.boolean, true, 'Hot reload on save', 'Reloads the running app whenever you save a Dart file.'),
  SettingDef('flutter.mode', SettingType.choice, 'debug', 'Run mode', 'Hot reload and the debugger only work in debug.', choices: {'debug': 'Debug', 'profile': 'Profile', 'release': 'Release'}),
  SettingDef('flutter.target', SettingType.text, '', 'Entry point', 'The file Run starts from. Empty uses lib/main.dart.'),
  SettingDef('flutter.flavor', SettingType.text, '', 'Flavor', 'The build flavor Run uses, if the project has them.'),
  SettingDef('flutter.dartDefines', SettingType.list, <String>[], 'Dart defines', 'Each is passed to Run as --dart-define, such as API_URL=https://example.com.'),
  SettingDef('flutter.runArgs', SettingType.list, <String>[], 'More run arguments', 'Added to flutter run as they are, such as --no-sound-null-safety.'),
  SettingDef('flutter.sdkPath', SettingType.text, '', 'Flutter SDK folder', 'Use this SDK instead of fvm or the one on PATH. Only here in your own settings, since it decides what program runs.', projectable: false),
];

final _defsByKey = {for (final d in settingDefs) d.key: d};

enum SettingScope { global, project }

/// JSON with the comments and trailing commas that people leave in a settings file.
Map<String, dynamic> parseSettingsJson(String text) {
  final out = StringBuffer();
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[++i]);
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
      out.write(c);
    } else if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 1;
    } else if (c == ',') {
      var next = i + 1;
      while (next < text.length && ' \t\r\n'.contains(text[next])) {
        next++;
      }
      if (next >= text.length || (text[next] != '}' && text[next] != ']')) out.write(c);
    } else {
      out.write(c);
    }
  }
  final body = out.toString().trim();
  if (body.isEmpty) return {};
  final data = jsonDecode(body);
  if (data is! Map<String, dynamic>) throw const FormatException('Expected an object at the top');
  return data;
}

/// A value of the wrong type counts as not set, so a typo can't break the app.
bool _fits(SettingDef def, Object? value) => switch (def.type) {
  SettingType.boolean => value is bool,
  SettingType.integer => value is int,
  SettingType.number => value is num,
  SettingType.text => value is String,
  SettingType.list => value is List && value.every((e) => e is String),
  SettingType.choice => value is String && (def.choices.isEmpty || def.choices.containsKey(value)),
};

/// A run argument goes through a shell on Windows, and a project's settings come with whatever repo was cloned.
bool isSafeRunArg(String arg) => !RegExp('[&|<>^"%`;\$\r\n]').hasMatch(arg);

/// Defaults, then your own settings.json, then the project's .devkit/settings.json.
class Settings extends ChangeNotifier {
  Settings._();

  static final instance = Settings._();

  var _global = <String, dynamic>{};
  var _project = <String, dynamic>{};
  String? _globalPath;
  String? _root;
  DateTime? _globalStamp, _projectStamp;
  Timer? _poll;

  /// What's wrong with the file being read, until it's fixed. The last good values stay in use.
  String? globalError, projectError;

  String? get globalPath => _globalPath;
  String? get root => _root;
  String? get projectPath => _root == null ? null : p.join(_root!, '.devkit', 'settings.json');

  @visibleForTesting
  void reset() {
    _poll?.cancel();
    _poll = null;
    _global = {};
    _project = {};
    _globalPath = _root = null;
    _globalStamp = _projectStamp = null;
    globalError = projectError = null;
  }

  /// [seed] is what older versions kept elsewhere, carried over the first time the file is written.
  Future<void> load({String? path, Map<String, Object?> Function()? seed}) async {
    _globalPath = path ?? p.join((await getApplicationSupportDirectory()).path, 'settings.json');
    final file = File(_globalPath!);
    if (!file.existsSync() && seed != null) {
      _global = {...seed()}..removeWhere((_, v) => v == null);
      await _write(SettingScope.global);
    }
    _read(SettingScope.global);
    notifyListeners();
  }

  /// Picks up changes made by hand in the editor or from a git pull.
  void watch() => _poll ??= Timer.periodic(const Duration(seconds: 2), (_) => refresh());

  void refresh() {
    var changed = false;
    for (final scope in SettingScope.values) {
      final path = _pathOf(scope);
      if (path == null) continue;
      final file = File(path);
      final stamp = file.existsSync() ? file.lastModifiedSync() : null;
      if (stamp != _stampOf(scope)) {
        _read(scope);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void openProject(String? root) {
    _root = root;
    _project = {};
    _projectStamp = null;
    projectError = null;
    if (root != null) _read(SettingScope.project);
    notifyListeners();
  }

  String? _pathOf(SettingScope scope) => scope == SettingScope.global ? _globalPath : projectPath;

  DateTime? _stampOf(SettingScope scope) => scope == SettingScope.global ? _globalStamp : _projectStamp;

  void _read(SettingScope scope) {
    final path = _pathOf(scope);
    if (path == null) return;
    final file = File(path);
    DateTime? stamp;
    String? error;
    Map<String, dynamic>? values;
    try {
      if (file.existsSync()) {
        stamp = file.lastModifiedSync();
        values = parseSettingsJson(file.readAsStringSync());
      } else {
        values = {};
      }
    } on FormatException catch (e) {
      error = e.message;
    } on FileSystemException catch (e) {
      error = e.message;
    }
    if (scope == SettingScope.global) {
      _globalStamp = stamp;
      globalError = error;
      if (values != null) _global = values;
    } else {
      _projectStamp = stamp;
      projectError = error;
      if (values != null) _project = values;
    }
  }

  Future<void> _write(SettingScope scope) async {
    final path = _pathOf(scope);
    if (path == null) return;
    final file = File(path);
    file.parent.createSync(recursive: true);
    final values = scope == SettingScope.global ? _global : _project;
    file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(values)}\n', flush: true);
    final stamp = file.lastModifiedSync();
    if (scope == SettingScope.global) {
      _globalStamp = stamp;
      globalError = null;
    } else {
      _projectStamp = stamp;
      projectError = null;
    }
  }

  /// Creates the file if needed, so there's something to open and edit by hand.
  Future<String?> ensureFile(SettingScope scope) async {
    final path = _pathOf(scope);
    if (path != null && !File(path).existsSync()) await _write(scope);
    return path;
  }

  Object? _valid(String key, Object? value) {
    final def = _defsByKey[key];
    return def == null || _fits(def, value) ? value : null;
  }

  Object? valueIn(SettingScope scope, String key) {
    final def = _defsByKey[key];
    if (scope == SettingScope.project && def != null && !def.projectable) return null;
    return _valid(key, (scope == SettingScope.global ? _global : _project)[key]);
  }

  Object? value(String key) => valueIn(SettingScope.project, key) ?? valueIn(SettingScope.global, key) ?? _defsByKey[key]?.fallback;

  /// Which file a setting's value comes from, or null when it's the default.
  SettingScope? sourceOf(String key) {
    if (valueIn(SettingScope.project, key) != null) return SettingScope.project;
    if (valueIn(SettingScope.global, key) != null) return SettingScope.global;
    return null;
  }

  bool flag(String key) => value(key) == true;

  String text(String key) => value(key) as String? ?? '';

  List<String> list(String key) => (value(key) as List?)?.cast<String>() ?? const [];

  double? number(String key) {
    final v = value(key) as num?;
    final def = _defsByKey[key];
    if (v == null) return null;
    return v.toDouble().clamp((def?.min ?? double.negativeInfinity).toDouble(), (def?.max ?? double.infinity).toDouble());
  }

  Future<void> set(SettingScope scope, String key, Object? value) async {
    if (scope == SettingScope.project && (_root == null || _defsByKey[key]?.projectable == false)) return;
    final values = scope == SettingScope.global ? _global : _project;
    if (value == null) {
      if (!values.containsKey(key)) return;
      values.remove(key);
    } else {
      values[key] = value;
    }
    notifyListeners();
    try {
      await _write(scope);
    } on FileSystemException catch (e) {
      if (scope == SettingScope.global) {
        globalError = e.message;
      } else {
        projectError = e.message;
      }
      notifyListeners();
    }
  }

  /// For a toggle outside the settings page: it changes the value where the value already lives.
  Future<void> update(String key, Object? value) => set(valueIn(SettingScope.project, key) != null ? SettingScope.project : SettingScope.global, key, value);

  /// The arguments Run adds to `flutter run`.
  List<String> runArgs() => _allRunArgs().where(isSafeRunArg).toList();

  /// What was left out of [runArgs], to say so rather than run something else than asked.
  List<String> blockedRunArgs() => _allRunArgs().where((a) => !isSafeRunArg(a)).toList();

  List<String> _allRunArgs() {
    final mode = text('flutter.mode'), target = text('flutter.target').trim(), flavor = text('flutter.flavor').trim();
    return [
      if (mode == 'profile' || mode == 'release') '--$mode',
      // Flag and value as one, so a refused value can't leave its flag behind.
      if (target.isNotEmpty) '--target=$target',
      if (flavor.isNotEmpty) '--flavor=$flavor',
      for (final d in list('flutter.dartDefines')) '--dart-define=$d',
      ...list('flutter.runArgs'),
    ];
  }
}
