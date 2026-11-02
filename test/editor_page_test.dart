import 'dart:io';

import 'package:devkit/core/tools.dart';
import 'package:devkit/modules/devices/cubit/devices_cubit.dart';
import 'package:devkit/modules/devices/services/adb_service.dart';
import 'package:devkit/modules/devices/services/device_store.dart';
import 'package:devkit/modules/devices/services/mdns_service.dart';
import 'package:devkit/modules/devices/services/network_scanner.dart';
import 'package:devkit/modules/editor/code_pane.dart';
import 'package:devkit/modules/editor/dart_sdk.dart';
import 'package:devkit/modules/editor/editor_page.dart';
import 'package:devkit/modules/editor/source_control_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('underlineRanges splits across highlighted spans and keeps the text', () {
    const red = Color(0xFFFF0000);
    const span = TextSpan(
      style: TextStyle(fontSize: 1),
      children: [
        TextSpan(text: 'int ', style: TextStyle(fontSize: 2)),
        TextSpan(text: 'value = 1;'),
      ],
    );
    final out = underlineRanges(span, [(2, 7, red)]);
    expect(out.toPlainText(), 'int value = 1;');
    final underlined = <String>[];
    out.visitChildren((s) {
      if (s is TextSpan && s.text != null && s.style?.decorationColor == red) underlined.add(s.text!);
      return true;
    });
    expect(underlined.join(), 't val');
  });

  group('page', () {
    late Directory dir;
    late String main;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('page');
      final sdk = flutterSdkOf(Directory.current.path)!;
      Link(p.join(dir.path, '.fvm', 'flutter_sdk')).createSync(Directory(sdk).resolveSymbolicLinksSync(), recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.0.0\n');
      main = p.join(dir.path, 'lib', 'main.dart');
      File(main)
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {\n  \n}\n');
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // The server may hold a handle a moment longer; it's a temp folder.
      }
    });

    testWidgets('opens a file, completes through the real server, saves with Ctrl+S', (tester) async {
      final tools = await tester.runAsync(Tools.resolve);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      final cubit = DevicesCubit(adb: AdbService(tools!), mdns: MdnsService(), scanner: NetworkScanner(), store: DeviceStore());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: EditorPage(initialRoot: dir.path, initialFile: main),
            ),
          ),
        ),
      );

      Future<void> settle(bool Function() ok, String what) async {
        for (var i = 0; i < 300 && !ok(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ok(), isTrue, reason: 'timed out waiting for $what');
      }

      await settle(() => find.byType(CodeEditor).evaluate().isNotEmpty, 'the editor');
      expect(find.text('main.dart'), findsWidgets);
      expect(find.text('fvm'), findsOneWidget);
      final ctrl = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

      await tester.tap(find.byType(CodeEditor));
      await tester.pump();
      ctrl.selection = const CodeLineSelection.collapsed(index: 1, offset: 2);
      ctrl.replaceSelection('pri');
      await settle(() => find.textContaining('print').evaluate().isNotEmpty, 'the completion popup');

      // The popup sits by the caret's line, not somewhere random on the page.
      final popupY = tester.getTopLeft(find.textContaining('print').first).dy;
      final editorY = tester.getTopLeft(find.byType(CodeEditor)).dy;
      expect(popupY - editorY, lessThan(120));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(() => ctrl.text.contains('print'), 'the accepted completion');
      // The file has 4 lines counting the empty one after the final newline.
      expect(ctrl.lineCount, 4, reason: 'Enter accepts the suggestion instead of adding a line. Got: ${ctrl.text}');
      expect(ctrl.selection.extentIndex, 1);

      ctrl.selection = CodeLineSelection.collapsed(index: 1, offset: ctrl.codeLines[1].length);
      ctrl.replaceSelection('("hi");');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(() => File(main).readAsStringSync().contains('hi'), 'the save');
      expect(File(main).readAsStringSync(), contains('  print'));

      await tester.pumpWidget(const SizedBox());
      // The server's 2 s shutdown timeout runs out here; a periodic timer left running would still fail the test.
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
      // Tests default to Android, where the editor handles Enter on its own.
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('sets breakpoints from the gutter and F9, and commits from Source Control', (tester) async {
      for (final args in [
        ['init', '-b', 'main'],
        ['config', 'user.email', 'test@example.com'],
        ['config', 'user.name', 'Test'],
        ['add', 'lib', 'pubspec.yaml'],
        ['commit', '-m', 'first'],
      ]) {
        expect(Process.runSync('git', args, workingDirectory: dir.path).exitCode, 0);
      }
      File(p.join(dir.path, '.git', 'info', 'exclude')).writeAsStringSync('.fvm\n');
      final tools = await tester.runAsync(Tools.resolve);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      final cubit = DevicesCubit(adb: AdbService(tools!), mdns: MdnsService(), scanner: NetworkScanner(), store: DeviceStore());
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('app'),
          child: MaterialApp(
            home: Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: EditorPage(initialRoot: dir.path, initialFile: main),
              ),
            ),
          ),
        ),
      );

      Future<void> settle(bool Function() ok, String what) async {
        for (var i = 0; i < 300 && !ok(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ok(), isTrue, reason: 'timed out waiting for $what');
      }

      Future<void> key(LogicalKeyboardKey k, {bool control = false, bool shift = false}) async {
        if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(k);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await settle(() => find.byType(CodeEditor).evaluate().isNotEmpty, 'the editor');
      final ctrl = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
      final rel = p.join('lib', 'main.dart');
      await tester.tap(find.byType(CodeEditor));
      await tester.pump();

      await key(LogicalKeyboardKey.keyJ, control: true);
      await tester.tap(find.text('Debug'));
      await tester.pump();
      expect(find.text('Not running'), findsOneWidget);

      // First line of the gutter: on, then off again.
      final gutter = tester.getTopLeft(find.byType(CodeEditor)) + const Offset(9, 14);
      await tester.tapAt(gutter);
      await tester.pump();
      expect(find.text('$rel:1'), findsOneWidget);
      await tester.tapAt(gutter);
      await tester.pump();
      expect(find.text('$rel:1'), findsNothing);

      ctrl.selection = const CodeLineSelection.collapsed(index: 2, offset: 1);
      await key(LogicalKeyboardKey.f9);
      expect(find.text('$rel:3'), findsOneWidget);

      // Enter at the end of a top-level line keeps its breakpoint; the lines below move.
      ctrl.selection = CodeLineSelection.collapsed(index: 0, offset: ctrl.codeLines[0].length);
      ctrl.replaceSelection('\n');
      await tester.pump();
      expect(find.text('$rel:4'), findsOneWidget);
      ctrl.selection = const CodeLineSelection.collapsed(index: 3, offset: 1);
      ctrl.selection = const CodeLineSelection.collapsed(index: 3, offset: 0);
      ctrl.replaceSelection('\n');
      await tester.pump();
      expect(find.text('$rel:5'), findsOneWidget, reason: 'a line pushed down whole keeps its breakpoint');

      await key(LogicalKeyboardKey.keyS, control: true);
      await settle(() => !File(main).readAsStringSync().startsWith('void main() {\n  \n}'), 'the save');

      await key(LogicalKeyboardKey.keyG, control: true, shift: true);
      await settle(() => find.text('Changes (1)').evaluate().isNotEmpty, 'the changed file');
      final row = find.descendant(of: find.byType(SourceControlView), matching: find.text('main.dart'));
      await settle(() => row.evaluate().isNotEmpty, 'the changed file in the list');
      await tester.tap(row);
      await settle(() => find.textContaining('@@').evaluate().isNotEmpty, 'the diff');

      await tester.tap(find.byTooltip('Stage'));
      await settle(() => find.text('Staged (1)').evaluate().isNotEmpty, 'staging');
      await tester.enterText(find.widgetWithText(TextField, 'Commit message'), 'second & last');
      await tester.pump();
      await tester.tap(find.text('Commit 1 file(s)'));
      await settle(() => find.text('Stage files to commit').evaluate().isNotEmpty, 'the commit');
      final log = Process.runSync('git', ['log', '-1', '--format=%s'], workingDirectory: dir.path);
      expect((log.stdout as String).trim(), 'second & last');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));
  });
}
