import 'package:shared_preferences/shared_preferences.dart';

import '../../core/background.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../editor/editor_view.dart';

/// What older versions kept in preferences, for the first settings.json.
Map<String, Object?> legacySettings(SharedPreferences prefs) => {
  'app.theme': prefs.getString('app_theme'),
  'app.keepRunningOnClose': prefs.getBool('keep_running_on_close'),
  'editor.fontSize': prefs.getDouble('editor_font_size'),
  'editor.wordWrap': prefs.getBool('editor_word_wrap'),
  'editor.lineBlame': prefs.getBool('editor_line_blame'),
  'flutter.hotReloadOnSave': prefs.getBool('editor_reload_on_save'),
};

/// Pushes the settings into the values the app's widgets listen to.
void applySettings() {
  final s = Settings.instance;
  final theme = appThemes.where((t) => t.id == s.text('app.theme')).firstOrNull;
  if (theme != null) appTheme.value = theme;
  keepRunningOnClose.value = s.flag('app.keepRunningOnClose');
  EditorView.fontSize.value = s.number('editor.fontSize') ?? EditorView.defaultFontSize;
  EditorView.fontFamily.value = s.text('editor.fontFamily').trim();
  EditorView.lineHeight.value = s.number('editor.lineHeight') ?? 1.4;
  EditorView.wordWrap.value = s.flag('editor.wordWrap');
  EditorView.lineBlame.value = s.flag('editor.lineBlame');
}
