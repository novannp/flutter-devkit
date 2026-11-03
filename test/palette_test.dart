import 'dart:io';

import 'package:slipway/modules/editor/palette.dart';
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

  test('search also finds a command by its group', () {
    void none() {}
    final items = [PaletteItem('Pub Get', none, group: 'Flutter'), PaletteItem('Open File', none, group: 'File')];
    expect(filterPalette(items, 'flutter pub').single.label, 'Pub Get');
    expect(filterPalette(items, 'open').single.label, 'Open File');
  });

  testWidgets('browsing shows headings, and the arrows follow what shows', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var ran = '';
    final items = [
      PaletteItem('One', () => ran = 'one', group: 'A'),
      PaletteItem('Two', () => ran = 'two', group: 'B', keys: 'Ctrl+Shift+T'),
      PaletteItem('Three', () => ran = 'three', group: 'A'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => showPalette(context, hint: 'h', empty: 'e', items: items), child: const Text('Open')),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(find.textContaining(Platform.isMacOS ? '⇧' : 'Shift'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Three')).dy, lessThan(tester.getTopLeft(find.text('Two')).dy), reason: 'grouped');

    // One, then Three: the second row on screen, even though it was third in the list.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(ran, 'three');
  });

  testWidgets('a prefix hands over to another search, with what was typed', (tester) async {
    void none() {}
    var handed = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPalette(context, hint: 'h', empty: 'e', items: [PaletteItem('One', none)], prefixes: {'@': (rest) => handed = rest}),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '@bui');
    await tester.pumpAndSettle();
    expect(handed, 'bui');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a palette can open already searching', (tester) async {
    void none() {}
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPalette(context, hint: 'h', empty: 'e', query: 'bui', items: [PaletteItem('build', none), PaletteItem('dispose', none)]),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('build'), findsOneWidget);
    expect(find.text('dispose'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'bui');
  });
}
