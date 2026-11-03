import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

/// Cmd on macOS, Ctrl elsewhere.
extension PrimaryModifier on HardwareKeyboard {
  bool get isPrimaryPressed => Platform.isMacOS ? isMetaPressed : isControlPressed;
}

bool isPrimaryModifierKey(LogicalKeyboardKey key) => Platform.isMacOS
    ? key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight
    : key == LogicalKeyboardKey.controlLeft || key == LogicalKeyboardKey.controlRight;

SingleActivator primaryActivator(LogicalKeyboardKey key, {bool shift = false, bool alt = false}) =>
    SingleActivator(key, control: !Platform.isMacOS, meta: Platform.isMacOS, shift: shift, alt: alt);

final _altIsDown = _altChecker();

bool Function() _altChecker() {
  // Tests press their keys inside Flutter, where the operating system can't see them.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return () => HardwareKeyboard.instance.isAltPressed;
  try {
    if (Platform.isWindows) {
      final state = DynamicLibrary.open('user32.dll').lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');
      const vkMenu = 0x12;
      return () => state(vkMenu) & 0x8000 != 0;
    }
    if (Platform.isMacOS) {
      final flags = DynamicLibrary.open('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
          .lookupFunction<Uint64 Function(Int32), int Function(int)>('CGEventSourceFlagsState');
      const hidSystemState = 1, maskAlternate = 0x80000;
      return () => flags(hidSystemState) & maskAlternate != 0;
    }
  } on Object {
    // Fall through: Flutter's own idea is still mostly right.
  }
  return () => HardwareKeyboard.instance.isAltPressed;
}

/// Whether Alt is held right now. Flutter misses the key's release when the window loses focus, as
/// Alt+Tab does, and then believes Alt is down until told otherwise.
bool isAltReallyPressed() {
  final really = _altIsDown();
  if (!really && HardwareKeyboard.instance.isAltPressed) unawaited(HardwareKeyboard.instance.syncKeyboardState());
  return really;
}

String platformKeys(String label) => Platform.isMacOS ? macKeys(label) : label;

/// Shortcuts macOS keeps on Ctrl, because the system holds Cmd+Space, Cmd+Tab and Cmd+` for itself.
final _staysOnControl = RegExp(r'Ctrl\+(Shift\+)?(Space|Tab|`)');

String macKeys(String label) => label
    .replaceAllMapped(_staysOnControl, (m) => '⌃${m[1] == null ? '' : '⇧'}${m[2]}')
    .replaceAll('Ctrl+click', '⌘+click')
    .replaceAll(RegExp(r'Ctrl ?\+ ?'), '⌘')
    .replaceAll(RegExp(r'Shift ?\+ ?'), '⇧')
    .replaceAll(RegExp(r'Alt ?\+ ?'), '⌥');
