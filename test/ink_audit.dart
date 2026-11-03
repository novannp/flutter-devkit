import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An InkWell paints its hover on the nearest Material. An opaque box between the two hides it.
List<String> inksHiddenBehindABox() {
  bool opaque(Color? c) => c != null && c.a == 1;
  final hidden = <String>[];
  for (final ink in find.byWidgetPredicate((w) => w is InkResponse).evaluate()) {
    ink.visitAncestorElements((e) {
      final w = e.widget;
      if (w is Material) return false;
      final box = switch (w) {
        ColoredBox(:final color) => color,
        DecoratedBox(decoration: BoxDecoration(:final color), position: DecorationPosition.background) => color,
        _ => null,
      };
      if (!opaque(box)) return true;
      hidden.add(ink.debugGetCreatorChain(12));
      return false;
    });
  }
  return hidden;
}
