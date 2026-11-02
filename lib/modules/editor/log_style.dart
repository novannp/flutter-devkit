import 'package:flutter/material.dart';

enum LogLevel { error, warning, success, debug, plain }

final _error = RegExp(r"\b(error|exception|failed|failure|fatal|unhandled)\b|^E/|^\s*#\d+\s", caseSensitive: false);
final _warning = RegExp(r'\b(warning|deprecated)\b|^W/', caseSensitive: false);
final _success = RegExp(r'^\s*[✓√]|\b(built|succeeded|success)\b', caseSensitive: false);
final _debug = RegExp(r'^(D|V)/');

/// Build tools print plain text, so a line's level has to come from its wording.
LogLevel levelOf(String line) {
  if (_success.hasMatch(line) && !_error.hasMatch(line)) return LogLevel.success;
  if (_error.hasMatch(line)) return LogLevel.error;
  if (_warning.hasMatch(line)) return LogLevel.warning;
  return _debug.hasMatch(line) ? LogLevel.debug : LogLevel.plain;
}

const _ansi = <int, Color>{
  30: Color(0xFF6B7280),
  31: Color(0xFFEF4444),
  32: Color(0xFF22C55E),
  33: Color(0xFFEAB308),
  34: Color(0xFF3B82F6),
  35: Color(0xFFA855F7),
  36: Color(0xFF06B6D4),
  37: Color(0xFFD1D5DB),
  90: Color(0xFF9CA3AF),
  91: Color(0xFFF87171),
  92: Color(0xFF4ADE80),
  93: Color(0xFFFACC15),
  94: Color(0xFF60A5FA),
  95: Color(0xFFC084FC),
  96: Color(0xFF22D3EE),
  97: Color(0xFFF9FAFB),
};

final _escape = RegExp(r'\x1b\[([0-9;]*)m');

/// Turns ANSI color codes into styled text; codes it doesn't know are dropped rather than shown.
TextSpan ansiSpan(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var style = base;
  var at = 0;
  for (final m in _escape.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start), style: style));
    for (final part in (m[1]!.isEmpty ? '0' : m[1]!).split(';')) {
      final code = int.tryParse(part);
      if (code == 0 || code == 39) {
        style = code == 0 ? base : style.copyWith(color: base.color);
      } else if (code == 1) {
        style = style.copyWith(fontWeight: FontWeight.w700);
      } else if (_ansi[code] case final color?) {
        style = style.copyWith(color: color);
      }
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: style));
  return TextSpan(children: spans, style: base);
}
