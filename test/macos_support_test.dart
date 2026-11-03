import 'dart:io';

import 'package:hotrestart/core/child_processes.dart';
import 'package:hotrestart/core/login_path.dart';
import 'package:hotrestart/core/platform_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shortcut labels use the Mac symbols', () {
    expect(macKeys('Hot restart (Ctrl+Shift+F5)'), 'Hot restart (⌘⇧F5)');
    expect(macKeys('Ctrl + Shift + S'), '⌘⇧S');
    expect(macKeys('Ctrl+click'), '⌘+click');
    expect(macKeys('Alt+Z'), '⌥Z');
  });

  test('what the system keeps for Cmd stays on Ctrl', () {
    expect(macKeys('Ctrl+Space'), '⌃Space');
    expect(macKeys('Ctrl+Shift+Space'), '⌃⇧Space');
    expect(macKeys('Ctrl+`'), '⌃`');
    expect(macKeys('Ctrl+Tab'), '⌃Tab');
  });

  test('labels stay as written off a Mac', () {
    if (!Platform.isMacOS) expect(platformKeys('Ctrl+P'), 'Ctrl+P');
  });

  test('the login PATH is found past what startup files print', () {
    expect(pathFromShellOutput('Welcome!\n\n__HOTRESTART_PATH__/opt/homebrew/bin:/usr/bin\n'), '/opt/homebrew/bin:/usr/bin');
    expect(pathFromShellOutput('no marker here'), isNull);
    expect(pathFromShellOutput('__HOTRESTART_PATH__\n'), isNull);
  });

  test('finds embedded scrcpy and which HotRestart started it', () {
    const ps = '''
  101 /usr/bin/login
  202 /Applications/HotRestart.app/Contents/Resources/scrcpy/scrcpy -s abc --window-title=hotrestart-embed-77-0 --no-audio
  303 /opt/homebrew/bin/scrcpy -s def
''';
    expect(embeddedScrcpyIn(ps).toList(), [(202, 77)]);
  });
}
