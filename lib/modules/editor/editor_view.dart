import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings.dart';

const _prefFontSize = 'editor_font_size';
const _prefWordWrap = 'editor_word_wrap';

/// How code is shown, the same in every view and project.
class EditorView {
  static const defaultFontSize = 14.0;
  static const minFontSize = 8.0, maxFontSize = 36.0;

  static final fontSize = ValueNotifier(defaultFontSize);
  static final wordWrap = ValueNotifier(false);
  static final lineBlame = ValueNotifier(false);
  static final fontFamily = ValueNotifier('');
  static final lineHeight = ValueNotifier(1.4);
  static final listenable = Listenable.merge([fontSize, wordWrap, lineBlame, fontFamily, lineHeight]);

  static Future<void> load() async {
    // Once settings.json is in use, it decides.
    if (Settings.instance.globalPath != null) return;
    final prefs = await SharedPreferences.getInstance();
    fontSize.value = prefs.getDouble(_prefFontSize) ?? defaultFontSize;
    wordWrap.value = prefs.getBool(_prefWordWrap) ?? false;
    lineBlame.value = prefs.getBool(_prefLineBlame) ?? false;
  }

  static Future<void> zoom(double delta) => _setFontSize(fontSize.value + delta);

  static Future<void> resetZoom() => _setFontSize(defaultFontSize);

  static Future<void> _setFontSize(double size) async {
    fontSize.value = size.clamp(minFontSize, maxFontSize);
    await (await SharedPreferences.getInstance()).setDouble(_prefFontSize, fontSize.value);
    await Settings.instance.update('editor.fontSize', fontSize.value);
  }

  static Future<void> toggleLineBlame() async {
    lineBlame.value = !lineBlame.value;
    await (await SharedPreferences.getInstance()).setBool(_prefLineBlame, lineBlame.value);
    await Settings.instance.update('editor.lineBlame', lineBlame.value);
  }

  static Future<void> toggleWordWrap() async {
    wordWrap.value = !wordWrap.value;
    await (await SharedPreferences.getInstance()).setBool(_prefWordWrap, wordWrap.value);
    await Settings.instance.update('editor.wordWrap', wordWrap.value);
  }
}

const _prefRecents = 'editor_recents';
const _prefLineBlame = 'editor_line_blame';

/// Folders and files opened lately, newest first.
/// The project folders opened lately.
class RecentPaths {
  static const limit = 20;
  static final paths = ValueNotifier(const <String>[]);

  static Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getStringList(_prefRecents) ?? const [];
    // Older versions listed single files here too.
    paths.value = [for (final path in saved) if (!FileSystemEntity.isFileSync(path)) path];
  }

  static Future<void> add(String path) async {
    final next = [path, ...paths.value.where((p) => p.toLowerCase() != path.toLowerCase())].take(limit).toList();
    await _save(next);
  }

  static Future<void> remove(String path) => _save(paths.value.where((p) => p != path).toList());

  static Future<void> clear() => _save(const []);

  static Future<void> _save(List<String> next) async {
    paths.value = next;
    await (await SharedPreferences.getInstance()).setStringList(_prefRecents, next);
  }
}

const _prefProjectTabs = 'editor_project_tabs';

/// The tabs each project had open, to come back to when it's opened again.
class ProjectTabs {
  const ProjectTabs(this.files, this.active);

  final List<String> files;
  final String? active;

  static Future<ProjectTabs?> load(String root) async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefProjectTabs);
    final entry = raw == null ? null : (jsonDecode(raw) as Map)[p.canonicalize(root)] as Map?;
    if (entry == null) return null;
    return ProjectTabs((entry['files'] as List).cast<String>(), entry['active'] as String?);
  }

  Future<void> save(String root) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefProjectTabs);
    final all = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    all[p.canonicalize(root)] = {'files': files, 'active': active};
    await prefs.setString(_prefProjectTabs, jsonEncode(all));
  }
}
