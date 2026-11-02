import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum TextLineBreak { lf, crlf }

class CodeLineOptions {
  const CodeLineOptions({this.lineBreak = TextLineBreak.lf});

  final TextLineBreak lineBreak;
}

class CodeLine {
  const CodeLine(this.text, {this.chunkParent = false});

  final String text;

  /// Starts a folded block.
  final bool chunkParent;

  int get length => text.length;
}

/// The lines as of one moment. A new object after every edit, so "did the text change" is an identity check.
class CodeLines {
  CodeLines(this._lines, this._folded);

  factory CodeLines.fromText(String text) => CodeLines(splitLines(text), const {});

  final List<String> _lines;
  final Map<int, int> _folded;

  int get length => _lines.length;

  CodeLine operator [](int index) => CodeLine(_lines[index], chunkParent: _folded.containsKey(index));
}

List<String> splitLines(String text) => text.split(RegExp(r'\r?\n'));

class CodeLineSelection {
  const CodeLineSelection({required this.baseIndex, required this.baseOffset, required this.extentIndex, required this.extentOffset});

  const CodeLineSelection.collapsed({required int index, required int offset})
    : baseIndex = index,
      baseOffset = offset,
      extentIndex = index,
      extentOffset = offset;

  final int baseIndex, baseOffset, extentIndex, extentOffset;

  bool get isCollapsed => baseIndex == extentIndex && baseOffset == extentOffset;
  bool get _baseFirst => baseIndex < extentIndex || (baseIndex == extentIndex && baseOffset <= extentOffset);
  int get startIndex => _baseFirst ? baseIndex : extentIndex;
  int get startOffset => _baseFirst ? baseOffset : extentOffset;
  int get endIndex => _baseFirst ? extentIndex : baseIndex;
  int get endOffset => _baseFirst ? extentOffset : baseOffset;

  CodeLineSelection collapseTo(int index, int offset) => CodeLineSelection.collapsed(index: index, offset: offset);

  @override
  bool operator ==(Object other) =>
      other is CodeLineSelection &&
      other.baseIndex == baseIndex &&
      other.baseOffset == baseOffset &&
      other.extentIndex == extentIndex &&
      other.extentOffset == extentOffset;

  @override
  int get hashCode => Object.hash(baseIndex, baseOffset, extentIndex, extentOffset);

  @override
  String toString() => 'CodeLineSelection($baseIndex:$baseOffset → $extentIndex:$extentOffset)';
}

typedef CodeLineSpanBuilder = TextSpan Function({
  required BuildContext context,
  required int index,
  required CodeLine codeLine,
  required TextSpan textSpan,
  required TextStyle style,
});

class _Change {
  const _Change(this.line, this.column, this.removed, this.inserted);

  final int line, column;
  final String removed, inserted;
}

class _Step {
  _Step(this.changes, this.before, this.after, this.typing) : cursors = before.length;

  final List<_Change> changes;
  final List<CodeLineSelection> before;
  List<CodeLineSelection> after;
  final int cursors;

  /// Letters typed in a row undo together, as one step.
  bool typing;
  DateTime at = DateTime.now();
}

const _closers = {'(': ')', '[': ']', '{': '}', '"': '"', "'": "'", '`': '`'};
final _wordChar = RegExp(r'[A-Za-z0-9_$]');

class CodeLineEditingController extends ChangeNotifier {
  CodeLineEditingController({CodeLines? codeLines, this.options = const CodeLineOptions(), this.spanBuilder})
    : _lines = codeLines == null ? [''] : List.of(codeLines._lines) {
    _codeLines = CodeLines(List.of(_lines), const {});
  }

  final CodeLineOptions options;
  final CodeLineSpanBuilder? spanBuilder;

  List<String> _lines;
  final Map<int, int> _folded = {};
  late CodeLines _codeLines;
  CodeLineSelection _selection = const CodeLineSelection.collapsed(index: 0, offset: 0);

  /// Every cursor beyond the main one. Edits and movement apply to all of them.
  List<CodeLineSelection> _extras = const [];

  int? _stickyColumn;
  final _undo = <_Step>[];
  final _redo = <_Step>[];

  /// Bumped when what's painted changes without the text changing, such as new analyzer colors.
  int paintVersion = 0;

  /// First line whose syntax state may have changed.
  int dirtyFrom = 0;

  /// Set by the editor showing this document.
  void Function({required bool center})? onReveal;
  bool _revealPending = false;
  bool _revealCenter = false;

  CodeLines get codeLines => _codeLines;
  CodeLineSelection get selection => _selection;
  List<CodeLineSelection> get extraSelections => _extras;
  int get lineCount => _lines.length;
  Map<int, int> get foldedRanges => _folded;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String get _break => options.lineBreak == TextLineBreak.crlf ? '\r\n' : '\n';
  String get text => _lines.join(_break);

  set text(String value) {
    final before = _allSelections;
    final previous = text;
    _lines = splitLines(value);
    _folded.clear();
    _extras = const [];
    _selection = _clamp(_selection);
    _record(_Step([_Change(0, 0, previous.replaceAll('\r\n', '\n'), _lines.join('\n'))], before, _allSelections, false));
    _changed(from: 0);
  }

  List<CodeLineSelection> get _allSelections => [_selection, ..._extras];

  set selection(CodeLineSelection value) {
    _extras = const [];
    _stickyColumn = null;
    _setSelection(_clamp(value));
  }

  void _setSelection(CodeLineSelection value) {
    if (value == _selection) {
      notifyListeners();
      return;
    }
    _selection = value;
    notifyListeners();
  }

  CodeLineSelection _clamp(CodeLineSelection s) {
    int line(int i) => i.clamp(0, _lines.length - 1);
    int col(int l, int c) => c.clamp(0, _lines[l].length);
    final b = line(s.baseIndex), e = line(s.extentIndex);
    return CodeLineSelection(baseIndex: b, baseOffset: col(b, s.baseOffset), extentIndex: e, extentOffset: col(e, s.extentOffset));
  }

  void _changed({required int from}) {
    _codeLines = CodeLines(List.of(_lines), Map.of(_folded));
    dirtyFrom = min(dirtyFrom, from);
    notifyListeners();
  }

  void forceRepaint() {
    paintVersion++;
    notifyListeners();
  }

  String get selectedText => _textIn(_selection);

  String _textIn(CodeLineSelection s) {
    if (s.startIndex == s.endIndex) return _lines[s.startIndex].substring(s.startOffset, s.endOffset);
    return [
      _lines[s.startIndex].substring(s.startOffset),
      for (var i = s.startIndex + 1; i < s.endIndex; i++) _lines[i],
      _lines[s.endIndex].substring(0, s.endOffset),
    ].join(_break);
  }

  // ------------------------------------------------------------- editing core

  /// Replaces a range in the lines; returns where the new text ends.
  (int, int) _splice(int startLine, int startCol, int endLine, int endCol, String inserted) {
    final parts = inserted.split('\n');
    final head = _lines[startLine].substring(0, startCol);
    final tail = _lines[endLine].substring(endCol);
    final replacement = parts.length == 1
        ? ['$head${parts.first}$tail']
        : ['$head${parts.first}', ...parts.sublist(1, parts.length - 1), '${parts.last}$tail'];
    _lines.replaceRange(startLine, endLine + 1, replacement);
    final delta = replacement.length - (endLine - startLine + 1);
    if (_folded.isNotEmpty) _moveFolds(startLine, endLine, delta);
    final endCursorCol = parts.length == 1 ? startCol + parts.first.length : parts.last.length;
    return (startLine + parts.length - 1, endCursorCol);
  }

  void _moveFolds(int startLine, int endLine, int delta) {
    final moved = <int, int>{};
    _folded.forEach((start, end) {
      // An edit touching a folded block opens it, so nothing changes out of sight.
      if (start <= endLine && end >= startLine) return;
      if (start > endLine) {
        moved[start + delta] = end + delta;
      } else {
        moved[start] = end;
      }
    });
    _folded
      ..clear()
      ..addAll(moved);
  }

  void _record(_Step step) {
    _redo.clear();
    final last = _undo.isEmpty ? null : _undo.last;
    if (step.typing && last != null && last.typing && step.at.difference(last.at).inMilliseconds < 800 && step.cursors == last.cursors) {
      last.changes.addAll(step.changes);
      last.after = step.after;
      last.at = step.at;
      return;
    }
    _undo.add(step);
    if (_undo.length > 2000) _undo.removeAt(0);
  }

  static int _byStart(CodeLineSelection a, CodeLineSelection b) => a.startIndex != b.startIndex
      ? a.startIndex - b.startIndex
      : a.startOffset != b.startOffset
      ? a.startOffset - b.startOffset
      : a.endIndex != b.endIndex
      ? a.endIndex - b.endIndex
      : a.endOffset - b.endOffset;

  /// Cursors can come to overlap, as when Backspace reaches back over the one before. Edits assume
  /// they don't, so overlapping ones become one.
  void _mergeCursors() {
    if (_extras.isEmpty) return;
    final sorted = [..._allSelections]..sort(_byStart);
    bool startsBefore(int line, int col, int otherLine, int otherCol) => line < otherLine || (line == otherLine && col < otherCol);
    final merged = <CodeLineSelection>[];
    for (final s in sorted) {
      final last = merged.isEmpty ? null : merged.last;
      final overlaps =
          last != null &&
          (startsBefore(s.startIndex, s.startOffset, last.endIndex, last.endOffset) ||
              (s.startIndex == last.startIndex && s.startOffset == last.startOffset && s.endIndex == last.endIndex && s.endOffset == last.endOffset));
      if (!overlaps) {
        merged.add(s);
        continue;
      }
      final endsLater = startsBefore(last.endIndex, last.endOffset, s.endIndex, s.endOffset);
      merged.last = CodeLineSelection(
        baseIndex: last.startIndex,
        baseOffset: last.startOffset,
        extentIndex: endsLater ? s.endIndex : last.endIndex,
        extentOffset: endsLater ? s.endOffset : last.endOffset,
      );
    }
    if (merged.length == _extras.length + 1) return;
    final primary = merged.firstWhere(
      (m) => !startsBefore(_selection.startIndex, _selection.startOffset, m.startIndex, m.startOffset) && !startsBefore(m.endIndex, m.endOffset, _selection.endIndex, _selection.endOffset),
      orElse: () => merged.first,
    );
    _selection = primary;
    _extras = [
      for (final m in merged)
        if (!identical(m, primary)) m,
    ];
  }

  /// Applies [edit] at every cursor, first to last, keeping later cursors in place as lines come and go.
  void _editAll(String Function(CodeLineSelection s) edit, {bool typing = false, CodeLineSelection Function(int line, int col, CodeLineSelection original)? cursorAfter}) {
    final before = _allSelections;
    _mergeCursors();
    final order = [..._allSelections]..sort(_byStart);
    // Asked up front, since an edit may read the text under its cursor and the loop below changes it.
    final edits = {for (final s in order) s: edit(s).replaceAll('\r\n', '\n')};
    final changes = <_Change>[];
    final after = <CodeLineSelection, CodeLineSelection>{};
    var lineShift = 0, colShift = 0, lastEndLine = -1, firstLine = 1 << 30;
    for (final s in order) {
      final sameLine = s.startIndex == lastEndLine;
      final startLine = s.startIndex + lineShift;
      final startCol = s.startOffset + (sameLine ? colShift : 0);
      final endLine = s.endIndex + lineShift;
      final endCol = s.endOffset + (s.endIndex == lastEndLine ? colShift : 0);
      final inserted = edits[s]!;
      final removed = _rangeText(startLine, startCol, endLine, endCol);
      final (toLine, toCol) = _splice(startLine, startCol, endLine, endCol, inserted);
      changes.add(_Change(startLine, startCol, removed, inserted));
      firstLine = min(firstLine, startLine);
      after[s] = cursorAfter?.call(toLine, toCol, s) ?? CodeLineSelection.collapsed(index: toLine, offset: toCol);
      lineShift += (toLine - startLine) - (endLine - startLine);
      colShift = toCol - s.endOffset;
      lastEndLine = s.endIndex;
    }
    _selection = after[_selection]!;
    final seen = <CodeLineSelection>{_selection};
    _extras = [
      for (final e in _extras)
        if (seen.add(after[e]!)) after[e]!,
    ];
    _stickyColumn = null;
    _record(_Step(changes, before, _allSelections, typing));
    _changed(from: firstLine);
  }

  String _rangeText(int startLine, int startCol, int endLine, int endCol) {
    if (startLine == endLine) return _lines[startLine].substring(startCol, endCol);
    return [
      _lines[startLine].substring(startCol),
      for (var i = startLine + 1; i < endLine; i++) _lines[i],
      _lines[endLine].substring(0, endCol),
    ].join('\n');
  }

  void undo() {
    if (_undo.isEmpty) return;
    final step = _undo.removeLast();
    _redo.add(step);
    var from = 1 << 30;
    for (final c in step.changes.reversed) {
      from = min(from, _revert(c));
    }
    _restore(step.before);
    _changed(from: from == 1 << 30 ? 0 : from);
  }

  void redo() {
    if (_redo.isEmpty) return;
    final step = _redo.removeLast();
    _undo.add(step);
    var from = 1 << 30;
    for (final c in step.changes) {
      final (endLine, endCol) = _endOf(c.line, c.column, c.removed);
      _splice(c.line, c.column, endLine, endCol, c.inserted);
      from = min(from, c.line);
    }
    _restore(step.after);
    _changed(from: from == 1 << 30 ? 0 : from);
  }

  int _revert(_Change c) {
    final (endLine, endCol) = _endOf(c.line, c.column, c.inserted);
    _splice(c.line, c.column, endLine, endCol, c.removed);
    return c.line;
  }

  (int, int) _endOf(int line, int col, String text) {
    final parts = text.split('\n');
    return parts.length == 1 ? (line, col + text.length) : (line + parts.length - 1, parts.last.length);
  }

  void _restore(List<CodeLineSelection> all) {
    _selection = _clamp(all.first);
    _extras = [for (final s in all.skip(1)) _clamp(s)];
  }

  // ------------------------------------------------------------- typing

  void replaceSelection(String replacement, [CodeLineSelection? over]) {
    if (over != null) selection = over;
    _editAll((_) => replacement);
  }

  /// What the keyboard sends: closes brackets and quotes, and steps over a closer already there.
  void insertTyped(String typed, {bool autoClose = true}) {
    if (typed.length == 1 && autoClose) {
      final closer = _closers[typed];
      if (closer != null && _allSelections.every((s) => !s.isCollapsed)) {
        // Brackets around a selection wrap it, and the same text stays selected.
        _editAll((s) => '$typed${_textIn(s).replaceAll('\r\n', '\n')}$closer', typing: false);
        return;
      }
      if (_allSelections.every((s) => s.isCollapsed)) {
        if (_closers.containsValue(typed) && _allSelections.every((s) => _charAt(s.extentIndex, s.extentOffset) == typed)) {
          _mapAll((s) => s.collapseTo(s.extentIndex, s.extentOffset + 1));
          return;
        }
        if (closer != null && _allSelections.every((s) => _canAutoClose(s, typed))) {
          _editAll(
            (_) => '$typed$closer',
            typing: true,
            cursorAfter: (line, col, _) => CodeLineSelection.collapsed(index: line, offset: col - 1),
          );
          return;
        }
      }
    }
    _editAll((_) => typed, typing: !typed.contains('\n') && typed.length == 1 && !typed.contains(' '));
  }

  String _charAt(int line, int col) => col < _lines[line].length ? _lines[line][col] : '';

  bool _canAutoClose(CodeLineSelection s, String typed) {
    final next = _charAt(s.extentIndex, s.extentOffset);
    if (next.isNotEmpty && _wordChar.hasMatch(next)) return false;
    if (typed == '"' || typed == "'" || typed == '`') {
      final before = s.extentOffset > 0 ? _lines[s.extentIndex][s.extentOffset - 1] : '';
      return !(before.isNotEmpty && _wordChar.hasMatch(before));
    }
    return true;
  }

  void applyNewLine() {
    final betweenPair = <CodeLineSelection>{};
    _editAll(
      (s) {
        final line = _lines[s.startIndex];
        final indent = RegExp(r'^[ \t]*').firstMatch(line)![0]!;
        final before = line.substring(0, s.startOffset).trimRight();
        final after = _lines[s.endIndex].substring(s.endOffset).trimLeft();
        if (!(before.endsWith('{') || before.endsWith('[') || before.endsWith('('))) return '\n$indent';
        if (!(after.startsWith('}') || after.startsWith(']') || after.startsWith(')'))) return '\n$indent  ';
        // Between a pair the closer drops below the cursor.
        betweenPair.add(s);
        return '\n$indent  \n$indent';
      },
      cursorAfter: (line, col, s) => betweenPair.contains(s)
          ? CodeLineSelection.collapsed(index: line - 1, offset: _lines[line - 1].length)
          : CodeLineSelection.collapsed(index: line, offset: col),
    );
  }

  void deleteBackward() {
    if (_allSelections.every((s) => s.isCollapsed)) {
      _extendEachThenDelete((s) {
        final line = s.extentIndex, col = s.extentOffset;
        if (col == 0) return line == 0 ? s : CodeLineSelection(baseIndex: line - 1, baseOffset: _lines[line - 1].length, extentIndex: line, extentOffset: 0);
        final text = _lines[line];
        // Deleting the opener of an empty pair takes the closer too.
        final pair = _closers[text[col - 1]];
        final pairEnd = pair != null && col < text.length && text[col] == pair ? col + 1 : col;
        // Whole indent steps, so a tab press and one backspace cancel out.
        final leading = text.substring(0, col);
        final step = leading.trim().isEmpty && col >= 2 && col.isEven ? 2 : 1;
        return CodeLineSelection(baseIndex: line, baseOffset: col - step, extentIndex: line, extentOffset: pairEnd);
      });
    } else {
      _editAll((_) => '');
    }
  }

  void deleteForward() {
    if (_allSelections.every((s) => s.isCollapsed)) {
      _extendEachThenDelete((s) {
        final line = s.extentIndex, col = s.extentOffset;
        if (col < _lines[line].length) return CodeLineSelection(baseIndex: line, baseOffset: col, extentIndex: line, extentOffset: col + 1);
        return line + 1 < _lines.length ? CodeLineSelection(baseIndex: line, baseOffset: col, extentIndex: line + 1, extentOffset: 0) : s;
      });
    } else {
      _editAll((_) => '');
    }
  }

  void deleteWordBackward() => _allSelections.every((s) => s.isCollapsed)
      ? _extendEachThenDelete((s) {
          final (line, col) = _wordLeft(s.extentIndex, s.extentOffset);
          return CodeLineSelection(baseIndex: line, baseOffset: col, extentIndex: s.extentIndex, extentOffset: s.extentOffset);
        })
      : _editAll((_) => '');

  void deleteWordForward() => _allSelections.every((s) => s.isCollapsed)
      ? _extendEachThenDelete((s) {
          final (line, col) = _wordRight(s.extentIndex, s.extentOffset);
          return CodeLineSelection(baseIndex: s.extentIndex, baseOffset: s.extentOffset, extentIndex: line, extentOffset: col);
        })
      : _editAll((_) => '');

  void _extendEachThenDelete(CodeLineSelection Function(CodeLineSelection s) range) {
    final extended = {for (final s in _allSelections) s: range(s)};
    _selection = extended[_selection]!;
    _extras = [for (final e in _extras) extended[e]!];
    if (_allSelections.every((s) => s.isCollapsed)) return;
    _editAll((_) => '');
  }

  void deleteSelectionLines([bool keepExtentOffset = true]) {
    final s = _selection;
    final start = s.startIndex, end = s.endIndex;
    final col = s.extentOffset;
    _extras = const [];
    if (_lines.length == 1) {
      selection = CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: _lines[0].length);
      _editAll((_) => '');
      return;
    }
    final lastGoes = end == _lines.length - 1;
    selection = lastGoes
        ? CodeLineSelection(baseIndex: start - 1 < 0 ? 0 : start - 1, baseOffset: start == 0 ? 0 : _lines[start - 1].length, extentIndex: end, extentOffset: _lines[end].length)
        : CodeLineSelection(baseIndex: start, baseOffset: 0, extentIndex: end + 1, extentOffset: 0);
    _editAll((_) => '');
    if (keepExtentOffset) {
      final line = _selection.extentIndex;
      selection = CodeLineSelection.collapsed(index: line, offset: col.clamp(0, _lines[line].length));
    }
  }

  void applyIndent() {
    if (_allSelections.every((s) => s.isCollapsed)) {
      _editAll((s) => ' ' * (2 - s.extentOffset % 2));
      return;
    }
    _shiftLines(2);
  }

  void applyOutdent() => _shiftLines(-2);

  /// Indents or outdents every line a selection touches.
  void _shiftLines(int by) {
    final before = _allSelections;
    final lines = {for (final s in before) for (var i = s.startIndex; i <= s.endIndex; i++) i}.toList()..sort();
    final changes = <_Change>[];
    final moved = <int, int>{};
    for (final i in lines) {
      if (by > 0) {
        if (_lines[i].isEmpty && lines.length > 1) continue;
        changes.add(_Change(i, 0, '', ' ' * by));
        _lines[i] = '${' ' * by}${_lines[i]}';
        moved[i] = by;
      } else {
        final remove = min(-by, RegExp(r'^ *').firstMatch(_lines[i])![0]!.length);
        if (remove == 0) continue;
        changes.add(_Change(i, 0, ' ' * remove, ''));
        _lines[i] = _lines[i].substring(remove);
        moved[i] = -remove;
      }
    }
    if (changes.isEmpty) return;
    CodeLineSelection shift(CodeLineSelection s) => CodeLineSelection(
      baseIndex: s.baseIndex,
      baseOffset: max(0, s.baseOffset + (moved[s.baseIndex] ?? 0)),
      extentIndex: s.extentIndex,
      extentOffset: max(0, s.extentOffset + (moved[s.extentIndex] ?? 0)),
    );
    _selection = shift(_selection);
    _extras = [for (final e in _extras) shift(e)];
    _record(_Step(changes, before, _allSelections, false));
    _changed(from: lines.first);
  }

  void moveSelectionLinesUp() => _moveLines(-1);
  void moveSelectionLinesDown() => _moveLines(1);

  void _moveLines(int direction) {
    final s = _selection;
    final start = s.startIndex, end = s.endIndex;
    if (direction < 0 ? start == 0 : end == _lines.length - 1) return;
    _extras = const [];
    final before = _allSelections;
    final blockStart = direction < 0 ? start - 1 : start;
    final blockEnd = direction < 0 ? end : end + 1;
    final removed = _lines.sublist(blockStart, blockEnd + 1).join('\n');
    final moved = direction < 0
        ? [..._lines.sublist(start, end + 1), _lines[start - 1]]
        : [_lines[end + 1], ..._lines.sublist(start, end + 1)];
    _lines.replaceRange(blockStart, blockEnd + 1, moved);
    _selection = CodeLineSelection(baseIndex: s.baseIndex + direction, baseOffset: s.baseOffset, extentIndex: s.extentIndex + direction, extentOffset: s.extentOffset);
    _record(_Step([_Change(blockStart, 0, removed, moved.join('\n'))], before, _allSelections, false));
    _changed(from: blockStart);
  }

  // ------------------------------------------------------------- comments

  void toggleLineComment(String prefix) {
    final before = _allSelections;
    final s = _selection;
    final targets = [for (var i = s.startIndex; i <= s.endIndex; i++) if (_lines[i].trim().isNotEmpty || s.isCollapsed) i];
    if (targets.isEmpty) return;
    final allCommented = targets.every((i) => _lines[i].trimLeft().startsWith(prefix));
    final indent = targets.map((i) => RegExp(r'^\s*').firstMatch(_lines[i])![0]!.length).reduce(min);
    final changes = <_Change>[];
    final moved = <int, int>{};
    for (final i in targets) {
      if (allCommented) {
        final at = _lines[i].indexOf(prefix);
        final length = prefix.length + (_lines[i].startsWith(' ', at + prefix.length) ? 1 : 0);
        changes.add(_Change(i, at, _lines[i].substring(at, at + length), ''));
        _lines[i] = _lines[i].replaceRange(at, at + length, '');
        moved[i] = -length;
      } else {
        changes.add(_Change(i, indent, '', '$prefix '));
        _lines[i] = _lines[i].replaceRange(indent, indent, '$prefix ');
        moved[i] = prefix.length + 1;
      }
    }
    _selection = CodeLineSelection(
      baseIndex: s.baseIndex,
      baseOffset: max(0, s.baseOffset + (moved[s.baseIndex] ?? 0)),
      extentIndex: s.extentIndex,
      extentOffset: max(0, s.extentOffset + (moved[s.extentIndex] ?? 0)),
    );
    _extras = const [];
    _record(_Step(changes, before, _allSelections, false));
    _changed(from: targets.first);
  }

  void toggleBlockComment([String open = '/*', String close = '*/']) {
    bool commented(String t) => t.startsWith(open) && t.endsWith(close) && t.length >= open.length + close.length;
    final all = {for (final s in _allSelections) s: _textIn(s).replaceAll('\r\n', '\n')};
    if (all.values.every(commented)) {
      _editAll((s) {
        final inner = _textIn(s).replaceAll('\r\n', '\n');
        return commented(inner) ? inner.substring(open.length, inner.length - close.length) : inner;
      });
      return;
    }
    _editAll(
      (s) => '$open${_textIn(s).replaceAll('\r\n', '\n')}$close',
      cursorAfter: (line, col, s) => s.isCollapsed ? CodeLineSelection.collapsed(index: line, offset: col - close.length) : CodeLineSelection.collapsed(index: line, offset: col),
    );
  }

  // ------------------------------------------------------------- cursors

  void _mapAll(CodeLineSelection Function(CodeLineSelection s) move) {
    final all = {for (final s in _allSelections) s: _clamp(move(s))};
    _selection = all[_selection]!;
    // Cursors that land on each other become one.
    final seen = <CodeLineSelection>{_selection};
    _extras = [
      for (final e in _extras)
        if (seen.add(all[e]!)) all[e]!,
    ];
    notifyListeners();
    _revealIfBound(center: false);
  }

  void selectAll() {
    _extras = const [];
    _setSelection(CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: _lines.length - 1, extentOffset: _lines.last.length));
  }

  void selectLine(int index) => selection = index + 1 < _lines.length
      ? CodeLineSelection(baseIndex: index, baseOffset: 0, extentIndex: index + 1, extentOffset: 0)
      : CodeLineSelection(baseIndex: index, baseOffset: 0, extentIndex: index, extentOffset: _lines[index].length);

  /// One cursor again, and nothing selected.
  void cancelSelection() {
    _extras = const [];
    _setSelection(_selection.collapseTo(_selection.extentIndex, _selection.extentOffset));
  }

  bool get hasExtraCursors => _extras.isNotEmpty;

  void clearExtraCursors() {
    if (_extras.isEmpty) return;
    _extras = const [];
    notifyListeners();
  }

  void addCursor(CodeLineSelection s) {
    final clamped = _clamp(s);
    if (clamped == _selection || _extras.contains(clamped)) return;
    _extras = [..._extras, _selection];
    _selection = clamped;
    notifyListeners();
    _revealIfBound(center: true);
  }

  /// Ctrl+D: a word first, then each next match gets its own cursor.
  void selectNextOccurrence() {
    final s = _selection;
    if (s.isCollapsed) {
      final text = _lines[s.extentIndex];
      final at = s.extentOffset;
      var start = at, end = at;
      while (start > 0 && _wordChar.hasMatch(text[start - 1])) {
        start--;
      }
      while (end < text.length && _wordChar.hasMatch(text[end])) {
        end++;
      }
      if (start == end) return;
      _setSelection(CodeLineSelection(baseIndex: s.extentIndex, baseOffset: start, extentIndex: s.extentIndex, extentOffset: end));
      return;
    }
    final query = selectedText;
    if (query.contains('\n')) return;
    final hit = nextMatchAfter(_lines, query, s.endIndex, s.endOffset, _allSelections);
    if (hit == null) return;
    addCursor(CodeLineSelection(baseIndex: hit.$1, baseOffset: hit.$2, extentIndex: hit.$1, extentOffset: hit.$2 + query.length));
  }

  int _nextVisible(int line, int direction) {
    var next = line + direction;
    if (direction > 0) {
      final end = _folded[line];
      if (end != null) next = end + 1;
    } else {
      for (final e in _folded.entries) {
        if (next > e.key && next <= e.value) next = e.key;
      }
    }
    return next.clamp(0, _lines.length - 1);
  }

  CodeLineSelection _moved(CodeLineSelection s, int line, int col, bool extend) =>
      extend ? CodeLineSelection(baseIndex: s.baseIndex, baseOffset: s.baseOffset, extentIndex: line, extentOffset: col) : CodeLineSelection.collapsed(index: line, offset: col);

  void moveHorizontal(int direction, {bool extend = false}) {
    _stickyColumn = null;
    _mapAll((s) {
      if (!extend && !s.isCollapsed) {
        return direction < 0 ? s.collapseTo(s.startIndex, s.startOffset) : s.collapseTo(s.endIndex, s.endOffset);
      }
      var line = s.extentIndex, col = s.extentOffset + direction;
      if (col < 0) {
        if (line == 0) return _moved(s, 0, 0, extend);
        line = _nextVisible(line, -1);
        col = _lines[line].length;
      } else if (col > _lines[line].length) {
        if (line == _lines.length - 1) return _moved(s, line, _lines[line].length, extend);
        line = _nextVisible(line, 1);
        col = 0;
      }
      return _moved(s, line, col, extend);
    });
  }

  void moveVertical(int direction, {bool extend = false, int count = 1}) {
    final sticky = _stickyColumn ?? _selection.extentOffset;
    _mapAll((s) {
      var line = s.extentIndex;
      for (var i = 0; i < count; i++) {
        line = _nextVisible(line, direction);
      }
      if (line == s.extentIndex) return _moved(s, line, direction < 0 ? 0 : _lines[line].length, extend);
      return _moved(s, line, min(identical(s, _selection) ? sticky : s.extentOffset, _lines[line].length), extend);
    });
    _stickyColumn = sticky;
  }

  void moveToLineStart({bool extend = false}) {
    _stickyColumn = null;
    _mapAll((s) {
      final text = _lines[s.extentIndex];
      final first = RegExp(r'^\s*').firstMatch(text)![0]!.length;
      // Home goes to the code first, then to the margin.
      return _moved(s, s.extentIndex, s.extentOffset == first ? 0 : first, extend);
    });
  }

  void moveToLineEnd({bool extend = false}) {
    _stickyColumn = null;
    _mapAll((s) => _moved(s, s.extentIndex, _lines[s.extentIndex].length, extend));
  }

  void moveCursorToLineEnd() => moveToLineEnd();

  void moveToDocumentEdge({required bool start, bool extend = false}) {
    _stickyColumn = null;
    _extras = const [];
    _mapAll((s) => start ? _moved(s, 0, 0, extend) : _moved(s, _lines.length - 1, _lines.last.length, extend));
  }

  (int, int) _wordLeft(int line, int col) {
    if (col == 0) return line == 0 ? (0, 0) : (line - 1, _lines[line - 1].length);
    final text = _lines[line];
    var i = col;
    while (i > 0 && text[i - 1] == ' ') {
      i--;
    }
    if (i > 0 && _wordChar.hasMatch(text[i - 1])) {
      while (i > 0 && _wordChar.hasMatch(text[i - 1])) {
        i--;
      }
    } else if (i > 0) {
      i--;
    }
    return (line, i);
  }

  (int, int) _wordRight(int line, int col) {
    final text = _lines[line];
    if (col >= text.length) return line == _lines.length - 1 ? (line, col) : (line + 1, 0);
    var i = col;
    if (_wordChar.hasMatch(text[i])) {
      while (i < text.length && _wordChar.hasMatch(text[i])) {
        i++;
      }
    } else if (text[i] != ' ') {
      i++;
    }
    while (i < text.length && text[i] == ' ') {
      i++;
    }
    return (line, i);
  }

  void moveCursorToWordBoundaryBackward() => _word(left: true, extend: false);
  void moveCursorToWordBoundaryForward() => _word(left: false, extend: false);
  void extendSelectionToWordBoundaryBackward() => _word(left: true, extend: true);
  void extendSelectionToWordBoundaryForward() => _word(left: false, extend: true);

  void _word({required bool left, required bool extend}) {
    _stickyColumn = null;
    _mapAll((s) {
      final (line, col) = left ? _wordLeft(s.extentIndex, s.extentOffset) : _wordRight(s.extentIndex, s.extentOffset);
      return _moved(s, line, col, extend);
    });
  }

  // ------------------------------------------------------------- clipboard

  Future<void> copy() async {
    final s = _selection;
    final text = s.isCollapsed ? '${_lines[s.extentIndex]}$_break' : [for (final x in _allSelections) _textIn(x)].join(_break);
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> cut() async {
    await copy();
    if (_selection.isCollapsed && _extras.isEmpty) {
      deleteSelectionLines();
    } else {
      _editAll((_) => '');
    }
  }

  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final normal = text.replaceAll('\r\n', '\n');
    // As many lines as cursors: each cursor gets its own.
    final parts = normal.split('\n');
    _mergeCursors();
    if (_extras.isNotEmpty && parts.length == _extras.length + 1) {
      final order = [..._allSelections]..sort(_byStart);
      _editAll((s) => parts[order.indexOf(s)]);
    } else {
      _editAll((_) => normal);
    }
    _revealIfBound(center: false);
  }

  // ------------------------------------------------------------- folding

  void collapseChunk(int start, int end) {
    if (end <= start) return;
    _folded[start] = end;
    final s = _selection;
    if (s.extentIndex > start && s.extentIndex <= end) selection = CodeLineSelection.collapsed(index: start, offset: _lines[start].length);
    _changed(from: start);
  }

  void expandChunk(int index) {
    if (_folded.remove(index) == null) return;
    _changed(from: index);
  }

  // ------------------------------------------------------------- view

  void makeCursorVisible() => _revealIfBound(center: false);
  void makeCursorCenterIfInvisible() => _revealIfBound(center: true);

  void _revealIfBound({required bool center}) {
    final reveal = onReveal;
    if (reveal == null) {
      _revealPending = true;
      _revealCenter = center;
      return;
    }
    reveal(center: center);
  }

  /// For an editor that just attached: a jump asked for before it existed.
  bool takePendingReveal() {
    final pending = _revealPending;
    _revealPending = false;
    return pending;
  }

  bool get pendingRevealCenter => _revealCenter;
}

/// Next [query] after a position, wrapping around, skipping what's already selected.
(int, int)? nextMatchAfter(List<String> lines, String query, int fromLine, int fromColumn, List<CodeLineSelection> taken) {
  if (query.isEmpty || lines.isEmpty) return null;
  bool isTaken(int line, int col) => taken.any((s) => s.startIndex == line && s.startOffset == col);
  for (var i = 0; i <= lines.length; i++) {
    final index = (fromLine + i) % lines.length;
    var at = i == 0 ? fromColumn.clamp(0, lines[index].length) : 0;
    while (true) {
      at = lines[index].indexOf(query, at);
      if (at < 0) break;
      if (!isTaken(index, at)) return (index, at);
      at++;
    }
  }
  return null;
}
