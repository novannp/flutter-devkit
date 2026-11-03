import 'package:hotrestart/core/panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the whole width of the rail takes the click, gaps included', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 60,
              child: RailItem(tooltip: 'Files', icon: Icons.description_outlined, selected: false, onTap: () => tapped++),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(RailItem));
    expect(box.width, 60);
    for (final spot in [box.topLeft + const Offset(1, 1), box.centerLeft + const Offset(1, 0), box.bottomRight - const Offset(1, 1), box.center]) {
      await tester.tapAt(spot);
    }
    expect(tapped, 4);
  });

  testWidgets('a count stays clear of the icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 60,
              child: RailItem(tooltip: 'Changes', icon: Icons.call_split, selected: true, badge: '99+', onTap: () {}),
            ),
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byIcon(Icons.call_split)).overlaps(tester.getRect(find.text('99+'))), isFalse);
  });
}
