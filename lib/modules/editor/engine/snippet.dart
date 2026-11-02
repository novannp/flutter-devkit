import 'package:flutter/services.dart';

import 'code_model.dart';

/// An LSP snippet as plain text, plus where its tab stops fall in that text, in visiting order.
/// The last stop is always the final caret position.
class ParsedSnippet {
  const ParsedSnippet(this.text, this.stops);

  final String text;
  final List<List<TextRange>> stops;
}

class _Stop {
  _Stop(this.number, this.children);

  final int number;
  final List<Object> children;
}

ParsedSnippet parseSnippet(String source) {
  var at = 0;

  int? readNumber() {
    final start = at;
    while (at < source.length && source.codeUnitAt(at) >= 0x30 && source.codeUnitAt(at) <= 0x39) {
      at++;
    }
    return start == at ? null : int.parse(source.substring(start, at));
  }

  List<Object> readNodes({required bool nested}) {
    final nodes = <Object>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      nodes.add(text.toString());
      text.clear();
    }

    while (at < source.length) {
      final ch = source[at];
      if (ch == r'\' && at + 1 < source.length && r'$}\'.contains(source[at + 1])) {
        text.write(source[at + 1]);
        at += 2;
      } else if (ch == '}' && nested) {
        break;
      } else if (ch == r'$') {
        final open = at;
        at++;
        final braced = at < source.length && source[at] == '{';
        if (braced) at++;
        final number = readNumber();
        if (number == null) {
          // A variable, which the analyzer doesn't send: keep it as text instead of losing it.
          at = open + 1;
          text.write(r'$');
          continue;
        }
        flush();
        var children = <Object>[];
        if (braced) {
          if (at < source.length && source[at] == ':') {
            at++;
            children = readNodes(nested: true);
          } else if (at < source.length && source[at] == '|') {
            final end = source.indexOf('|', at + 1);
            if (end > 0) {
              children = [source.substring(at + 1, end).split(',').first];
              at = end + 1;
            }
          }
          if (at < source.length && source[at] == '}') at++;
        }
        nodes.add(_Stop(number, children));
      } else {
        text.write(ch);
        at++;
      }
    }
    flush();
    return nodes;
  }

  final nodes = readNodes(nested: false);

  // A later $1 with no text of its own mirrors the first $1 that has some.
  final defaults = <int, List<Object>>{};
  void collect(List<Object> list) {
    for (final n in list) {
      if (n is _Stop) {
        if (n.children.isNotEmpty) defaults.putIfAbsent(n.number, () => n.children);
        collect(n.children);
      }
    }
  }

  collect(nodes);

  final out = StringBuffer();
  final byNumber = <int, List<TextRange>>{};
  void render(List<Object> list) {
    for (final n in list) {
      if (n is String) {
        out.write(n);
      } else if (n is _Stop) {
        final start = out.length;
        render(n.children.isNotEmpty ? n.children : defaults[n.number] ?? const []);
        byNumber.putIfAbsent(n.number, () => []).add(TextRange(start: start, end: out.length));
      }
    }
  }

  render(nodes);
  final text = out.toString();
  final order = byNumber.keys.where((n) => n != 0).toList()..sort();
  return ParsedSnippet(text, [
    for (final n in order) byNumber[n]!..sort((a, b) => a.start - b.start),
    byNumber[0] ?? [TextRange.collapsed(text.length)],
  ]);
}

/// Walks a snippet's stops after it's inserted: Tab forward, Shift+Tab back. Mirrored stops get a
/// cursor each, so typing changes them all.
class SnippetSession {
  SnippetSession(this._controller, int start, ParsedSnippet snippet)
    : _stops = [
        for (final group in snippet.stops)
          [for (final r in group) TextRange(start: r.start + start, end: r.end + start)],
      ] {
    _select();
  }

  final CodeLineEditingController _controller;
  final List<List<TextRange>> _stops;
  var _index = 0;
  late int _length;

  /// Still has somewhere to go. Once it's on the final stop the session is over.
  bool get active => _index < _stops.length - 1;

  int _documentLength() {
    final lines = _controller.codeLines;
    var total = lines.length - 1;
    for (var i = 0; i < lines.length; i++) {
      total += lines[i].length;
    }
    return total;
  }

  int _offsetOf(int line, int column) {
    final lines = _controller.codeLines;
    var total = 0;
    for (var i = 0; i < line; i++) {
      total += lines[i].length + 1;
    }
    return total + column;
  }

  (int, int) _positionOf(int offset) {
    final lines = _controller.codeLines;
    var left = offset;
    for (var i = 0; i < lines.length; i++) {
      if (left <= lines[i].length) return (i, left);
      left -= lines[i].length + 1;
    }
    return (lines.length - 1, lines[lines.length - 1].length);
  }

  CodeLineSelection _selectionOf(TextRange r) {
    final (startLine, startColumn) = _positionOf(r.start);
    final (endLine, endColumn) = _positionOf(r.end);
    return CodeLineSelection(baseIndex: startLine, baseOffset: startColumn, extentIndex: endLine, extentOffset: endColumn);
  }

  void _select() {
    final group = _stops[_index];
    _controller.selection = _selectionOf(group.last);
    // Each added cursor becomes the primary one, so going backwards leaves the first on top.
    for (final r in group.reversed.skip(1)) {
      _controller.addCursor(_selectionOf(r));
    }
    _length = _documentLength();
  }

  /// Moves [by] one stop either way. False means the caret has wandered off, so the key should do
  /// what it normally does.
  bool move(int by) {
    final group = _stops[_index];
    final grown = _documentLength() - _length;
    if (grown % group.length != 0) return false;
    final each = grown ~/ group.length;
    final s = _controller.selection;
    final first = group.first;
    final caret = _offsetOf(s.extentIndex, s.extentOffset);
    if (_controller.extraSelections.length != group.length - 1 || caret < first.start || caret > first.end + each) return false;

    _stops[_index] = [
      for (var i = 0; i < group.length; i++) TextRange(start: group[i].start + i * each, end: group[i].end + (i + 1) * each),
    ];
    for (var g = 0; g < _stops.length; g++) {
      if (g == _index) continue;
      _stops[g] = [
        for (final r in _stops[g])
          TextRange(
            start: r.start + group.where((c) => c.end <= r.start).length * each,
            end: r.end + group.where((c) => c.end <= r.end).length * each,
          ),
      ];
    }
    _index = (_index + by).clamp(0, _stops.length - 1);
    _select();
    return true;
  }
}
