import 'package:hotrestart/core/equatable.dart';
import 'package:hotrestart/core/theme.dart';
import 'package:hotrestart/modules/editor/engine/code_model.dart';
import 'package:hotrestart/modules/editor/engine/syntax.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

CodeLineEditingController editor(String text, {int line = 0, int col = 0}) {
  final c = CodeLineEditingController(codeLines: CodeLines.fromText(text));
  c.selection = CodeLineSelection.collapsed(index: line, offset: col);
  return c;
}

class _Point extends Equatable {
  const _Point(this.x, this.tags);

  final int x;
  final List<String> tags;

  @override
  List<Object?> get props => [x, tags];
}

void main() {
  group('typing', () {
    test('inserts at the caret, across lines, keeping CRLF', () {
      final c = CodeLineEditingController(codeLines: CodeLines.fromText('ab\r\ncd'), options: const CodeLineOptions(lineBreak: TextLineBreak.crlf));
      c.selection = const CodeLineSelection.collapsed(index: 1, offset: 1);
      c.replaceSelection('X\nY');
      expect(c.text, 'ab\r\ncX\r\nYd');
      expect(c.selection.extentIndex, 2);
      expect(c.selection.extentOffset, 1);
    });

    test('brackets close themselves and the closer is stepped over', () {
      final c = editor('');
      c.insertTyped('(');
      expect(c.text, '()');
      expect(c.selection.extentOffset, 1);
      c.insertTyped('a');
      c.insertTyped(')');
      expect(c.text, '(a)');
      expect(c.selection.extentOffset, 3);
    });

    test('a quote after a word stays single, and brackets wrap a selection', () {
      final c = editor('dont');
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 4);
      c.insertTyped("'");
      expect(c.text, "dont'");
      final w = editor('word');
      w.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 4);
      w.insertTyped('[');
      expect(w.text, '[word]');
    });

    test('Enter keeps the indent, and opens a block between brackets', () {
      final plain = editor('  a', col: 3);
      plain.applyNewLine();
      expect(plain.text, '  a\n  ');
      final block = editor('f() {}', col: 5);
      block.applyNewLine();
      expect(block.text, 'f() {\n  \n}');
      expect((block.selection.extentIndex, block.selection.extentOffset), (1, 2));
    });

    test('backspace takes a pair, a whole indent, and joins lines', () {
      final pair = editor('()', col: 1);
      pair.deleteBackward();
      expect(pair.text, '');
      final indent = editor('    x', col: 4);
      indent.deleteBackward();
      expect(indent.text, '  x');
      final join = editor('a\nb', line: 1);
      join.deleteBackward();
      expect(join.text, 'ab');
      expect(join.selection.extentOffset, 1);
      final start = editor('a');
      start.deleteBackward();
      expect(start.text, 'a');
    });

    test('Delete and word deletes', () {
      final d = editor('a\nb', col: 1);
      d.deleteForward();
      expect(d.text, 'ab');
      final w = editor('foo bar', col: 7);
      w.deleteWordBackward();
      expect(w.text, 'foo ');
      final f = editor('foo bar');
      f.deleteWordForward();
      expect(f.text, 'bar');
    });
  });

  group('undo', () {
    test('undo and redo restore text and caret', () {
      final c = editor('ab', col: 2);
      c.replaceSelection('\ncd');
      expect(c.text, 'ab\ncd');
      c.undo();
      expect(c.text, 'ab');
      expect(c.selection.extentOffset, 2);
      c.redo();
      expect(c.text, 'ab\ncd');
      expect(c.selection.extentIndex, 1);
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 1, extentIndex: 1, extentOffset: 1);
      c.replaceSelection('Z');
      expect(c.text, 'aZd');
      c.undo();
      expect(c.text, 'ab\ncd');
    });

    test('letters typed in a row undo as one', () {
      final c = editor('');
      for (final ch in 'abc'.split('')) {
        c.insertTyped(ch);
      }
      expect(c.text, 'abc');
      c.undo();
      expect(c.text, '');
    });

    test('a whole-text change undoes too', () {
      final c = editor('one\ntwo');
      c.text = 'three';
      expect(c.text, 'three');
      c.undo();
      expect(c.text, 'one\ntwo');
    });

    test('a line move and a comment undo', () {
      final c = editor('a\nb');
      c.moveSelectionLinesDown();
      expect(c.text, 'b\na');
      expect(c.selection.extentIndex, 1);
      c.undo();
      expect(c.text, 'a\nb');
      c.toggleLineComment('//');
      expect(c.text, '// a\nb');
      c.undo();
      expect(c.text, 'a\nb');
    });
  });

  group('multiple cursors', () {
    test('Ctrl+D picks the word, then adds a cursor at each next match', () {
      final c = editor('foo x foo\nfoo', col: 1);
      c.selectNextOccurrence();
      expect(c.selectedText, 'foo');
      expect(c.extraSelections, isEmpty);
      c.selectNextOccurrence();
      expect(c.extraSelections.length, 1);
      expect(c.selection.startOffset, 6);
      c.selectNextOccurrence();
      expect(c.extraSelections.length, 2);
      expect(c.selection.startIndex, 1);
      // Everything is taken: another press finds nothing new.
      c.selectNextOccurrence();
      expect(c.extraSelections.length, 2);
    });

    test('typing replaces every selection, on one line and across lines', () {
      final c = editor('foo x foo\nfoo', col: 1);
      c.selectNextOccurrence();
      c.selectNextOccurrence();
      c.selectNextOccurrence();
      c.insertTyped('b', autoClose: false);
      expect(c.text, 'b x b\nb');
      c.undo();
      expect(c.text, 'foo x foo\nfoo');
      expect(c.extraSelections.length, 2);
    });

    test('new lines at several cursors keep the rest in place', () {
      final c = editor('a b', col: 1);
      c.addCursor(const CodeLineSelection.collapsed(index: 0, offset: 3));
      c.replaceSelection('\n');
      expect(c.text, 'a\n b\n');
      expect(c.lineCount, 3);
      c.insertTyped('z');
      expect(c.text, 'a\nz b\nz');
    });

    test('movement applies to all, cursors that meet merge, Esc-style clear leaves one', () {
      final c = editor('abcd', col: 1);
      c.addCursor(const CodeLineSelection.collapsed(index: 0, offset: 3));
      c.moveHorizontal(1);
      expect(c.selection.extentOffset, 4);
      expect(c.extraSelections.single.extentOffset, 2);
      c.moveToLineEnd();
      expect(c.extraSelections, isEmpty);
      c.addCursor(const CodeLineSelection.collapsed(index: 0, offset: 0));
      c.clearExtraCursors();
      expect(c.hasExtraCursors, isFalse);
    });
  });

  group('lines', () {
    test('delete line, in the middle and at the end', () {
      final c = editor('a\nb\nc', line: 1);
      c.deleteSelectionLines();
      expect(c.text, 'a\nc');
      c.selection = const CodeLineSelection.collapsed(index: 1, offset: 0);
      c.deleteSelectionLines();
      expect(c.text, 'a');
      c.deleteSelectionLines();
      expect(c.text, '');
    });

    test('indent and outdent every selected line', () {
      final c = editor('a\nb');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 1, extentOffset: 1);
      c.applyIndent();
      expect(c.text, '  a\n  b');
      c.applyOutdent();
      expect(c.text, 'a\nb');
    });

    test('Tab at a caret goes to the next even column', () {
      final c = editor('abc', col: 3);
      c.applyIndent();
      expect(c.text, 'abc ');
    });

    test('line comments toggle at the shared indent', () {
      final c = editor('  a\n    b');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 1, extentOffset: 1);
      c.toggleLineComment('//');
      expect(c.text, '  // a\n  //   b');
      c.toggleLineComment('//');
      expect(c.text, '  a\n    b');
    });

    test('block comments wrap and unwrap', () {
      final c = editor('abc');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 3);
      c.toggleBlockComment();
      expect(c.text, '/*abc*/');
    });

    test('Home goes to the code, then to the margin', () {
      final c = editor('  abc', col: 4);
      c.moveToLineStart();
      expect(c.selection.extentOffset, 2);
      c.moveToLineStart();
      expect(c.selection.extentOffset, 0);
    });

    test('up and down remember the column across short lines', () {
      final c = editor('long line\nx\nlong line', col: 6);
      c.moveVertical(1);
      expect(c.selection.extentOffset, 1);
      c.moveVertical(1);
      expect(c.selection.extentOffset, 6);
    });

    test('word movement', () {
      final c = editor('foo.bar baz');
      c.moveCursorToWordBoundaryForward();
      expect(c.selection.extentOffset, 3);
      c.moveCursorToWordBoundaryForward();
      expect(c.selection.extentOffset, 4);
      c.moveCursorToWordBoundaryForward();
      expect(c.selection.extentOffset, 8);
      c.moveCursorToWordBoundaryBackward();
      expect(c.selection.extentOffset, 4);
    });

    test('folding hides lines from movement, keeps them in the text, and an edit inside opens it', () {
      final c = editor('a {\n  b\n}\nc');
      c.collapseChunk(0, 2);
      expect(c.codeLines[0].chunkParent, isTrue);
      expect(c.text, 'a {\n  b\n}\nc');
      expect(c.codeLines.length, 4);
      c.moveVertical(1);
      expect(c.selection.extentIndex, 3);
      c.moveVertical(-1);
      expect(c.selection.extentIndex, 0);
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 1);
      c.replaceSelection('!');
      expect(c.foldedRanges, isEmpty);
    });

    test('folds below an edit follow it', () {
      final c = editor('x\na {\n  b\n}');
      c.collapseChunk(1, 3);
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 1);
      c.replaceSelection('\n');
      expect(c.foldedRanges, {2: 4});
    });

    test('every text change is a new CodeLines, a caret move is not', () {
      final c = editor('a');
      final before = c.codeLines;
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 1);
      expect(identical(c.codeLines, before), isTrue);
      c.insertTyped('b');
      expect(identical(c.codeLines, before), isFalse);
      expect(before[0].text, 'a', reason: 'an older snapshot stays as it was');
    });

    test('selections clamp to the text', () {
      final c = editor('ab');
      c.selection = const CodeLineSelection.collapsed(index: 9, offset: 9);
      expect((c.selection.extentIndex, c.selection.extentOffset), (0, 2));
    });
  });

  group('syntax', () {
    List<(String, TokenKind)> tokens(String text, String ext) {
      final (found, _) = tokenizeLine(text, languageForExtension(ext)!, const LexState.code());
      return [for (final t in found) (text.substring(t.start, t.end), t.kind)];
    }

    test('Dart', () {
      expect(tokens("final a = Foo(1, 'x'); // note", '.dart'), [
        ('final', TokenKind.keyword),
        ('Foo', TokenKind.type),
        ('1', TokenKind.number),
        ("'x'", TokenKind.string),
        ('// note', TokenKind.comment),
      ]);
      expect(tokens('if (x) return run();', '.dart').map((t) => t.$2), [TokenKind.control, TokenKind.control, TokenKind.function]);
      expect(tokens('@override', '.dart').single.$2, TokenKind.annotation);
    });

    test('comments and long strings carry over lines', () {
      final dart = languageForExtension('.dart')!;
      var (found, state) = tokenizeLine('a /* b', dart, const LexState.code());
      expect(found.single.kind, TokenKind.comment);
      expect(state.blockDepth, 1);
      (found, state) = tokenizeLine('still', dart, state);
      expect(found.single.kind, TokenKind.comment);
      (found, state) = tokenizeLine('end */ final', dart, state);
      expect(found.map((t) => t.kind), [TokenKind.comment, TokenKind.keyword]);
      expect(state.same(const LexState.code()), isTrue);
      (found, state) = tokenizeLine("x = '''abc", dart, const LexState.code());
      expect(state.tripleQuote, "'''");
      (found, state) = tokenizeLine("def''' 1", dart, state);
      expect(found.map((t) => t.kind), [TokenKind.string, TokenKind.number]);
    });

    test('escapes and raw strings end where they should', () {
      expect(tokens(r"'a\'b' 1", '.dart').map((t) => t.$1), [r"'a\'b'", '1']);
      expect(tokens(r"r'a\' 1", '.dart').map((t) => t.$1), [r"'a\'", '1']);
    });

    test('other languages', () {
      expect(tokens('name: 1 # x', '.yaml').map((t) => t.$2), [TokenKind.type, TokenKind.number, TokenKind.comment]);
      expect(tokens('{"a": true}', '.json').map((t) => t.$2), [TokenKind.string, TokenKind.keyword]);
      expect(tokens('<a href="x">', '.xml').first.$2, TokenKind.tag);
      expect(tokens('# Title', '.md').single.$2, TokenKind.keyword);
      expect(tokens(r'echo $HOME', '.sh').map((t) => t.$2), [TokenKind.keyword, TokenKind.type]);
      expect(tokens('IF (x)', '.ps1').first.$2, TokenKind.control);
      expect(languageForExtension('.unknown'), isNull);
    });

    test('a highlighted line keeps its exact text', () {
      const line = "  final a = 'b'; // c";
      final (found, _) = tokenizeLine(line, languageForExtension('.dart')!, const LexState.code());
      final span = spanForLine(line, found, appThemes.first.syntax, const TextStyle());
      expect(span.toPlainText(), line);
      expect(highlightSnippet('a\nb', '.dart', appThemes.first.syntax, const TextStyle()).toPlainText(), 'a\nb');
    });
  });

  test('Equatable looks inside collections', () {
    expect(const _Point(1, ['a']), const _Point(1, ['a']));
    expect(const _Point(1, ['a']).hashCode, const _Point(1, ['a']).hashCode);
    expect(const _Point(1, ['a']) == const _Point(1, ['b']), isFalse);
    expect(const _Point(1, ['a']) == const _Point(2, ['a']), isFalse);
  });

  group('cursors that meet', () {
    CodeLineEditingController editor(String text) => CodeLineEditingController(codeLines: CodeLines.fromText(text));

    test('Backspace with cursors side by side takes each character once', () {
      final c = editor('abcd');
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 2);
      c.addCursor(const CodeLineSelection.collapsed(index: 0, offset: 3));
      c.deleteBackward();
      expect(c.text, 'ad');
      expect(c.extraSelections, isEmpty, reason: 'they land on one spot');
      c.undo();
      expect(c.text, 'abcd');
    });

    test('Backspace across a line break next to a cursor before it', () {
      final c = editor('ab\ncd');
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 2);
      c.addCursor(const CodeLineSelection.collapsed(index: 1, offset: 0));
      c.deleteBackward();
      expect(c.text, 'acd');
    });

    test('overlapping selections act as one', () {
      final c = editor('abcdef');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 1, extentIndex: 0, extentOffset: 4);
      c.addCursor(const CodeLineSelection(baseIndex: 0, baseOffset: 2, extentIndex: 0, extentOffset: 5));
      c.insertTyped('Z');
      expect(c.text, 'aZf');
    });

    test('wrapping several selections keeps each one\'s own text', () {
      final c = editor('one two');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 3);
      c.addCursor(const CodeLineSelection(baseIndex: 0, baseOffset: 4, extentIndex: 0, extentOffset: 7));
      c.insertTyped('(');
      expect(c.text, '(one) (two)');
    });

    test('a block comment wraps each cursor\'s own text', () {
      final c = editor('one two');
      c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 3);
      c.addCursor(const CodeLineSelection(baseIndex: 0, baseOffset: 4, extentIndex: 0, extentOffset: 7));
      c.toggleBlockComment();
      expect(c.text, '/*one*/ /*two*/');
    });
  });
}
