import 'dart:io';

import 'package:devkit/core/panels.dart';
import 'package:devkit/core/settings.dart';
import 'package:devkit/core/theme.dart';
import 'package:devkit/core/windows.dart';
import 'package:devkit/modules/editor/dart_settings.dart';
import 'package:devkit/modules/editor/editor_page.dart';
import 'package:devkit/modules/editor/editor_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  late String global, root;
  final s = Settings.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    s.reset();
    dir = Directory.systemTemp.createTempSync('settings');
    global = p.join(dir.path, 'settings.json');
    root = p.join(dir.path, 'project');
    Directory(root).createSync();
  });
  tearDown(() {
    s.reset();
    dir.deleteSync(recursive: true);
  });

  File projectFile() => File(p.join(root, '.devkit', 'settings.json'))..parent.createSync(recursive: true);

  group('JSON', () {
    test('takes comments and trailing commas, but not inside strings', () {
      final out = parseSettingsJson('''
{
  // a note
  "a": "http://x", /* another */
  "b": [1, 2,],
  "c": "x,]",
}''');
      expect(out, {'a': 'http://x', 'b': [1, 2], 'c': 'x,]'});
    });

    test('an empty file is empty, and anything else that is not an object is refused', () {
      expect(parseSettingsJson('  '), isEmpty);
      expect(() => parseSettingsJson('[1]'), throwsFormatException);
      expect(() => parseSettingsJson('{nope'), throwsFormatException);
    });
  });

  group('layers', () {
    test('a project wins over yours, and yours over the default', () async {
      expect(s.number('editor.fontSize'), 14);
      File(global).writeAsStringSync('{"editor.fontSize": 16, "editor.wordWrap": true}');
      await s.load(path: global);
      expect(s.number('editor.fontSize'), 16);
      expect(s.sourceOf('editor.fontSize'), SettingScope.global);
      projectFile().writeAsStringSync('{"editor.fontSize": 20}');
      s.openProject(root);
      expect(s.number('editor.fontSize'), 20);
      expect(s.sourceOf('editor.fontSize'), SettingScope.project);
      expect(s.flag('editor.wordWrap'), isTrue);
      s.openProject(null);
      expect(s.number('editor.fontSize'), 16);
    });

    test('a wrong type or an unknown choice counts as not set, and numbers stay in range', () async {
      File(global).writeAsStringSync('{"editor.fontSize": "big", "editor.autoSave": "sometimes", "editor.lineHeight": 99}');
      await s.load(path: global);
      expect(s.number('editor.fontSize'), 14);
      expect(s.text('editor.autoSave'), 'off');
      expect(s.number('editor.lineHeight'), 3);
    });

    test('a repo cannot choose the SDK that runs', () async {
      projectFile().writeAsStringSync('{"flutter.sdkPath": "C:/evil", "app.reopenLastProject": false}');
      await s.load(path: global);
      s.openProject(root);
      expect(s.text('flutter.sdkPath'), '');
      expect(s.flag('app.reopenLastProject'), isTrue);
      await s.set(SettingScope.project, 'flutter.sdkPath', 'C:/evil');
      expect(s.text('flutter.sdkPath'), '');
    });

    test('a broken file keeps the last good values and says what is wrong', () async {
      File(global).writeAsStringSync('{"editor.fontSize": 16}');
      await s.load(path: global);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(global).writeAsStringSync('{broken');
      File(global).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      s.refresh();
      expect(s.globalError, isNotNull);
      expect(s.number('editor.fontSize'), 16);
    });

    test('hand edits are picked up, and writes keep what the file already had', () async {
      await s.load(path: global);
      s.openProject(root);
      var heard = 0;
      void listener() => heard++;
      s.addListener(listener);
      addTearDown(() => s.removeListener(listener));
      await s.set(SettingScope.project, 'dart.lineLength', 100);
      expect(parseSettingsJson(projectFile().readAsStringSync()), {'dart.lineLength': 100});
      projectFile().writeAsStringSync('{"dart.lineLength": 90, "custom": 1}');
      projectFile().setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      heard = 0;
      s.refresh();
      expect(heard, 1);
      await s.set(SettingScope.project, 'dart.showTodos', true);
      expect(parseSettingsJson(projectFile().readAsStringSync()), {'dart.lineLength': 90, 'custom': 1, 'dart.showTodos': true});
      await s.set(SettingScope.project, 'dart.lineLength', null);
      expect(s.value('dart.lineLength'), isNull);
    });

    test('older values carry over only the first time', () async {
      await s.load(path: global, seed: () => {'editor.fontSize': 18.0, 'editor.wordWrap': null});
      expect(s.number('editor.fontSize'), 18);
      expect(parseSettingsJson(File(global).readAsStringSync()), {'editor.fontSize': 18.0});
      await s.load(path: global, seed: () => {'editor.fontSize': 30.0});
      expect(s.number('editor.fontSize'), 18);
    });

    test('a toggle changes the value where it lives', () async {
      await s.load(path: global);
      s.openProject(root);
      await s.update('editor.wordWrap', true);
      expect(s.valueIn(SettingScope.global, 'editor.wordWrap'), isTrue);
      await s.set(SettingScope.project, 'editor.wordWrap', true);
      await s.update('editor.wordWrap', false);
      expect(s.valueIn(SettingScope.project, 'editor.wordWrap'), isFalse);
      expect(s.valueIn(SettingScope.global, 'editor.wordWrap'), isTrue);
    });
  });

  group('run arguments', () {
    test('come from the settings, in order', () async {
      File(global).writeAsStringSync('{"flutter.mode": "profile", "flutter.target": "lib/dev.dart", "flutter.flavor": "dev", "flutter.dartDefines": ["A=1"], "flutter.runArgs": ["--verbose"]}');
      await s.load(path: global);
      expect(s.runArgs(), ['--profile', '--target=lib/dev.dart', '--flavor=dev', '--dart-define=A=1', '--verbose']);
    });

    test('with shell characters are left out, and reported', () async {
      projectFile().writeAsStringSync(r'{"flutter.runArgs": ["--ok", "& calc", "x|y", "$(id)"], "flutter.flavor": "a;b"}');
      await s.load(path: global);
      s.openProject(root);
      expect(s.runArgs(), ['--ok']);
      expect(s.blockedRunArgs(), containsAll(['& calc', 'x|y', r'$(id)', '--flavor=a;b']));
    });
  });

  group('Dart settings', () {
    test('a project file wins over what older versions kept', () async {
      SharedPreferences.setMockInitialValues({
        'editor_dart_settings': '{"${p.normalize(root).replaceAll(r'\', r'\\')}": {"lineLength": 100, "showTodos": true}}',
      });
      await s.load(path: global);
      s.openProject(root);
      expect((await DartSettings.load(root)).lineLength, 100);
      projectFile().writeAsStringSync('{"dart.lineLength": 60, "dart.organizeImportsOnSave": true, "dart.documentation": "none"}');
      s.openProject(root);
      final dart = await DartSettings.load(root);
      expect((dart.lineLength, dart.showTodos, dart.organizeImportsOnSave), (60, true, true));
      expect(dart.toServerConfig(root)['documentation'], 'none');
    });

    test('the dialog saves changes in the project file, and only changes', () async {
      await s.load(path: global);
      s.openProject(root);
      await const DartSettings(lineLength: 120).save(root);
      expect(parseSettingsJson(projectFile().readAsStringSync()), {'dart.lineLength': 120});
    });
  });

  test('tidying on save', () {
    expect(tidyOnSave('a  \nb\t\r\n  c', trim: true, finalNewline: false), 'a\nb\r\n  c');
    expect(tidyOnSave('a', trim: false, finalNewline: true), 'a\n');
    expect(tidyOnSave('a\r\nb', trim: false, finalNewline: true), 'a\r\nb\r\n');
    expect(tidyOnSave('', trim: true, finalNewline: true), '');
    expect(tidyOnSave('a  \n', trim: false, finalNewline: false), 'a  \n');
  });

  test('the Output panel keeps commands and the log in the order they happened', () {
    // Five log lines, then a two-line command, then more log.
    List<(bool, int)> rows(int anchor, int tool, int log) => [for (var i = 0; i < tool + log; i++) outputRow(i, anchor, tool)];
    expect(rows(2, 2, 3), [(false, 0), (false, 1), (true, 0), (true, 1), (false, 2)]);
    expect(rows(3, 2, 3).last, (true, 1), reason: 'the command run last is at the end');
    expect(rows(0, 1, 1), [(true, 0), (false, 0)]);
  });

  test('what a new window was opened for', () {
    expect(startupProjectOf(const []), isNull);
    expect(startupProjectOf(const ['--title=x']), isNull);
    expect(startupProjectOf(const ['--project=']), '');
    expect(startupProjectOf(const ['--project=C:\\My Projects\\app']), 'C:\\My Projects\\app');
  });

  test('searching the Output panel', () {
    expect(matchesLogSearch('I/flutter: Payment failed', 'payment'), isTrue);
    expect(matchesLogSearch('I/flutter: Payment failed', 'failed flutter'), isTrue);
    expect(matchesLogSearch('I/flutter: Payment failed', 'refund'), isFalse);
    expect(matchesLogSearch('anything', '   '), isTrue);
    expect(matchesLogSearch('\x1B[31mError\x1B[0m here', 'error here'), isTrue);
    expect(matchesLogSearch('\x1B[31mError', '31m'), isFalse, reason: 'color codes are not text');
  });

  testWidgets('a status bar item shows it can be clicked, and one that cannot does not', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StatusBarItem(onTap: () => tapped++, child: const Text('main')),
              const StatusBarItem(onTap: null, child: Text('off')),
            ],
          ),
        ),
      ),
    );
    MouseCursor cursorOf(String text) => tester.widget<MouseRegion>(find.ancestor(of: find.text(text), matching: find.byType(MouseRegion)).first).cursor;
    expect(cursorOf('main'), SystemMouseCursors.click);
    expect(cursorOf('off'), isNot(SystemMouseCursors.click));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('main')));
    await tester.pump();
    final fill = (tester.widget<Container>(find.ancestor(of: find.text('main'), matching: find.byType(Container)).first).decoration! as BoxDecoration).color;
    expect(fill, isNot(Colors.transparent), reason: 'hover shows');

    await tester.tap(find.text('main'));
    expect(tapped, 1);
  });

  testWidgets('snackbars sit at the bottom right', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(appThemes.first),
        builder: snackBarsBottomRight,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hello'))),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);
    expect(bar.right, 1200 - 16);
    expect(bar.left, greaterThan(600));
    expect(bar.bottom, greaterThan(700));
  });
}
