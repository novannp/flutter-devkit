import 'package:slipway/modules/editor/tool_tabs.dart';
import 'package:slipway/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tab that is not a module, like a diff, still has a title', () {
    final diff = AppModule('main.dart (diff)', Icons.compare_arrows, const SizedBox());
    expect(windowTitleFor(diff), 'main.dart (diff) — Slipway');
    expect(windowTitleFor(null), 'Slipway');
  });
}
