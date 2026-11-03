import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotrestart/modules/editor/dart_sdk.dart';
import 'package:hotrestart/modules/editor/debugger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;

const _script = r'''
int add(int a, int b) {
  final sum = a + b;
  return sum;
}

void main() {
  final names = ['x', 'y'];
  final total = add(2, 3);
  try {
    throw 'boom';
  } catch (_) {}
  print('$names $total');
}
''';

void main() {
  group('uri mapping', () {
    final root = p.join(Directory.systemTemp.path, 'app');

    test('lib files use package URIs, others use file URIs', () {
      final file = p.join(root, 'lib', 'src', 'a.dart');
      expect(scriptUriOf(root, 'app', file), 'package:app/src/a.dart');
      expect(localPathOf(root, 'app', 'package:app/src/a.dart'), file);
      final tool = p.join(root, 'tool', 'b.dart');
      expect(localPathOf(root, 'app', scriptUriOf(root, 'app', tool)), tool);
    });

    test('other packages stay unresolved', () {
      expect(localPathOf(root, 'app', 'package:flutter/material.dart'), isNull);
      expect(localPathOf(root, 'app', 'dart:core/list.dart'), isNull);
    });
  });

  group('shiftLines', () {
    test('Enter at a line end moves only the lines below', () {
      expect(shiftLines({5, 6}, cursor: 6, delta: 1, atLineStart: false), {5, 7});
    });

    test('Enter at a line start moves that line too', () {
      expect(shiftLines({5}, cursor: 6, delta: 1, atLineStart: true), {6});
    });

    test('a paste moves everything below it', () {
      expect(shiftLines({5, 6, 9}, cursor: 8, delta: 3, atLineStart: false), {5, 9, 12});
    });

    test('a deletion collapses lines inside it and pulls the rest up', () {
      expect(shiftLines({2, 3, 4, 9}, cursor: 2, delta: -2, atLineStart: false), {2, 7});
    });
  });

  test('stops at breakpoints, steps, reads variables and evaluates in a real VM', () async {
    final dir = await Directory.systemTemp.createTemp('hotrestart_debugger');
    final file = p.join(dir.path, 'main.dart');
    await File(file).writeAsString(_script);
    final dart = dartCommand(Directory.current.path);
    final process = await Process.start(
      dart.exe,
      [...dart.args, '--enable-vm-service=0', '--pause-isolates-on-start', file],
      runInShell: dart.runInShell,
    );
    final output = StringBuffer();
    final uri = Completer<String>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      output.writeln(l);
      final m = RegExp(r'http://\S+').firstMatch(l);
      if (m != null && !uri.isCompleted) {
        uri.complete('${m[0]!.replaceFirst('http://', 'ws://').replaceFirst(RegExp(r'/$'), '')}/ws');
      }
    });
    process.stderr.drain<void>().ignore();

    final debugger = Debugger();
    final messages = <String>[];
    debugger.onMessage = messages.add;
    Future<void> until(bool Function() test) async {
      final done = Completer<void>();
      void check() {
        if (test() && !done.isCompleted) done.complete();
      }

      debugger.addListener(check);
      check();
      await done.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail('state: ${debugger.state}, ${debugger.pauseReason}\nmessages: $messages\noutput: $output'),
      );
      debugger.removeListener(check);
    }

    addTearDown(() async {
      debugger.dispose();
      process.kill();
      await dir.delete(recursive: true).catchError((_) => dir);
    });

    debugger.toggleBreakpoint(file, 1);
    expect(debugger.hasBreakpoint(file, 1), isTrue);
    await debugger.connect(await uri.future.timeout(const Duration(seconds: 20)), dir.path);

    await until(() => debugger.paused);
    expect(debugger.currentFrame!.function, contains('add'));
    expect(debugger.currentFrame!.path, file);
    expect(debugger.currentFrame!.line, 1);
    expect(debugger.pauseReason, 'Breakpoint');
    expect({for (final v in debugger.variables) v.name: v.value}, containsPair('a', '2'));
    expect(await debugger.evaluate('a + b'), '5');

    // The VM steps by token, so one line can take several stops.
    for (var i = 0; i < 5 && debugger.currentFrame!.line != 2; i++) {
      await debugger.stepOver();
      await until(() => debugger.paused);
    }
    expect(debugger.currentFrame!.line, 2);
    expect({for (final v in debugger.variables) v.name: v.value}, containsPair('sum', '5'));

    // The caller's frame has its own variables, and a List opens up to its elements.
    debugger.selectFrame(1);
    expect(debugger.currentFrame!.function, contains('main'));
    final names = debugger.variables.firstWhere((v) => v.name == 'names');
    expect(names.expandable, isTrue);
    final items = await debugger.children(names);
    expect(items.map((v) => v.value), ['"x"', '"y"']);
    debugger.selectFrame(0);

    await debugger.setExceptionMode(vm.ExceptionPauseMode.kAll);
    await debugger.resume();
    await until(() => debugger.paused && debugger.pauseReason.startsWith('Exception'));
    expect(debugger.pauseReason, contains('boom'));

    await debugger.resume();
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(output.toString(), contains('[x, y] 5'));
    expect(messages, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
