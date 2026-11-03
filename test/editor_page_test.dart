import 'dart:io';

import 'package:devkit/core/tools.dart';
import 'package:devkit/modules/devices/cubit/devices_cubit.dart';
import 'package:devkit/modules/devices/services/adb_service.dart';
import 'package:devkit/modules/devices/services/device_store.dart';
import 'package:devkit/modules/devices/services/mdns_service.dart';
import 'package:devkit/modules/devices/services/network_scanner.dart';
import 'package:devkit/modules/editor/code_pane.dart';
import 'package:devkit/modules/editor/dart_sdk.dart';
import 'package:devkit/modules/editor/debug_panel.dart' show breakpointColor;
import 'package:devkit/modules/editor/editor_page.dart';
import 'package:devkit/modules/editor/editor_view.dart';
import 'package:devkit/modules/editor/engine/code_editor.dart';
import 'package:devkit/modules/editor/file_tree.dart';
import 'package:devkit/modules/editor/markdown_view.dart';
import 'package:devkit/modules/editor/notices.dart';
import 'package:devkit/modules/editor/tool_tabs.dart';
import 'package:devkit/modules/editor/source_control_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

final _primary = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

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

      // A click in the code dismisses the suggestions; typing brings them back.
      await tester.tapAt(tester.getTopLeft(find.byType(CodeEditor)) + const Offset(600, 300));
      await tester.pump();
      expect(find.textContaining('print'), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      ctrl.selection = const CodeLineSelection.collapsed(index: 1, offset: 5);
      await tester.pump();
      ctrl.replaceSelection('n');
      await settle(() => find.textContaining('print').evaluate().isNotEmpty, 'the popup again');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(() => ctrl.text.contains('print'), 'the accepted completion');
      // The file has 4 lines counting the empty one after the final newline.
      expect(ctrl.lineCount, 4, reason: 'Enter accepts the suggestion instead of adding a line. Got: ${ctrl.text}');
      expect(ctrl.selection.extentIndex, 1);

      ctrl.selection = CodeLineSelection.collapsed(index: 1, offset: ctrl.codeLines[1].length);
      ctrl.replaceSelection('("hi");');
      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(_primary);
      await settle(() => File(main).readAsStringSync().contains('hi'), 'the save');
      expect(File(main).readAsStringSync(), contains('  print'));

      await tester.pumpWidget(const SizedBox());
      // The server's 2 s shutdown timeout runs out here; a periodic timer left running would still fail the test.
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
      // Tests default to Android, where the editor handles Enter on its own.
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('switching projects brings back the tabs each one had', (tester) async {
      // Plain text, so the test is about tabs and starts no analysis server.
      String project(String name, List<String> files) {
        final root = Directory(p.join(dir.path, name))..createSync();
        for (final f in files) {
          File(p.join(root.path, f)).writeAsStringSync(f);
        }
        return root.path;
      }

      final a = project('project_a', ['one.txt', 'two.txt']);
      final b = project('project_b', ['three.txt']);
      await const ProjectTabs([], null).save(b);
      await tester.runAsync(() => ProjectTabs([p.join(a, 'one.txt'), p.join(a, 'two.txt'), p.join(a, 'gone.txt')], p.join(a, 'one.txt')).save(a));
      final tools = await tester.runAsync(Tools.resolve);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      final cubit = DevicesCubit(adb: AdbService(tools!), mdns: MdnsService(), scanner: NetworkScanner(), store: DeviceStore());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: EditorPage(initialRoot: a),
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

      Finder tab(String name) => find.descendant(of: find.byType(ReorderableListView), matching: find.text(name));
      String? shown() => find.byType(CodeEditor).evaluate().isEmpty ? null : tester.widget<CodeEditor>(find.byType(CodeEditor)).controller?.text;

      await settle(() => tab('one.txt').evaluate().isNotEmpty && tab('two.txt').evaluate().isNotEmpty, 'project A tabs');
      await settle(() => shown() == 'one.txt', 'the tab that was active');

      await tester.tap(tab('two.txt'));
      await settle(() => shown() == 'two.txt', 'switching tab');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));

      EditorCommands.openRecent!(b);
      await settle(() => shown() == null, 'project B, with no tabs yet');
      expect(tab('one.txt'), findsNothing);

      await settle(() => find.text('three.txt').evaluate().isNotEmpty, 'the tree of project B');
      await tester.tap(find.text('three.txt'));
      await settle(() => shown() == 'three.txt', 'a file in project B');

      EditorCommands.openRecent!(a);
      await settle(() => tab('one.txt').evaluate().isNotEmpty && tab('two.txt').evaluate().isNotEmpty, 'project A coming back');
      await settle(() => shown() == 'two.txt', 'the tab last used in A');
      expect(tab('three.txt'), findsNothing);

      EditorCommands.openRecent!(b);
      await settle(() => shown() == 'three.txt', 'project B coming back');
      expect(tab('one.txt'), findsNothing);

      // Search runs as you type, with no Enter, and clearing the field clears the results.
      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(_primary);
      await tester.pump();
      final field = find.widgetWithText(TextField, 'Search in files');
      await tester.enterText(field, 'three');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(() => find.textContaining('results for "three"').evaluate().isNotEmpty, 'results without Enter');
      expect(find.text('1 results for "three"'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(find.textContaining('results for'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('Ctrl+click on a declaration shows its usages in an overlay', (tester) async {
      File(main).writeAsStringSync('void helper() {}\n\nvoid main() {\n  helper();\n  helper();\n}\n');
      File(p.join(dir.path, 'lib', 'other.dart')).writeAsStringSync("import 'main.dart';\n\nvoid other() => helper();\n");
      // What pub get leaves behind: without it the analyzer doesn't index the other files.
      File(p.join(dir.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[{"name":"sample","rootUri":"../","packageUri":"lib/","languageVersion":"3.0"}]}');
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
      final pane = tester.state<CodePaneState>(find.byType(CodePane));
      Offset? word;
      await settle(() => (word = pane.globalCenterOf(0, 6)) != null, 'the laid out line');

      // A slow answer shows that something is happening, and Esc gives up on it.
      await tester.sendKeyDownEvent(_primary);
      await tester.tapAt(word!);
      await tester.sendKeyUpEvent(_primary);
      await tester.pump();
      expect(find.text('Loading…'), findsNothing, reason: 'a fast answer never shows it');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Loading…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Loading…'), findsNothing);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(find.textContaining('usages of helper'), findsNothing, reason: 'the cancelled answer is dropped');

      // Ctrl+Space says it's working even if the analyzer isn't ready, and Esc gives up on it too.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Loading suggestions…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Loading suggestions…'), findsNothing);

      // The palette finds commands, and the symbol list opens over the current file.
      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(_primary);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Go to File'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'format doc');
      await tester.pump();
      expect(find.text('Format Document'), findsOneWidget);
      expect(find.text('Go to File'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(_primary);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.widgetWithText(TextField, 'Go to symbol in main.dart'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));

      // The declaration isn't one of its own usages; the other file's use is listed too, once it's indexed.
      for (var i = 0; i < 40 && find.text('3 usages of helper').evaluate().isEmpty; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.sendKeyDownEvent(_primary);
        await tester.tapAt(word!);
        await tester.sendKeyUpEvent(_primary);
        await settle(() => find.textContaining('usages of helper').evaluate().isNotEmpty, 'the usages overlay');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump();
      }
      expect(tester.widget<Text>(find.textContaining('usages of helper')).data, '3 usages of helper');
      expect(find.text('other.dart'), findsNWidgets(2), reason: 'in the file tree and in the overlay');
      expect(find.text('helper();'), findsNWidgets(2));

      // Esc closes it, and the arrows and Enter go to the picked line.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('usages of helper'), findsNothing);

      await tester.sendKeyDownEvent(_primary);
      await tester.tapAt(word!);
      await tester.sendKeyUpEvent(_primary);
      await settle(() => find.textContaining('usages of helper').evaluate().isNotEmpty, 'the overlay again');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.textContaining('usages of helper'), findsNothing);
      final ctrl = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
      await settle(() => ctrl.selection.extentIndex == 4, 'the second usage');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('Ctrl+click follows a symbol out of the project, into the SDK', (tester) async {
      File(main).writeAsStringSync("void main() {\n  print('x');\n}\n");
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
      final pane = tester.state<CodePaneState>(find.byType(CodePane));
      Offset? word;
      await settle(() => (word = pane.globalCenterOf(1, 3)) != null, 'the laid out line');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      // The docs card waits while the pointer travels to it, then lets go.
      await mouse.moveTo(word!);
      await tester.pump(const Duration(milliseconds: 600));
      await settle(() => find.byType(MarkdownView).evaluate().isNotEmpty, 'the docs card');
      await mouse.moveTo(word! + const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MarkdownView), findsOneWidget, reason: 'still on its way to the card');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MarkdownView), findsNothing);

      // A real mouse: it hovers first, so the Ctrl+hover underline is showing when the click lands.
      // The caret starts elsewhere, on purpose: the click alone has to decide what's followed.
      await tester.sendKeyDownEvent(_primary);
      for (var i = 0; i < 300; i++) {
        await mouse.moveTo(word! + Offset(0, i.isEven ? 0 : 1));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
        if (pane.showsLink) break;
      }
      expect(pane.showsLink, isTrue, reason: 'Ctrl+hover marks the word');
      await mouse.down(word!);
      await tester.pump();
      await mouse.up();
      await tester.pump();
      await tester.sendKeyUpEvent(_primary);
      await settle(() => find.text('print.dart').evaluate().isNotEmpty, 'the SDK file to open');
      expect(find.text('Read-only: SDK or package source'), findsOneWidget);

      // Back on the project's own tab the pane follows, and typing still works there.
      await tester.tap(find.text('main.dart').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Read-only: SDK or package source'), findsNothing);

      // Two views side by side, each with its own editor.
      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
      await tester.sendKeyUpEvent(_primary);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CodePane), findsNWidgets(2));
      expect(find.byType(CodeEditor), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      // A tool opens as a tab and the Editor stays: its files panel is still there, and it comes back.
      final tool = AppModule('Probe', Icons.devices_other, const Text('probe page'));
      ToolTabs.instance.show(tool);
      await tester.pump();
      expect(find.text('probe page'), findsOneWidget);
      expect(find.byType(FileTree), findsOneWidget);
      expect(find.byType(CodePane), findsNothing, reason: 'the code is behind the tool, not gone');
      await tester.tap(find.text('Editor'));
      await tester.pump();
      expect(find.byType(CodePane), findsNWidgets(2));
      ToolTabs.instance.close(tool);
      await tester.pump();

      // A narrow window with the panels open: everything gives way instead of overflowing.
      await tester.sendKeyDownEvent(_primary);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(_primary);
      await tester.binding.setSurfaceSize(const Size(560, 400));
      await tester.pump();
      expect(tester.takeException()?.toString(), isNull);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('a project without its packages says so, until dismissed', (tester) async {
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
      for (var i = 0; i < 200 && find.byType(NoticeCard).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('missing or out of sync'), findsOneWidget);
      expect(find.text('Run pub get'), findsOneWidget);

      // The packages catching up by themselves doesn't take it away from under you.
      final config = File(p.join(dir.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      await tester.pump(const Duration(seconds: 11));
      expect(find.byType(NoticeCard), findsOneWidget);
      config.deleteSync();

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.byType(NoticeCard), findsNothing);
      // It stays away until the dependencies change again.
      await tester.pump(const Duration(seconds: 11));
      expect(find.byType(NoticeCard), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.binding.setSurfaceSize(null);
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
        if (control) await tester.sendKeyDownEvent(_primary);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(k);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        if (control) await tester.sendKeyUpEvent(_primary);
        await tester.pump();
      }

      await settle(() => find.byType(CodeEditor).evaluate().isNotEmpty, 'the editor');
      final ctrl = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
      final rel = p.join('lib', 'main.dart');
      await tester.tap(find.byType(CodeEditor));
      await tester.pump();

      // The caret on a brace lights up its partner, even across lines.
      ctrl.selection = CodeLineSelection.collapsed(index: 0, offset: ctrl.codeLines[0].length);
      await tester.pump();
      final pane = tester.state<CodePaneState>(find.byType(CodePane));
      expect(pane.matchedBrackets, ((0, 12), (2, 0)));
      ctrl.selection = const CodeLineSelection.collapsed(index: 1, offset: 1);
      await tester.pump();
      expect(pane.matchedBrackets, isNull);

      // VS Code's keys.
      await key(LogicalKeyboardKey.equal, control: true);
      expect(EditorView.fontSize.value, EditorView.defaultFontSize + 1);
      await key(LogicalKeyboardKey.minus, control: true);
      expect(EditorView.fontSize.value, EditorView.defaultFontSize);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).wordWrap, isTrue);
      await EditorView.toggleWordWrap();
      await tester.pump();
      final lineCount = ctrl.lineCount;
      ctrl.selection = const CodeLineSelection.collapsed(index: 0, offset: 6);
      await key(LogicalKeyboardKey.keyD, control: true);
      expect(ctrl.selectedText, 'main');
      expect(ctrl.lineCount, lineCount);
      ctrl.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      await key(LogicalKeyboardKey.slash, control: true);
      expect(ctrl.codeLines[0].text, startsWith('//'));
      await key(LogicalKeyboardKey.slash, control: true);
      expect(ctrl.codeLines[0].text, 'void main() {');
      await key(LogicalKeyboardKey.enter, control: true);
      expect(ctrl.lineCount, lineCount + 1);
      await key(LogicalKeyboardKey.keyK, control: true, shift: true);
      expect(ctrl.lineCount, lineCount);

      await key(LogicalKeyboardKey.keyD, control: true, shift: true);
      expect(find.text('Not running'), findsOneWidget);

      // First line of the gutter: on, then off again.
      final gutter = tester.getTopLeft(find.byType(CodeEditor)) + const Offset(9, 14);
      RenderObject gutterPaint() => tester.allRenderObjects.whereType<RenderCustomPaint>().firstWhere((r) => r.painter.runtimeType.toString() == '_GutterPainter');
      expect(gutterPaint(), isNot(paints..circle()));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: gutter);
      await mouse.moveTo(gutter + const Offset(0, 1));
      await tester.pump();
      expect(gutterPaint(), paints..circle(color: breakpointColor.withValues(alpha: .4)), reason: 'a faint dot shows where a click would put one');
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(gutterPaint(), isNot(paints..circle()));
      await mouse.removePointer();
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
      final railIcon = find.byIcon(Icons.call_split).first;
      final railItem = find.ancestor(of: railIcon, matching: find.byType(Column)).first;
      final railCount = tester.getRect(find.descendant(of: railItem, matching: find.text('1')));
      expect(tester.getRect(railIcon).overlaps(railCount), isFalse, reason: 'the count leaves the icon uncovered');
      final row = find.descendant(of: find.byType(SourceControlView), matching: find.text('main.dart'));
      await settle(() => row.evaluate().isNotEmpty, 'the changed file in the list');
      await tester.tap(row);
      await settle(() => find.text('After (working copy)').evaluate().isNotEmpty, 'the diff tab');
      await settle(() => find.text('Before (HEAD)').evaluate().isNotEmpty, 'its before side');
      expect(find.byType(SideBySideDiff), findsOneWidget);
      expect(find.byType(SourceControlView), findsOneWidget, reason: 'the Editor is still around it');
      await tester.tap(find.text('Editor').first);
      await tester.pump();
      ToolTabs.instance.open.toList().forEach(ToolTabs.instance.close);
      await tester.pump();

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
      // The refresh after a commit runs git step by step, and each step starts its process under the fake clock.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      await tester.binding.setSurfaceSize(null);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows), timeout: const Timeout(Duration(minutes: 3)));
  });
}
