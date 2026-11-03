import 'dart:io';

import 'package:devkit/modules/console/console_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
