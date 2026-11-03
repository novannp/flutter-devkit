import 'package:slipway/core/windows.dart';
import 'package:slipway/modules/editor/tool_tabs.dart';
import 'package:slipway/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new window does not inherit a debugger start-paused switch', () {
    final env = windowEnvironment({'PATH': 'x', 'FLUTTER_ENGINE_SWITCHES': '1', 'FLUTTER_ENGINE_SWITCH_1': 'start-paused', 'Flutter_Engine_Switch_2': 'y'});
    expect(env, {'PATH': 'x'});
  });

  test('a tab that is not a module, like a diff, still has a title', () {
    final diff = AppModule('main.dart (diff)', Icons.compare_arrows, const SizedBox());
    expect(windowTitleFor(diff), 'main.dart (diff) — Slipway');
    expect(windowTitleFor(null), 'Slipway');
  });
}
