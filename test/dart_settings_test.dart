import 'dart:io';

import 'package:hotrestart/modules/editor/code_pane.dart';
import 'package:hotrestart/modules/editor/dart_sdk.dart';
import 'package:hotrestart/modules/editor/dart_settings.dart';
import 'package:hotrestart/modules/editor/editor_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _longCall = 'void main() {\n  print(["aaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccc"]);\n}\n\nclass Greeter {\n  String hello(int count) => "hi";\n}\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('projectPageWidth reads analysis_options.yaml', () {
    final dir = Directory.systemTemp.createTempSync('pw');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(projectPageWidth(dir.path), isNull);
    File(p.join(dir.path, 'analysis_options.yaml')).writeAsStringSync('linter:\n  rules: []\nformatter:\n  trailing_commas: preserve\n  page_width: 120\n');
    expect(projectPageWidth(dir.path), 120);
    expect(const DartSettings(lineLength: 100).toServerConfig(dir.path).containsKey('lineLength'), isFalse);
  });

  test('pub get on save is on unless turned off, and survives a save', () {
    expect(const DartSettings().pubGetOnSave, isTrue);
    expect(DartSettings.fromJson(const {}).pubGetOnSave, isTrue, reason: 'settings saved before it existed');
    expect(DartSettings.fromJson(const DartSettings(pubGetOnSave: false).toJson()).pubGetOnSave, isFalse);
  });

  test('settings are kept per project', () async {
    SharedPreferences.setMockInitialValues({});
    await const DartSettings(lineLength: 120, showTodos: true, excludedFolders: ['build']).save('C:/a');
    final a = await DartSettings.load('C:/a');
    expect(a.lineLength, 120);
    expect(a.showTodos, isTrue);
    expect(a.excludedFolders, ['build']);
    expect((await DartSettings.load('C:/b')).lineLength, isNull);
  });

  test('decodeSemanticTokens turns the relative encoding into line ranges', () {
    final lines = decodeSemanticTokens([1, 2, 3, 0, 0, 0, 5, 4, 1, 1, 2, 0, 2, 0, 0], ['class', 'keyword'], ['static']);
    expect(lines.keys, [1, 3]);
    expect(lines[1]![0].start, 2);
    expect(lines[1]![0].end, 5);
    expect(lines[1]![0].type, 'class');
    expect(lines[1]![1].start, 7);
    expect(lines[1]![1].type, 'keyword');
    expect(lines[1]![1].modifiers, {'static'});
    expect(lines[3]![0].end, 2);
  });

  test('semanticColor tells kinds apart in both themes, and leaves interpolation to its parts', () {
    for (final b in Brightness.values) {
      final type = semanticColor('class', const {}, b);
      final fn = semanticColor('method', const {}, b);
      final variable = semanticColor('parameter', const {}, b);
      expect({type, fn, variable}.length, 3);
      expect(semanticColor('keyword', const {'control'}, b), isNot(semanticColor('keyword', const {}, b)));
    }
    expect(semanticColor('source', const {}, Brightness.dark), isNull);
  });

  test('colorRanges splits spans and keeps the text', () {
    const red = Color(0xFFFF0000);
    const span = TextSpan(children: [TextSpan(text: 'int '), TextSpan(text: 'value')]);
    final out = colorRanges(span, [(4, 9, red)]);
    expect(out.toPlainText(), 'int value');
    final colored = <String>[];
    out.visitChildren((s) {
      if (s is TextSpan && s.text != null && s.style?.color == red) colored.add(s.text!);
      return true;
    });
    expect(colored.join(), 'value');
  });

  group('real server', () {
    late Directory dir;
    late String main;
    late EditorWorkspace ws;

    Future<void> until(bool Function() ok, String what) async {
      for (var i = 0; i < 600 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(ok(), isTrue, reason: 'timed out waiting for $what');
    }

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('settings');
      final sdk = flutterSdkOf(Directory.current.path)!;
      await Link(p.join(dir.path, '.fvm', 'flutter_sdk')).create(Directory(sdk).resolveSymbolicLinksSync(), recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\n');
      main = p.join(dir.path, 'lib', 'main.dart');
      File(main)
        ..createSync(recursive: true)
        ..writeAsStringSync(_longCall);
      ws = EditorWorkspace(dir.path);
    });

    tearDownAll(() async {
      ws.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // The server may still hold a handle for a moment; it's a temp folder.
      }
    });

    test('line length reaches the formatter, and semantic tokens color the code', () async {
      final doc = await ws.open(main);
      await until(() => doc.semantics.isNotEmpty, 'semantic tokens');
      final classLine = doc.controller.text.split('\n').indexWhere((l) => l.startsWith('class Greeter'));
      expect(doc.semantics[classLine]!.map((t) => t.type), containsAll(['keyword', 'class']));
      final methodLine = classLine + 1;
      expect(doc.semantics[methodLine]!.map((t) => t.type), containsAll(['class', 'method', 'parameter']));

      await ws.format(doc);
      expect(doc.controller.text, contains('\n    "aaaaaaaaaaaaaaaaaaaaaaaaaaa",\n'), reason: 'the default 80 splits this call');

      doc.replaceAll(_longCall);
      await ws.applyDartSettings(const DartSettings(lineLength: 120));
      await until(() => ws.dart.lineLength == 120, 'the setting');
      // The server fetches the new configuration by itself, so give it a moment.
      for (var i = 0; i < 100; i++) {
        await ws.format(doc);
        if (doc.controller.text.contains('  print(["aaaa')) break;
        doc.replaceAll(_longCall);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(doc.controller.text, contains('  print(["aaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "cccccccccccccccccccccc"]);'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
