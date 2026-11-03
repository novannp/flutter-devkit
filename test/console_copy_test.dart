import 'dart:io';

import 'package:devkit/modules/console/console_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('typing reaches the shell', (tester) async {
    final terminal = Terminal();
    final sent = StringBuffer();
    terminal.onOutput = sent.write;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, hardwareKeyboardOnly: consoleUsesKeyEvents),
        ),
      ),
    );
    // A click is how the panel gets focus: it isn't focused on its own.
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL, character: 'l');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS, character: 's');
    await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
    await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent.toString(), 'ls -\x7f\r');
    // It waits this long to tell a click from a double click.
    await tester.pump(const Duration(milliseconds: 400));
  });

  final primary = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

  testWidgets('Ctrl+C copies a selection, and otherwise still interrupts', (tester) async {
    final seen = <(bool, bool)>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      Focus(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyC) {
            seen.add((copiesSelection(event, hasSelection: true), copiesSelection(event, hasSelection: false)));
          }
          return KeyEventResult.ignored;
        },
        child: const SizedBox(),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(primary);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(primary);
    expect(seen.single, (true, false));

    seen.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    expect(seen.single, (false, false), reason: 'a plain c is typing');

    seen.clear();
    await tester.sendKeyDownEvent(primary);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(primary);
    expect(seen.single, (false, false), reason: 'Ctrl+Shift+C has its own shortcut');
  });
}
