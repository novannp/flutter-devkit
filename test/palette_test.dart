import 'package:devkit/modules/editor/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PaletteItem item(String label, [VoidCallback? onPick]) => PaletteItem(label, onPick ?? () {});
  List<String> labels(List<PaletteItem> items) => items.map((i) => i.label).toList();

  test('words match in any order, and labels starting with the query come first', () {
    final items = [item('Show Terminal'), item('Format Document'), item('Terminal: Clear'), item('Save')];
    expect(labels(filterPalette(items, '')), labels(items));
    expect(labels(filterPalette(items, 'doc form')), ['Format Document']);
    expect(labels(filterPalette(items, 'term')), ['Terminal: Clear', 'Show Terminal']);
    expect(filterPalette(items, 'zzz'), isEmpty);
  });

  testWidgets('types, moves and runs the picked item after closing', (tester) async {
    var ran = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPalette(
              context,
              hint: 'Type a command',
              empty: 'No commands match',
              items: [item('Save', () => ran = 'save'), item('Save All', () => ran = 'all'), item('Zoom In', () => ran = 'zoom')],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nothing like it');
    await tester.pump();
    expect(find.text('No commands match'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'save');
    await tester.pump();
    expect(find.text('Zoom In'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(ran, 'all');
    expect(find.byType(TextField), findsNothing);
  });
}
