import 'dart:io';

import 'package:hotrestart/modules/editor/code_pane.dart';
import 'package:hotrestart/modules/editor/dart_sdk.dart';
import 'package:hotrestart/modules/editor/editor_workspace.dart';
import 'package:hotrestart/modules/editor/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _source = r'''
/// Says hello to [name].
///
/// Uses `print` under the hood.
String greet(String name, {int times = 1}) => 'hi $name $times';

void main() {
  greet('x', times: 2);
  gre
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseMarkdown', () {
    test('splits a server hover into code, rule and paragraphs', () {
      final blocks = parseMarkdown('```dart\nvoid f(\n  int a)\n```\nType: `int`\n\n---\nFirst line\nsame paragraph.\n\n# Title\n* one\n- two\n1. three');
      expect(blocks.map((b) => b.kind), [
        MdKind.code,
        MdKind.paragraph,
        MdKind.rule,
        MdKind.paragraph,
        MdKind.heading,
        MdKind.bullet,
        MdKind.bullet,
        MdKind.bullet,
      ]);
      expect(blocks[0].text, 'void f(\n  int a)');
      expect(blocks[3].text, 'First line same paragraph.');
      expect(blocks[7].text, 'three');
    });

    test('an unclosed fence keeps its text', () {
      expect(parseMarkdown('```dart\nvoid f()').single.text, 'void f()');
    });
  });

  test('markdownInline keeps the words and drops the marks', () {
    final span = markdownInline(
      'Use `print`, **bold**, *soft*, [State] and [the docs](https://dart.dev). 2 * 3 stays.',
      accent: const Color(0xFF00FF00),
    );
    expect(span.toPlainText(), 'Use print, bold, soft, State and the docs. 2 * 3 stays.');
  });

  test('isDeclarationAt only matches the word the target points at', () {
    const text = '  String greet(String name) => name;';
    const target = EditTarget('a.dart', 3, 9);
    expect(isDeclarationAt(target, 'a.dart', 3, 11, text), isTrue);
    expect(isDeclarationAt(target, 'a.dart', 3, 4, text), isFalse);
    expect(isDeclarationAt(target, 'a.dart', 4, 11, text), isFalse);
    expect(isDeclarationAt(target, 'b.dart', 3, 11, text), isFalse);
  });

  test('clickableTokenAt skips what Ctrl+click can\'t follow', () {
    const tokens = [
      SemanticToken(0, 5, 'keyword', {}),
      SemanticToken(6, 11, 'class', {}),
      SemanticToken(12, 18, 'string', {}),
    ];
    expect(clickableTokenAt(tokens, 2), isNull);
    expect(clickableTokenAt(tokens, 8)!.type, 'class');
    expect(clickableTokenAt(tokens, 11), isNull);
    expect(clickableTokenAt(tokens, 13), isNull);
    expect(clickableTokenAt(null, 1), isNull);
  });

  test('isLibrarySource spots the SDK and the pub cache, not the project', () {
    expect(isLibrarySource(r'C:\Users\me\fvm\versions\3.47.5\packages\flutter\lib\src\widgets\framework.dart'), isTrue);
    expect(isLibrarySource(r'C:\Users\me\AppData\Local\Pub\Cache\hosted\pub.dev\a-1.0.0\lib\a.dart'), isTrue);
    expect(isLibrarySource('/home/me/.pub-cache/hosted/pub.dev/a-1.0.0/lib/a.dart'), isTrue);
    expect(isLibrarySource('/opt/flutter/bin/cache/pkg/sky_engine/lib/core/print.dart'), isTrue);
    expect(isLibrarySource(r'C:\Zota Projects\flutter-devkit\lib\main.dart'), isFalse);
  });

  test('signatureOf marks the active parameter', () {
    final s = SignatureInfo.fromLsp({
      'activeSignature': 0,
      'activeParameter': 1,
      'signatures': [
        {
          'label': 'greet(String name, {int times = 1})',
          'documentation': {'kind': 'markdown', 'value': 'Says hello.'},
          'parameters': [
            {'label': 'String name'},
            {'label': 'int times = 1'},
          ],
        },
      ],
    })!;
    expect(s.label.substring(s.activeStart, s.activeEnd), 'int times = 1');
    expect(s.documentation, 'Says hello.');
    expect(SignatureInfo.fromLsp(null), isNull);
    expect(SignatureInfo.fromLsp({'signatures': const []}), isNull);
  });

  group('real server', () {
    late Directory dir;
    late String main;
    late EditorWorkspace ws;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('intel');
      final sdk = flutterSdkOf(Directory.current.path)!;
      await Link(p.join(dir.path, '.fvm', 'flutter_sdk')).create(Directory(sdk).resolveSymbolicLinksSync(), recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\n');
      main = p.join(dir.path, 'lib', 'main.dart');
      File(main)
        ..createSync(recursive: true)
        ..writeAsStringSync(_source);
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

    test('the server offers snippets, and one inserts with its stops ready', () async {
      final file = p.join(dir.path, 'lib', 'snippets.dart');
      File(file).writeAsStringSync('void run() {\n  for\n}\n');
      final doc = await ws.open(file);
      // The first answer can come before the file's analysis is ready.
      var items = await ws.completion(doc, 1, 5);
      for (var i = 0; i < 20 && !items.any((c) => c.kind == 15); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        items = await ws.completion(doc, 1, 5);
      }
      final fori = items.firstWhere((c) => c.filter == 'for' && c.kind == 15);
      expect(fori.kind, 15);
      expect(fori.raw['insertTextFormat'], 2);
      final session = ws.applyCompletion(doc, await ws.resolveCompletion(doc, fori), line: 1, start: 2, end: 5);
      expect(session, isNotNull);
      final text = doc.controller.text;
      expect(text, contains('for (var i = 0; i < count; i++) {'));
      expect(text, isNot(contains(r'\$')));
      expect(text.split('\n')[2], startsWith('    '), reason: 'the body keeps the indent of the line it was typed on');
      expect(doc.controller.selectedText, 'count');
      expect(doc.controller.selection.isCollapsed, isFalse);
      expect(session!.move(1), isTrue);
      expect(session.active, isFalse);
      expect(doc.controller.selection.isCollapsed, isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('hover is Markdown, completion has docs, signature help tracks the argument', () async {
      final doc = await ws.open(main);
      final lines = doc.controller.text.split('\n');
      final call = lines.indexWhere((l) => l.contains("greet('x'"));

      final hover = (await ws.hover(doc, call, 3))!;
      expect(hover, contains('```dart'));
      expect(hover, contains('Says hello to'));
      expect(parseMarkdown(hover).any((b) => b.kind == MdKind.code), isTrue);

      final sig = await ws.signatureHelp(doc, call, lines[call].indexOf('times'));
      expect(sig!.label, contains('greet'));
      expect(sig.label.substring(sig.activeStart, sig.activeEnd), contains('times'));
      expect(sig.documentation, contains('Says hello'));

      final typed = lines.indexWhere((l) => l.trim() == 'gre');
      final items = await ws.completion(doc, typed, lines[typed].length);
      final greet = items.firstWhere((c) => c.label.startsWith('greet'));
      expect(greet.signature, contains('String'));
      final docs = await ws.documentationOf(doc, greet);
      expect(docs, contains('Says hello'));

      // The declaration resolves to itself, and its usages are one request away.
      final declared = lines.indexWhere((l) => l.startsWith('String greet'));
      final self = await ws.definition(doc, declared, 9);
      expect(self == null || isDeclarationAt(self, main, declared, 9, lines[declared]), isTrue);
      final refs = await ws.references(doc, declared, 9);
      expect(refs.map((r) => r.line), containsAll([declared, call]));
      final fromUsage = await ws.definition(doc, call, 3);
      expect(fromUsage!.line, declared);
      expect(isDeclarationAt(fromUsage, main, call, 3, lines[call]), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
