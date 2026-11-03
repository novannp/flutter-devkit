import 'dart:convert';
import 'dart:io';

import 'package:hotrestart/modules/editor/dart_sdk.dart';
import 'package:hotrestart/modules/editor/editor_workspace.dart';
import 'package:hotrestart/modules/editor/lsp_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LspFrameParser', () {
    List<int> frame(String json) => [...ascii.encode('Content-Length: ${utf8.encode(json).length}\r\n\r\n'), ...utf8.encode(json)];

    test('reassembles split chunks, multi-byte text and several messages', () {
      final bytes = [...frame('{"a":"é"}'), ...frame('{"b":2}')];
      final parser = LspFrameParser();
      expect(parser.add(bytes.sublist(0, 5)), isEmpty);
      expect(parser.add(bytes.sublist(5, 24)), isEmpty);
      expect(parser.add(bytes.sublist(24)), [
        {'a': 'é'},
        {'b': 2},
      ]);
    });
  });

  group('applyTextEdits', () {
    Map<String, dynamic> edit(int l1, int c1, int l2, int c2, String text) => {
      'range': {
        'start': {'line': l1, 'character': c1},
        'end': {'line': l2, 'character': c2},
      },
      'newText': text,
    };

    test('applies several edits against the original positions', () {
      expect(applyTextEdits('one\ntwo\nthree', [edit(0, 0, 0, 3, '1'), edit(2, 0, 2, 5, '3')]), '1\ntwo\n3');
    });

    test('keeps CRLF and same-position insert order', () {
      expect(applyTextEdits('a\r\nb', [edit(1, 0, 1, 0, 'x'), edit(1, 0, 1, 0, 'y')]), 'a\r\nxyb');
    });
  });

  test('filterCompletions ranks prefix over fuzzy and honours sort order', () {
    CompletionEntry e(String label, String sort) => CompletionEntry({'label': label, 'sortText': sort});
    final out = filterCompletions([e('setState', '2'), e('StatelessWidget', '3'), e('State', '1'), e('other', '0')], 'sta');
    expect(out.map((c) => c.label), ['State', 'StatelessWidget', 'setState']);
  });

  group('fvm', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('fvm'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('.fvmrc resolves through the fvm cache', () {
      File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter": "1.2.3"}');
      final cache = Directory(p.join(dir.path, 'cache', 'versions', '1.2.3'))..createSync(recursive: true);
      expect(projectUsesFvm(dir.path), isTrue);
      expect(flutterSdkOf(dir.path, environment: {'FVM_CACHE_PATH': p.join(dir.path, 'cache')}), cache.path);
    });

    test('a version not installed yet falls back to the fvm wrapper', () {
      File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter": "9.9.9"}');
      expect(flutterSdkOf(dir.path, environment: {'FVM_CACHE_PATH': dir.path}), isNull);
      expect(dartCommand(dir.path).exe, 'fvm');
    });

    test('no fvm means dart from PATH', () {
      expect(projectUsesFvm(dir.path), isFalse);
      expect(dartCommand(dir.path).exe, 'dart');
    });
  });

  test('this repo uses its fvm-pinned dart', () {
    final cmd = dartCommand(Directory.current.path);
    expect(cmd.exe, contains('flutter_sdk'));
    expect(File(cmd.exe).existsSync(), isTrue);
  });

  // The real analysis server, from this repo's SDK.
  group('language features', () {
    late Directory dir;
    late EditorWorkspace ws;
    late String main;

    Future<void> until(bool Function() ok, String what) async {
      for (var i = 0; i < 600 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(ok(), isTrue, reason: 'timed out waiting for $what');
    }

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('lsp');
      // The fvm link makes the project resolve to this repo's SDK.
      final sdk = flutterSdkOf(Directory.current.path)!;
      await Link(p.join(dir.path, '.fvm', 'flutter_sdk')).create(Directory(sdk).resolveSymbolicLinksSync(), recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\n');
      main = p.join(dir.path, 'lib', 'main.dart');
      File(main)
        ..createSync(recursive: true)
        ..writeAsStringSync('class Greeter {\n  String hello() => "hi";\n}\n\nvoid main() {\n  final g = Greeter();\n  int bad = g.hello();\n  print(bad);\n}\n');
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

    test('diagnostics, hover, definition, completion, format, rename, code actions', () async {
      final doc = await ws.open(main);
      await until(() => doc.diagnostics.isNotEmpty, 'diagnostics');
      final error = doc.diagnostics.firstWhere((d) => d.severity == 1);
      expect(error.line, 6);
      expect(error.message, contains('String'));
      expect(ws.countOf(1), 1);

      expect(await ws.hover(doc, 5, 12), contains('Greeter'));

      final target = await ws.definition(doc, 5, 12);
      expect(p.equals(target!.path, main), isTrue);
      expect(target.line, 0);

      final items = await ws.completion(doc, 6, 14);
      expect(items.map((c) => c.label), contains(startsWith('hello')));
      // An item from dart:core is offered, proving the SDK itself resolved.
      expect((await ws.completion(doc, 7, 2)).map((c) => c.label), contains(startsWith('print')));

      final refs = await ws.references(doc, 5, 12);
      expect(refs.length, greaterThanOrEqualTo(2));

      final actions = await ws.codeActions(doc, 6, 6);
      expect(actions, isNotEmpty);

      doc.replaceAll('void   main( ) {\n  final x=1;\n  print(x);\n}\n');
      await ws.format(doc);
      expect(doc.controller.text, 'void main() {\n  final x = 1;\n  print(x);\n}\n');

      await ws.rename(doc, 1, 8, 'renamed');
      expect(doc.controller.text, contains('final renamed = 1;'));
      expect(doc.controller.text, contains('print(renamed);'));

      expect(doc.dirty, isTrue);
      await ws.save(doc);
      expect(doc.dirty, isFalse);
      expect(File(main).readAsStringSync(), contains('renamed'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('EditorDocument', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('doc'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps CRLF and the final newline through a save', () async {
      final f = File(p.join(dir.path, 'a.txt'))..writeAsStringSync('one\r\ntwo\r\n');
      final doc = await EditorDocument.open(f.path);
      expect(doc.dirty, isFalse);
      doc.replaceAll('${doc.controller.text}three\r\n');
      await doc.save();
      expect(f.readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
      doc.dispose();
    });

    test('opens what is not text as a preview', () async {
      final zeros = File(p.join(dir.path, 'a.bin'))..writeAsBytesSync([1, 0, 2]);
      final latin = File(p.join(dir.path, 'b.txt'))..writeAsBytesSync([0xE9, 0xE8]);
      for (final file in [zeros, latin]) {
        final doc = await EditorDocument.open(file.path);
        addTearDown(doc.dispose);
        expect(doc.binary, isTrue);
        expect(doc.dirty, isFalse);
      }
    });

    test('follows outside edits, but never over unsaved work', () async {
      final f = File(p.join(dir.path, 'a.txt'))..writeAsStringSync('v1');
      final doc = await EditorDocument.open(f.path);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      f.writeAsStringSync('v2');
      f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      expect(await doc.reloadIfChanged(), isTrue);
      expect(doc.controller.text, 'v2');

      doc.replaceAll('mine');
      f.writeAsStringSync('v3');
      f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 10)));
      expect(await doc.reloadIfChanged(), isFalse);
      expect(doc.controller.text, 'mine');
      expect(doc.changedOnDisk, isTrue);
      doc.dispose();
    });
  });

  test('search and quick open leave out what git ignores, and .history', () async {
    final dir = Directory.systemTemp.createTempSync('ignored');
    addTearDown(() => dir.deleteSync(recursive: true));
    await Process.run('git', ['init', '-q'], workingDirectory: dir.path);
    File(p.join(dir.path, '.gitignore')).writeAsStringSync('secret/\n*.gen.dart\n');
    for (final f in ['lib/a.dart', 'lib/b.gen.dart', 'secret/c.dart', '.history/lib/d.dart']) {
      File(p.join(dir.path, f))
        ..createSync(recursive: true)
        ..writeAsStringSync('FIND');
    }
    expect((await searchInFiles(dir.path, 'FIND')).map((h) => p.basename(h.path)), ['a.dart']);
    expect((await listProjectFiles(dir.path)).map(p.basename), unorderedEquals(['.gitignore', 'a.dart']));
  });

  test('searchInFiles skips generated folders', () async {
    final dir = await Directory.systemTemp.createTemp('search');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x\nfind Me\n');
    File(p.join(dir.path, 'build', 'b.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('find me\n');
    final hits = await searchInFiles(dir.path, 'FIND');
    expect(hits.single.line, 1);
    expect(p.basename(hits.single.path), 'a.dart');
    expect(await listProjectFiles(dir.path), [p.join(dir.path, 'lib', 'a.dart')]);
  });
}
