import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipway/core/panels.dart';

import 'ink_audit.dart';

void main() {
  testWidgets('a row in a panel shows its hover, on top of the panel color', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(hoverColor: const Color(0x80FF0000)),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: PanelCard(
                child: InkWell(key: key, onTap: () {}, child: const SizedBox.expand()),
              ),
            ),
          ),
        ),
      ),
    );
    expect(inksHiddenBehindABox(), isEmpty);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.byKey(key)));
    await tester.pumpAndSettle();
    expect(Material.of(tester.element(find.byKey(key))), paints..rect(color: const Color(0x80FF0000)));
  });

  testWidgets('the audit catches a color between the ink and its Material', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColoredBox(
            color: Colors.white,
            child: InkWell(onTap: () {}, child: const SizedBox(width: 20, height: 20)),
          ),
        ),
      ),
    );
    expect(inksHiddenBehindABox(), hasLength(1));
  });
}
