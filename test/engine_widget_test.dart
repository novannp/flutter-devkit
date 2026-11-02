import 'package:devkit/core/theme.dart';
import 'package:devkit/modules/editor/engine/code_editor.dart';
import 'package:devkit/modules/editor/engine/syntax.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _style = CodeEditorStyle(
  fontFamily: 'monospace',
  fontSize: 14,
  backgroundColor: Colors.white,
  textColor: Colors.black,
  cursorColor: Colors.blue,
  selectionColor: Colors.blue.withValues(alpha: .3),
  cursorLineColor: Colors.grey.withValues(alpha: .1),
  syntax: appThemes.first.syntax,
);

void main() {
  late CodeLineEditingController c;
  late CodeIndicatorValueNotifier notifier;
  late CodeScrollController scroll;

  Future<void> pumpEditor(WidgetTester tester, String text, {bool wrap = false, bool readOnly = false, Size size = const Size(800, 400)}) async {
    c = CodeLineEditingController(codeLines: CodeLines.fromText(text));
    scroll = CodeScrollController();
    addTearDown(c.dispose);
    addTearDown(scroll.dispose);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeEditor(
            controller: c,
            scrollController: scroll,
            language: languageForExtension('.dart'),
            lineComment: '//',
            wordWrap: wrap,
            readOnly: readOnly,
            padding: const EdgeInsets.only(left: 6, top: 4, bottom: 120, right: 16),
            style: _style,
            indicatorBuilder: (_, editing, chunks, n) {
              notifier = n;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DefaultCodeLineNumber(controller: editing, notifier: n, textStyle: const TextStyle(fontSize: 12), focusedTextStyle: const TextStyle(fontSize: 12)),
                  DefaultCodeChunkIndicator(width: 18, controller: chunks, editing: editing, notifier: n, color: Colors.grey),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder field() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_CodeField');

  Future<void> focus(WidgetTester tester) async {
    await tester.tapAt(tester.getTopLeft(field()) + const Offset(300, 200));
    await tester.pump();
  }

  /// What the operating system's text input sends for a typed character.
  Future<void> type(WidgetTester tester, String text) async {
    final set = tester.testTextInput.log.lastWhere((m) => m.method == 'TextInput.setClient');
    final client = (set.arguments as List).first as int;
    final current = c.codeLines[c.selection.extentIndex].text;
    final at = c.selection.extentOffset;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/textinput',
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          client,
          {
            'deltas': [
              {
                'oldText': current,
                'deltaText': text,
                'deltaStart': at,
                'deltaEnd': at,
                'selectionBase': at + text.length,
                'selectionExtent': at + text.length,
                'selectionAffinity': 'TextAffinity.downstream',
                'selectionIsDirectional': false,
                'composingBase': -1,
                'composingExtent': -1,
              },
            ],
          },
        ]),
      ),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> keys(WidgetTester tester, LogicalKeyboardKey key, {bool control = false, bool shift = false, bool alt = false}) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  double lineY(int line) => notifier.value!.paragraphs.firstWhere((x) => x.index == line).offset.dy;

  Offset onLine(WidgetTester tester, int line, {double x = 60}) => tester.getTopLeft(field()) + Offset(x, lineY(line) + 8);

  testWidgets('typing reaches the text through the input channel, and keys edit it', (tester) async {
    await pumpEditor(tester, 'hello');
    await focus(tester);
    final client = tester.testTextInput.setClientArgs!;
    expect(client['viewId'], tester.view.viewId, reason: 'Windows drops all typing without it');
    await keys(tester, LogicalKeyboardKey.end);
    await type(tester, '!');
    expect(c.text, 'hello!');

    await keys(tester, LogicalKeyboardKey.backspace);
    expect(c.text, 'hello');
    await keys(tester, LogicalKeyboardKey.enter);
    expect(c.text, 'hello\n');
    await type(tester, 'x');
    expect(c.text, 'hello\nx');

    await keys(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(c.text, 'hello\n');
    await keys(tester, LogicalKeyboardKey.keyY, control: true);
    expect(c.text, 'hello\nx');

    await keys(tester, LogicalKeyboardKey.arrowUp);
    expect(c.selection.extentIndex, 0);
    await keys(tester, LogicalKeyboardKey.home);
    await keys(tester, LogicalKeyboardKey.end, shift: true);
    expect(c.selectedText, 'hello');
    await keys(tester, LogicalKeyboardKey.keyA, control: true);
    expect(c.selectedText, 'hello\nx');
    await keys(tester, LogicalKeyboardKey.delete);
    expect(c.text, '');
    await keys(tester, LogicalKeyboardKey.tab);
    expect(c.text, '  ');
  });

  testWidgets('clipboard and line keys', (tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
      if (call.method == 'Clipboard.getData') return {'text': clipboard.last};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpEditor(tester, 'one\ntwo');
    await focus(tester);
    c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 3);
    await keys(tester, LogicalKeyboardKey.keyC, control: true);
    expect(clipboard.last, 'one');
    c.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    await keys(tester, LogicalKeyboardKey.keyV, control: true);
    await tester.pump();
    expect(c.text, 'one\ntwoone');

    await keys(tester, LogicalKeyboardKey.arrowUp, alt: true);
    expect(c.text, 'twoone\none');
    await keys(tester, LogicalKeyboardKey.keyK, control: true, shift: true);
    expect(c.text, 'one');
    await keys(tester, LogicalKeyboardKey.slash, control: true);
    expect(c.text, '// one');
  });

  testWidgets('a read-only editor moves but does not change', (tester) async {
    await pumpEditor(tester, 'abc', readOnly: true);
    await focus(tester);
    await keys(tester, LogicalKeyboardKey.delete);
    await keys(tester, LogicalKeyboardKey.enter);
    await keys(tester, LogicalKeyboardKey.keyV, control: true);
    expect(c.text, 'abc');
    await keys(tester, LogicalKeyboardKey.end);
    expect(c.selection.extentOffset, 3);
    expect(tester.testTextInput.hasAnyClients, isFalse, reason: 'nothing to type into');
  });

  testWidgets('the mouse places the caret, drags a selection, and clicks pick a word and a line', (tester) async {
    await pumpEditor(tester, 'hello world\nsecond line');
    final start = onLine(tester, 1, x: 6);
    await tester.tapAt(start);
    await tester.pump();
    expect((c.selection.extentIndex, c.selection.extentOffset), (1, 0));

    final drag = await tester.startGesture(onLine(tester, 0, x: 6), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await drag.moveTo(onLine(tester, 1, x: 300));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.selectedText, 'hello world\nsecond line');

    final word = onLine(tester, 0, x: 30);
    await tester.tapAt(word);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word);
    await tester.pump();
    expect(c.selectedText, 'hello');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word);
    await tester.pump();
    expect(c.selection.startOffset, 0);
    expect(c.selection.endIndex, 1, reason: 'a third click takes the line');
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('Alt+click adds a cursor, typing goes to both, Esc goes back to one', (tester) async {
    await pumpEditor(tester, 'aa\nbb');
    await tester.tapAt(onLine(tester, 0, x: 6));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.tapAt(onLine(tester, 1, x: 6));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(c.extraSelections.length, 1);
    await type(tester, 'x');
    expect(c.text, 'xaa\nxbb');
    await keys(tester, LogicalKeyboardKey.escape);
    expect(c.extraSelections, isEmpty);
  });

  testWidgets('only the lines in view are laid out, and the wheel scrolls smoothly to where it should', (tester) async {
    await pumpEditor(tester, List.generate(5000, (i) => 'line $i').join('\n'));
    final shown = notifier.value!.paragraphs;
    expect(shown.length, lessThan(40));
    expect(shown.first.index, 0);

    await tester.sendEventToBinding(PointerScrollEvent(position: tester.getCenter(field()), scrollDelta: const Offset(0, 1000)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.vertical, inExclusiveRange(0, 1000), reason: 'on its way, not there yet');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(scroll.vertical, 1000);
    expect(notifier.value!.paragraphs.first.index, greaterThan(40));

    await tester.tapAt(tester.getCenter(field()));
    await tester.pump();
    await keys(tester, LogicalKeyboardKey.end, control: true);
    expect(c.selection.extentIndex, 4999);
    expect(notifier.value!.paragraphs.any((x) => x.index == 4999), isTrue, reason: 'the caret stays in view');
    await keys(tester, LogicalKeyboardKey.home, control: true);
    expect(notifier.value!.paragraphs.first.index, 0);
  });

  testWidgets('moving near the edge glides, and everything comes to rest', (tester) async {
    await pumpEditor(tester, List.generate(500, (i) => 'line $i').join('\n'), size: const Size(800, 300));
    await focus(tester);
    c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await keys(tester, LogicalKeyboardKey.arrowDown);
    }
    final during = scroll.vertical;
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.vertical, greaterThan(during - 0.01));
    // Not pumpAndSettle: a focused caret blinks, so frames never quite stop.
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final shown = notifier.value!.paragraphs.map((x) => x.index);
    expect(shown, contains(20), reason: 'the caret ends up in view');
    final settled = scroll.vertical;
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.vertical, settled, reason: 'and nothing keeps animating');
  });

  testWidgets('word wrap gives long lines more rows and keeps positions right', (tester) async {
    final long = List.filled(40, 'word').join(' ');
    await pumpEditor(tester, '$long\nnext', wrap: true, size: const Size(500, 400));
    final first = notifier.value!.paragraphs[0], second = notifier.value!.paragraphs[1];
    expect(first.height, greaterThan(first.preferredLineHeight * 1.5));
    expect(second.offset.dy, closeTo(first.offset.dy + first.height, .01));
    expect(tester.takeException(), isNull);

    await tester.tapAt(onLine(tester, 1, x: 6));
    await tester.pump();
    expect((c.selection.extentIndex, c.selection.extentOffset), (1, 0));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('long lines scroll sideways to keep the caret in view', (tester) async {
    await pumpEditor(tester, 'x' * 400);
    await focus(tester);
    await keys(tester, LogicalKeyboardKey.end);
    expect(scroll.horizontal, greaterThan(0));
    await keys(tester, LogicalKeyboardKey.home);
    await tester.pump();
    expect(scroll.horizontal, 0);
  });

  testWidgets('folding from the gutter hides the block and an arrow brings it back', (tester) async {
    await pumpEditor(tester, 'void f() {\n  a();\n  b();\n}\nend');
    await tester.pump(const Duration(milliseconds: 200));
    final arrow = find.byType(DefaultCodeChunkIndicator);
    final at = tester.getTopLeft(arrow) + Offset(9, lineY(0) + 8);
    await tester.tapAt(at);
    await tester.pump();
    expect(notifier.value!.paragraphs.map((x) => x.index), [0, 4]);
    expect(c.text, 'void f() {\n  a();\n  b();\n}\nend');
    await tester.tapAt(at);
    await tester.pump();
    expect(notifier.value!.paragraphs.map((x) => x.index), [0, 1, 2, 3, 4]);
  });

  testWidgets('positions line up, so overlays land on the right text', (tester) async {
    await pumpEditor(tester, 'abc\ndef');
    final para = notifier.value!.paragraphs[1];
    final at = para.paragraph.getOffset(const TextPosition(offset: 2))!;
    expect(para.paragraph.getPosition(at + const Offset(1, 2)).offset, 2);
    expect(para.height, para.preferredLineHeight);
    expect(lineY(1) - lineY(0), para.preferredLineHeight);
    expect(notifier.value!.focusedIndex, 0);
  });

  testWidgets('find highlights and walks the matches, and replace changes them', (tester) async {
    await pumpEditor(tester, 'cat dog cat\ncat');
    final finder = CodeFindController(c);
    addTearDown(finder.dispose);
    finder.findMode();
    finder.findInputController.text = 'cat';
    expect(finder.value!.result!.matches.length, 3);
    finder.nextMatch();
    expect(c.selectedText, 'cat');
    expect(c.selection.startOffset, 8);
    finder.toggleCaseSensitive();
    finder.findInputController.text = 'CAT';
    expect(finder.value!.result!.matches, isEmpty);
    finder.toggleCaseSensitive();
    expect(finder.value!.result!.matches.length, 3);
    finder.replaceInputController.text = 'x';
    finder.replaceAllMatches();
    expect(c.text, 'x dog x\nx');
    c.undo();
    expect(c.text, 'cat dog cat\ncat');
    finder.toggleRegex();
    finder.findInputController.text = 'd.g';
    expect(finder.value!.result!.matches.single.start, 4);
    finder.findInputController.text = '(';
    expect(finder.value!.result!.matches, isEmpty, reason: 'a half-typed pattern is not an error');
  });
}
