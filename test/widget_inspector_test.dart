import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:devkit/core/child_processes.dart';
import 'package:devkit/modules/editor/dart_sdk.dart';
import 'package:devkit/modules/editor/debugger.dart';
import 'package:devkit/modules/editor/widget_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _app = r'''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: Scaffold(body: Text('hello inspector')));
}
''';

void main() {
  final file = Platform.isWindows ? 'file:///C:/app/lib/main.dart' : 'file:///app/lib/main.dart';
  final json = {
    'valueId': 'a',
    'widgetRuntimeType': 'MyApp',
    'description': 'MyApp',
    'creationLocation': {'file': file, 'line': 12, 'column': 5},
    'children': [
      {
        'valueId': 'b',
        'description': 'Scaffold',
        'children': [
          {'valueId': 'c', 'widgetRuntimeType': 'Text', 'description': 'Text("hi")'},
        ],
      },
      {'valueId': 'd', 'widgetRuntimeType': 'Spacer', 'description': 'Spacer'},
    ],
  };

  test('reads a node from what the framework sends', () {
    final node = InspectorNode.fromJson(json);
    expect(node.type, 'MyApp');
    expect(node.path, Uri.parse(file).toFilePath());
    expect((node.line, node.column), (12, 5));
    expect(node.children.first.type, 'Scaffold', reason: 'falls back to the description');
    expect(node.children.first.path, isNull);
  });

  test('flattens depth first and skips what a collapsed node hides', () {
    final root = InspectorNode.fromJson(json);
    List<(String, int)> shown(Set<String?> collapsed) => [for (final (n, d) in flattenTree(root, collapsed)) (n.type, d)];
    expect(shown({}), [('MyApp', 0), ('Scaffold', 1), ('Text', 2), ('Spacer', 1)]);
    expect(shown({'b'}), [('MyApp', 0), ('Scaffold', 1), ('Spacer', 1)]);
    expect(flattenTree(null, {}), isEmpty);
  });

  test('reads a real running app, and lets go when it stops', () async {
    // The VM reports real paths, and macOS keeps its temp folder behind a symlink.
    final dir = Directory((await Directory.systemTemp.createTemp('inspect')).resolveSymbolicLinksSync());
    addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  flutter:\n    sdk: flutter\nflutter:\n  uses-material-design: true\n');
    final main = p.join(dir.path, 'lib', 'main.dart');
    File(main)
      ..createSync(recursive: true)
      ..writeAsStringSync(_app);
    final sdk = Directory(flutterSdkOf(Directory.current.path)!).resolveSymbolicLinksSync();
    final process = await Process.start(
      p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
      ['--show-test-device', 'run', '--machine', '-d', 'flutter-tester'],
      workingDirectory: dir.path,
      runInShell: Platform.isWindows,
    );
    String? appId;
    addTearDown(() async {
      // Killing the wrapper alone leaves flutter_tester running.
      process.stdin.writeln(jsonEncode([
        {'id': 1, 'method': 'app.stop', 'params': {'appId': appId}},
      ]));
      await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => -1);
      await ChildProcesses.killTree(process);
    });
    process.stderr.drain<void>();
    final ws = Completer<String>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      appId ??= RegExp(r'"appId":"([^"]+)"').firstMatch(l)?[1];
      final m = RegExp(r'"wsUri":"(ws://[^"]+)"').firstMatch(l);
      if (m != null && !ws.isCompleted) ws.complete(m[1]!);
    });
    final debugger = Debugger();
    await debugger.connect(await ws.future.timeout(const Duration(minutes: 3)), dir.path);
    final inspector = WidgetTreeInspector(debugger);
    addTearDown(inspector.dispose);
    for (var i = 0; i < 40 && inspector.root == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await inspector.refresh();
    }
    expect(inspector.error, isNull);
    final nodes = [for (final (n, _) in flattenTree(inspector.root, {})) n];
    expect(nodes.map((n) => n.type), containsAllInOrder(['MyApp', 'MaterialApp', 'Scaffold', 'Text']));

    final mine = nodes.firstWhere((n) => n.type == 'MyApp');
    expect(p.equals(mine.path!, main), isTrue);
    await inspector.select(nodes.firstWhere((n) => n.type == 'Text'));
    expect(inspector.properties, contains(('data', '"hello inspector"')));

    await inspector.toggleSelectMode();
    expect(inspector.selectMode, isTrue);
    await inspector.toggleDebugPaint();
    expect(inspector.debugPaint, isTrue);

    await debugger.disconnect();
    expect(inspector.root, isNull);
    expect(inspector.selectMode, isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
