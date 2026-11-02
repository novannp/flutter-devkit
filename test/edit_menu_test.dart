import 'package:devkit/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an Edit menu item reaches the field that had focus', (tester) async {
    final field = TextEditingController(text: 'hello');
    final focus = FocusNode();
    addTearDown(field.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MenuBar(
                children: [
                  SubmenuButton(
                    menuChildren: [
                      MenuItemButton(
                        onPressed: () => invokeOnFocused(const SelectAllTextIntent(SelectionChangedCause.keyboard)),
                        child: const Text('Select All'),
                      ),
                    ],
                    child: const Text('Edit'),
                  ),
                ],
              ),
              TextField(controller: field, focusNode: focus),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select All'));
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isTrue);
    expect(field.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
  });
}
