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

String platformKeys(String label) => Platform.isMacOS ? macKeys(label) : label;

/// Shortcuts macOS keeps on Ctrl, because the system holds Cmd+Space, Cmd+Tab and Cmd+` for itself.
final _staysOnControl = RegExp(r'Ctrl\+(Shift\+)?(Space|Tab|`)');

String macKeys(String label) => label
    .replaceAllMapped(_staysOnControl, (m) => '⌃${m[1] == null ? '' : '⇧'}${m[2]}')
    .replaceAll('Ctrl+click', '⌘+click')
    .replaceAll(RegExp(r'Ctrl ?\+ ?'), '⌘')
    .replaceAll(RegExp(r'Shift ?\+ ?'), '⇧')
    .replaceAll(RegExp(r'Alt ?\+ ?'), '⌥');
