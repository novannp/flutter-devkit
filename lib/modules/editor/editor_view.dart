import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefFontSize = 'editor_font_size';
const _prefWordWrap = 'editor_word_wrap';

/// How code is shown, the same in every view and project.
class EditorView {
  static const defaultFontSize = 14.0;
  static const minFontSize = 8.0, maxFontSize = 36.0;

  static final fontSize = ValueNotifier(defaultFontSize);
  static final wordWrap = ValueNotifier(false);
  static final listenable = Listenable.merge([fontSize, wordWrap]);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    fontSize.value = prefs.getDouble(_prefFontSize) ?? defaultFontSize;
    wordWrap.value = prefs.getBool(_prefWordWrap) ?? false;
  }

  static Future<void> zoom(double delta) => _setFontSize(fontSize.value + delta);

  static Future<void> resetZoom() => _setFontSize(defaultFontSize);

  static Future<void> _setFontSize(double size) async {
    fontSize.value = size.clamp(minFontSize, maxFontSize);
    await (await SharedPreferences.getInstance()).setDouble(_prefFontSize, fontSize.value);
  }

  static Future<void> toggleWordWrap() async {
    wordWrap.value = !wordWrap.value;
    await (await SharedPreferences.getInstance()).setBool(_prefWordWrap, wordWrap.value);
  }
}

const _prefRecents = 'editor_recents';

/// Folders and files opened lately, newest first.
class RecentPaths {
  static const limit = 20;
  static final paths = ValueNotifier(const <String>[]);

  static Future<void> load() async {
    paths.value = (await SharedPreferences.getInstance()).getStringList(_prefRecents) ?? const [];
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
