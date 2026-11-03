import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'console_session.dart';
import '../../core/mono_font.dart';
import '../../core/platform_keys.dart';

const _theme = TerminalTheme(
  cursor: Color(0xFF34D399),
  selection: Color(0x5534D399),
  foreground: Color(0xFFE5E7EB),
  background: Color(0xFF0F1115),
  black: Color(0xFF1F2937),
  red: Color(0xFFF87171),
  green: Color(0xFF34D399),
  yellow: Color(0xFFFBBF24),
  blue: Color(0xFF60A5FA),
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: Color(0xFFE5E7EB),
  brightBlack: Color(0xFF6B7280),
  brightRed: Color(0xFFFCA5A5),
  brightGreen: Color(0xFF6EE7B7),
  brightYellow: Color(0xFFFDE68A),
  brightBlue: Color(0xFF93C5FD),
  brightMagenta: Color(0xFFD8B4FE),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFBBF24),
  searchHitBackgroundCurrent: Color(0xFF34D399),
  searchHitForeground: Color(0xFF0F1115),
);

/// Terminal widget: right-click copies the selection, or pastes when nothing is selected.
/// xterm opens its text input without saying which window it's for, and such input goes nowhere,
/// so typing comes from key events instead.
const consoleUsesKeyEvents = true;

/// Ctrl+C copies while text is selected, as in Windows Terminal. With nothing selected it still interrupts.
bool copiesSelection(KeyEvent event, {required bool hasSelection}) {
  final keys = HardwareKeyboard.instance;
  return hasSelection && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyC && keys.isPrimaryPressed && !keys.isShiftPressed;
}

class ConsoleView extends StatelessWidget {
  const ConsoleView({super.key, required this.session, this.autofocus = true});

  final ConsoleSession session;
  final bool autofocus;

  Future<void> _copyOrPaste() async {
    final sel = session.controller.selection;
    if (sel != null) {
      await Clipboard.setData(ClipboardData(text: session.terminal.buffer.getText(sel)));
      session.controller.clearSelection();
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final t? when t.isNotEmpty) session.terminal.paste(t);
  }

  @override
  Widget build(BuildContext context) => Container(
    color: _theme.background,
    padding: const EdgeInsets.fromLTRB(8, 6, 2, 2),
    child: CallbackShortcuts(
      bindings: {
        primaryActivator(LogicalKeyboardKey.keyC, shift: !Platform.isMacOS): _copyOrPaste,
        primaryActivator(LogicalKeyboardKey.keyV, shift: !Platform.isMacOS): _copyOrPaste,
      },
      child: TerminalView(
        session.terminal,
        controller: session.controller,
        theme: _theme,
        autofocus: autofocus,
        hardwareKeyboardOnly: consoleUsesKeyEvents,
        textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'Cascadia Mono', fontFamilyFallback: ['Consolas', ...monoFallback]),
        onSecondaryTapDown: (_, _) => _copyOrPaste(),
        onKeyEvent: (_, event) {
          if (!copiesSelection(event, hasSelection: session.controller.selection != null)) return KeyEventResult.ignored;
          unawaited(_copyOrPaste());
          return KeyEventResult.handled;
        },
      ),
    ),
  );
}
