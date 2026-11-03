import 'dart:io';

import 'package:devkit/core/theme.dart';
import 'package:devkit/extensions/registry.dart';
import 'package:devkit/modules/editor/brackets.dart';
import 'package:devkit/modules/editor/breadcrumbs.dart';
import 'package:devkit/modules/editor/dart_sdk.dart';
import 'package:devkit/modules/editor/editor_view.dart';
import 'package:devkit/modules/editor/editor_workspace.dart';
import 'package:devkit/modules/editor/log_style.dart';
import 'package:devkit/modules/editor/notices.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:devkit/modules/editor/editor_page.dart';
import 'package:devkit/modules/editor/tool_tabs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _source = '''
class Greeter {
  String hello(int count) {
    final greeting = 'hi';
    return greeting;
  }
}

void main() {}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('symbols', () {
    DocSymbol sym(String name, int start, int end, [List<DocSymbol> children = const []]) =>
        DocSymbol(name, 5, start, 0, end, 99, start, 0, children);
    final tree = [
      sym('A', 0, 5, [sym('one', 1, 2), sym('two', 3, 4)]),
      sym('B', 7, 9),
    ];

    test('symbolChainAt walks down to the innermost symbol', () {
      expect(symbolChainAt(tree, 3, 2).map((s) => s.name), ['A', 'two']);
      expect(symbolChainAt(tree, 5, 2).map((s) => s.name), ['A']);
      expect(symbolChainAt(tree, 6, 0), isEmpty);
      expect(symbolChainAt(tree, 8, 0).map((s) => s.name), ['B']);
    });

    test('DocSymbol.fromLsp reads the hierarchical shape', () {
      Map<String, dynamic> pos(int l, int c) => {'line': l, 'character': c};
      final s = DocSymbol.fromLsp({
        'name': 'A',
        'kind': 5,
        'range': {'start': pos(0, 0), 'end': pos(4, 1)},
        'selectionRange': {'start': pos(0, 6), 'end': pos(0, 7)},
        'children': [
          {
            'name': 'b',
            'kind': 6,
            'range': {'start': pos(1, 2), 'end': pos(2, 3)},
            'selectionRange': {'start': pos(1, 7), 'end': pos(1, 8)},
          },
        ],
      });
      expect(s.column, 6);
      expect(s.endLine, 4);
      expect(s.children.single.name, 'b');
      expect(s.children.single.line, 1);
    });
  });

  test('sdkVersionsOf reports this project\'s pinned SDK', () async {
    final v = (await sdkVersionsOf(Directory.current.path))!;
    expect(v.flutter, matches(RegExp(r'^\d+\.\d+\.\d+')));
    expect(v.dart, matches(RegExp(r'^\d+\.\d+\.\d+')));
    expect(v.dart, isNot(contains('build')));
  });

  test('editor groups: reorder, split, move, and an emptied group goes away', () async {
    final dir = await Directory.systemTemp.createTemp('groups');
    addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
    Future<String> file(String name) async {
      final path = p.join(dir.path, name);
      await File(path).writeAsString(name);
      return path;
    }

    final ws = EditorWorkspace(dir.path);
    addTearDown(ws.dispose);
    final a = await ws.open(await file('a.txt'));
    final b = await ws.open(await file('b.txt'));
    final c = await ws.open(await file('c.txt'));
    final first = ws.groups.single;
    expect(first.docs, [a, b, c]);

    ws.moveTab(first, 0, 2);
    expect(first.docs, [b, c, a]);
    ws.moveTab(first, 2, 0);
    expect(first.docs, [a, b, c]);

    ws.moveToGroup(c, null);
    expect(ws.groups.length, 2);
    final second = ws.groups[1];
    expect(second.docs, [c]);
    expect(ws.active, c);
    expect(first.active, b);

    // Already open elsewhere: the file's own view comes forward, it doesn't open twice.
    await ws.open(a.path);
    expect(ws.focused, first);
    expect(ws.documents.length, 3);

    ws.moveToGroup(b, null);
    expect(ws.groups.length, 3);
    ws.moveToGroup(b, second);
    expect(ws.groups.length, 2);
    expect(second.docs, [c, b]);

    await ws.close(c);
    await ws.close(b);
    expect(ws.groups, [first]);
    expect(ws.focused, first);

    // A single tab has nothing to split from.
    ws.moveToGroup(a, null);
    expect(ws.groups.length, 1);
  });

  test('zoom stays in range, word wrap toggles, both survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await EditorView.load();
    expect(EditorView.fontSize.value, EditorView.defaultFontSize);
    await EditorView.zoom(2);
    expect(EditorView.fontSize.value, EditorView.defaultFontSize + 2);
    await EditorView.zoom(100);
    expect(EditorView.fontSize.value, EditorView.maxFontSize);
    await EditorView.zoom(-100);
    expect(EditorView.fontSize.value, EditorView.minFontSize);
    await EditorView.zoom(1);
    await EditorView.toggleWordWrap();
    final size = EditorView.fontSize.value;
    EditorView.fontSize.value = 1;
    EditorView.wordWrap.value = false;
    await EditorView.load();
    expect(EditorView.fontSize.value, size);
    expect(EditorView.wordWrap.value, isTrue);
    await EditorView.resetZoom();
    await EditorView.toggleWordWrap();
    expect(EditorView.fontSize.value, EditorView.defaultFontSize);
  });

  test('appVersion matches pubspec.yaml', () {
    final version = RegExp(r'^version: ([0-9.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(appVersion, version);
  });

  test('folderEntries lists folders first, by name, without .git', () async {
    final dir = await Directory.systemTemp.createTemp('crumbs');
    addTearDown(() => dir.delete(recursive: true));
    await Directory(p.join(dir.path, 'zeta')).create();
    await Directory(p.join(dir.path, 'Alpha')).create();
    await Directory(p.join(dir.path, '.git')).create();
    await File(p.join(dir.path, 'b.dart')).writeAsString('');
    await File(p.join(dir.path, 'A.dart')).writeAsString('');
    expect(folderEntries(dir.path).map((e) => p.basename(e.path)), ['Alpha', 'zeta', 'A.dart', 'b.dart']);
    expect(folderEntries(p.join(dir.path, 'missing')), isEmpty);
  });

  test('ProjectTabs keeps each project apart', () async {
    SharedPreferences.setMockInitialValues({});
    final a = p.join(Directory.systemTemp.path, 'a'), b = p.join(Directory.systemTemp.path, 'b');
    expect(await ProjectTabs.load(a), isNull);
    await const ProjectTabs(['1.dart', '2.dart'], '2.dart').save(a);
    await const ProjectTabs(['3.dart'], null).save(b);
    final loaded = (await ProjectTabs.load(a))!;
    expect(loaded.files, ['1.dart', '2.dart']);
    expect(loaded.active, '2.dart');
    expect((await ProjectTabs.load(b))!.files, ['3.dart']);
    expect((await ProjectTabs.load('$a${Platform.pathSeparator}'))!.files, ['1.dart', '2.dart'], reason: 'same folder, however it is written');
  });

  test('only the project\'s own pubspec.yaml counts as saved', () {
    final root = Directory.systemTemp.path;
    expect(isProjectPubspec(p.join(root, 'pubspec.yaml'), root), isTrue);
    expect(isProjectPubspec(p.join(root, 'packages', 'a', 'pubspec.yaml'), root), isFalse);
    expect(isProjectPubspec(p.join(root, 'lib', 'main.dart'), root), isFalse);
  });

  test('packagesOutOfSyncSince compares pubspec with what pub get left', () async {
    final dir = await Directory.systemTemp.createTemp('pkg');
    addTearDown(() => dir.delete(recursive: true));
    expect(packagesOutOfSyncSince(dir.path), isNull, reason: 'not a Dart project');
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'))..writeAsStringSync('name: a');
    expect(packagesOutOfSyncSince(dir.path), isNotNull, reason: 'never fetched');
    final config = File(p.join(dir.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final now = DateTime.now();
    pubspec.setLastModifiedSync(now.subtract(const Duration(minutes: 5)));
    config.setLastModifiedSync(now.subtract(const Duration(minutes: 1)));
    expect(packagesOutOfSyncSince(dir.path), isNull, reason: 'fetched since');
    pubspec.setLastModifiedSync(now);
    expect(packagesOutOfSyncSince(dir.path), isNotNull, reason: 'edited since');
    pubspec.setLastModifiedSync(now.subtract(const Duration(minutes: 5)));
    File(p.join(dir.path, 'pubspec.lock')).writeAsStringSync('');
    expect(packagesOutOfSyncSince(dir.path), isNotNull, reason: 'the lock changed, as with a pull');
  });

  group('output log', () {
    test('levelOf reads the wording of plain tool output', () {
      expect(levelOf('E/AndroidRuntime: FATAL EXCEPTION: main'), LogLevel.error);
      expect(levelOf('Exception: Null check operator'), LogLevel.error);
      expect(levelOf('#0      main (package:app/main.dart:3:1)'), LogLevel.error);
      expect(levelOf('W/ActivityThread: slow'), LogLevel.warning);
      expect(levelOf('warning: unused import'), LogLevel.warning);
      expect(levelOf('✓ Built build/app.apk'), LogLevel.success);
      expect(levelOf('D/EGL: swap'), LogLevel.debug);
      expect(levelOf('I/flutter: hello'), LogLevel.plain);
    });

    test('ansiSpan colors the text and hides the codes', () {
      const base = TextStyle(color: Color(0xFF000001));
      final span = ansiSpan('a\x1b[31mred\x1b[0m b\x1b[1;32mgreen\x1b[39m\x1b[2Kx', base);
      expect(span.toPlainText(), 'ared b' 'green' '\x1b[2Kx');
      final kids = span.children!.cast<TextSpan>();
      expect(kids[0].style!.color, base.color);
      expect(kids[1].style!.color, const Color(0xFFEF4444));
      expect(kids[2].style!.color, base.color);
      expect(kids[3].style!.color, const Color(0xFF22C55E));
      expect(kids[3].style!.fontWeight, FontWeight.w700);
      expect(ansiSpan('plain', base).toPlainText(), 'plain');
    });
  });

  test('recents forget the single files older versions saved', () async {
    final dir = Directory.systemTemp.createTempSync('recents');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'a.dart'))..writeAsStringSync('');
    SharedPreferences.setMockInitialValues({'editor_recents': [dir.path, file.path]});
    await RecentPaths.load();
    expect(RecentPaths.paths.value, [dir.path]);
  });

  test('recents put the newest first, drop repeats and stay short', () async {
    SharedPreferences.setMockInitialValues({});
    await RecentPaths.load();
    expect(RecentPaths.paths.value, isEmpty);
    await RecentPaths.add(r'C:\a');
    await RecentPaths.add(r'C:\b\f.dart');
    await RecentPaths.add(r'c:\A');
    expect(RecentPaths.paths.value, [r'c:\A', r'C:\b\f.dart']);
    for (var i = 0; i < 30; i++) {
      await RecentPaths.add('C:\\p$i');
    }
    expect(RecentPaths.paths.value.length, RecentPaths.limit);
    expect(RecentPaths.paths.value.first, r'C:\p29');
    RecentPaths.paths.value = const [];
    await RecentPaths.load();
    expect(RecentPaths.paths.value.length, RecentPaths.limit);
    await RecentPaths.clear();
    expect(RecentPaths.paths.value, isEmpty);
  });

  group('brackets', () {
    test('pairs nest and cross lines', () {
      final pairs = bracketPairs(['void f(int a) {', '  g([a]);', '}']);
      expect(pairs[(0, 6)], (0, 12));
      expect(pairs[(0, 14)], (2, 0));
      expect(pairs[(2, 0)], (0, 14));
      expect(pairs[(1, 3)], (1, 7));
      expect(pairs[(1, 4)], (1, 6));
    });

    test('strings and comments do not count', () {
      final pairs = bracketPairs([
        "f('(', \")\", r'\\', '\\'(');",
        '// (',
        '/* { /* [ */ ( */ g();',
        "final s = '''",
        '  ( { [',
        "''';",
      ]);
      expect(pairs[(0, 1)], (0, "f('(', \")\", r'\\', '\\'('".length));
      expect(pairs.keys.where((k) => k.$1 == 1 || k.$1 == 4), isEmpty);
      expect(pairs[(2, '/* { /* [ */ ( */ g'.length)], (2, '/* { /* [ */ ( */ g('.length));
      expect(pairs.length, 4);
    });

    test('a stray closer does not break what surrounds it', () {
      final pairs = bracketPairs(['( ] )']);
      expect(pairs[(0, 0)], (0, 4));
      expect(pairs.containsKey((0, 2)), isFalse);
    });

    test('pairAtCaret takes the bracket after the caret, then the one before', () {
      final pairs = bracketPairs(['(a)(b)']);
      expect(pairAtCaret(pairs, 0, 0), ((0, 0), (0, 2)));
      expect(pairAtCaret(pairs, 0, 3), ((0, 3), (0, 5)));
      expect(pairAtCaret(pairs, 0, 6), ((0, 5), (0, 3)));
      expect(pairAtCaret(pairs, 0, 1), ((0, 0), (0, 2)));
    });
  });

  group('themes', () {
    test('ids are unique and every theme builds', () {
      expect(appThemes.map((t) => t.id).toSet().length, appThemes.length);
      expect(appThemes.length, greaterThanOrEqualTo(10));
      for (final t in appThemes) {
        final theme = buildTheme(t);
        expect(theme.brightness, t.brightness, reason: t.id);
        expect(theme.colorScheme.primary, t.primary, reason: t.id);
      }
    });

    test('the code stays readable on every theme', () {
      double contrast(Color a, Color b) {
        final (x, y) = (a.computeLuminance() + .05, b.computeLuminance() + .05);
        return x > y ? x / y : y / x;
      }

      for (final t in appThemes) {
        final s = t.syntax;
        for (final (name, color) in [
          ('type', s.type),
          ('function', s.function),
          ('variable', s.variable),
          ('keyword', s.keyword),
          ('string', s.string),
        ]) {
          expect(contrast(color, t.surface), greaterThan(3), reason: '${t.id} $name');
        }
      }
    });

    test('an old dark mode choice carries over, and the pick is remembered', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      await loadAppTheme();
      expect(appTheme.value.id, 'devkit-dark');
      await setAppTheme(appThemes.firstWhere((t) => t.id == 'nord'));
      appTheme.value = appThemes.first;
      await loadAppTheme();
      expect(appTheme.value.id, 'nord');
      appTheme.value = appThemes.first;
    });
  });

  group('extensions', () {
    test('ids are unique, and everything starts enabled', () async {
      SharedPreferences.setMockInitialValues({});
      expect(builtinExtensions.map((e) => e.id).toSet().length, builtinExtensions.length);
      await ExtensionManager.instance.load();
      for (final e in builtinExtensions) {
        expect(ExtensionManager.instance.isEnabled(e.id), isTrue, reason: e.id);
      }
    });

    test('the choice survives a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final notes = builtinExtensions.firstWhere((e) => e.id == 'notes');
      await ExtensionManager.instance.load();
      await ExtensionManager.instance.setEnabled(notes, false);
      expect(ExtensionManager.instance.isEnabled('notes'), isFalse);
      await ExtensionManager.instance.load();
      expect(ExtensionManager.instance.isEnabled('notes'), isFalse);
      await ExtensionManager.instance.setEnabled(notes, true);
      expect(ExtensionManager.instance.isEnabled('notes'), isTrue);
    });

    test('a turned off extension gets its stop hook', () async {
      SharedPreferences.setMockInitialValues({});
      var stopped = 0, started = 0;
      final e = BuiltinExtension(
        id: 'probe',
        name: 'Probe',
        description: '',
        icon: builtinExtensions.first.icon,
        menu: 'Tools',
        modules: const [],
        onDisable: () async => stopped++,
        onEnable: () async => started++,
      );
      await ExtensionManager.instance.load();
      await ExtensionManager.instance.setEnabled(e, false);
      await ExtensionManager.instance.setEnabled(e, false);
      await ExtensionManager.instance.setEnabled(e, true);
      expect((stopped, started), (1, 1));
    });
  });

  test('the real server gives symbols for the breadcrumb', () async {
    final dir = await Directory.systemTemp.createTemp('crumb');
    final sdk = flutterSdkOf(Directory.current.path)!;
    await Link(p.join(dir.path, '.fvm', 'flutter_sdk')).create(Directory(sdk).resolveSymbolicLinksSync(), recursive: true);
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\n');
    final main = p.join(dir.path, 'lib', 'main.dart');
    File(main)
      ..createSync(recursive: true)
      ..writeAsStringSync(_source);
    File(p.join(dir.path, 'lib', 'second.dart')).writeAsStringSync('class Second {}\n');
    final ws = EditorWorkspace(dir.path);
    addTearDown(() async {
      ws.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      await dir.delete(recursive: true).catchError((_) => dir);
    });
    final doc = await ws.open(main);
    expect(ws.startingAnalyzer, isTrue, reason: 'says so while the server comes up');
    for (var i = 0; i < 300 && doc.symbols.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ws.startingAnalyzer, isFalse);

    // A second file opened after analysis settled still gets its colors.
    final second = await ws.open(main.replaceFirst('main.dart', 'second.dart'));
    for (var i = 0; i < 100 && second.semantics.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(second.semantics, isNotEmpty);
    final line = _source.split('\n').indexWhere((l) => l.contains('final greeting'));
    expect(symbolChainAt(doc.symbols, line, 6).map((s) => s.name), containsAllInOrder(['Greeter', 'hello']));
    expect(doc.symbols.map((s) => s.name), containsAll(['Greeter', 'main']));
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('dragging tabs', () {
    late Directory dir;
    late EditorWorkspace ws;
    late EditorDocument a, b, c;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('tabs');
      for (final name in ['a', 'b', 'c']) {
        File(p.join(dir.path, '$name.txt')).writeAsStringSync(name);
      }
      ws = EditorWorkspace(dir.path);
      a = await ws.open(p.join(dir.path, 'a.txt'));
      b = await ws.open(p.join(dir.path, 'b.txt'));
      c = await ws.open(p.join(dir.path, 'c.txt'));
    });
    tearDown(() {
      ws.dispose();
      dir.deleteSync(recursive: true);
    });

    test('along the strip, to before the tab it lands on', () {
      final g = ws.groups.single;
      ws.placeTab(c, g, 0);
      expect(g.docs, [c, a, b]);
      ws.placeTab(c, g, 2);
      expect(g.docs, [a, c, b]);
      ws.placeTab(a, g, 3);
      expect(g.docs, [c, b, a]);
    });

    test('to an edge splits on that side', () {
      final first = ws.groups.single;
      ws.splitBeside(b, first, right: true);
      expect(ws.groups.length, 2);
      expect(ws.groups.last.docs, [b]);
      expect(ws.focused, ws.groups.last);
      ws.splitBeside(c, first, right: false);
      expect(ws.groups.length, 3);
      expect(ws.groups.first.docs, [c]);
      expect(ws.groups[1].docs, [a]);
    });

    test('a view keeps its only tab, unless it goes elsewhere', () {
      final first = ws.groups.single;
      ws.splitBeside(b, first, right: true);
      ws.splitBeside(c, first, right: true);
      ws.splitBeside(a, first, right: true);
      expect(first.docs, [a]);
      expect(ws.groups.length, 3);
      ws.splitBeside(a, ws.groups.last, right: true);
      expect(ws.groups.length, 3, reason: 'its old view closes');
      expect(ws.groups.any((g) => g.docs.isEmpty), isFalse);
    });

    test('between views, at a place', () {
      final first = ws.groups.single;
      ws.splitBeside(c, first, right: true);
      ws.placeTab(a, ws.groups.last, 0);
      expect(ws.groups.last.docs, [a, c]);
      expect(ws.groups.first.docs, [b]);
    });
  });

  test('where a dragged tab lands', () {
    expect(tabDropZone(10, 100), TabDropZone.left);
    expect(tabDropZone(50, 100), TabDropZone.center);
    expect(tabDropZone(90, 100), TabDropZone.right);
  });

  test('the Editor tab moves like the others, and stays put when others close', () {
    final tabs = ToolTabs.instance;
    const one = AppModule('One', Icons.abc, SizedBox()), two = AppModule('Two', Icons.abc, SizedBox());
    addTearDown(() {
      tabs.close(one);
      tabs.close(two);
      tabs.editorAt = 0;
    });
    tabs.show(one);
    tabs.show(two);
    expect(tabs.strip, [null, one, two]);
    tabs.move(0, 2);
    expect(tabs.strip, [one, two, null]);
    tabs.move(1, 0);
    expect(tabs.strip, [two, one, null]);
    tabs.close(two);
    expect(tabs.strip, [one, null]);
  });
}
