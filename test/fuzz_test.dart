import 'dart:convert';
import 'dart:math';

import 'package:devkit/extensions/printer/escpos.dart';
import 'package:devkit/modules/editor/brackets.dart';
import 'package:devkit/modules/editor/editor_workspace.dart';
import 'package:devkit/modules/editor/engine/code_model.dart';
import 'package:devkit/modules/editor/engine/snippet.dart';
import 'package:devkit/modules/editor/engine/syntax.dart';
import 'package:devkit/modules/editor/fuzzy_files.dart';
import 'package:devkit/modules/editor/log_style.dart';
import 'package:devkit/modules/editor/lsp_client.dart';
import 'package:devkit/modules/editor/markdown_view.dart';
import 'package:devkit/modules/editor/source_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pieces = ['', ' ', '\n', '\t', '{', '}', '(', ')', '[', ']', '"', "'", '`', r'$', r'\', '/', '//', '/*', '*/', 'é', '日本', '😀', 'class ', 'void ', 'abc', 'x_1', '0', ';', ':', '\r\n', '<', '>', '=>', '#', '-', '+', '@@ -1,2 +3,4 @@', '---', '\u0000', '\u001b[31m', '\u001b[', r'${1:a}', r'${', '|'];

String _junk(Random r, [int max = 40]) => [for (var i = r.nextInt(max); i > 0; i--) _pieces[r.nextInt(_pieces.length)]].join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no run of edits breaks the editor, and undo and redo retrace them', () {
    for (var seed = 0; seed < 400; seed++) {
      final r = Random(seed);
      final original = List.generate(r.nextInt(12) + 1, (_) => _junk(r, 8).replaceAll('\r\n', '\n').replaceAll('\n', ' ')).join('\n');
      final c = CodeLineEditingController(codeLines: CodeLines.fromText(original));
      final start = c.text;
      var log = <String>[];

      int line() => r.nextInt(c.lineCount + 2) - 1;
      int col() => r.nextInt(30) - 2;
      CodeLineSelection anywhere() => CodeLineSelection(baseIndex: line(), baseOffset: col(), extentIndex: line(), extentOffset: col());

      final ops = <String, void Function()>{
        'select': () => c.selection = anywhere(),
        'cursor': () => c.addCursor(anywhere()),
        'type': () => c.insertTyped(_pieces[r.nextInt(_pieces.length)]),
        'typeNoClose': () => c.insertTyped('z', autoClose: false),
        'replace': () => c.replaceSelection(_junk(r, 6)),
        'newline': c.applyNewLine,
        'back': c.deleteBackward,
        'forward': c.deleteForward,
        'wordBack': c.deleteWordBackward,
        'wordForward': c.deleteWordForward,
        'deleteLines': c.deleteSelectionLines,
        'indent': c.applyIndent,
        'outdent': c.applyOutdent,
        'up': c.moveSelectionLinesUp,
        'down': c.moveSelectionLinesDown,
        'comment': () => c.toggleLineComment('//'),
        'block': c.toggleBlockComment,
        'all': c.selectAll,
        'selectLine': () => c.selectLine(r.nextInt(c.lineCount)),
        'cancel': c.cancelSelection,
        'clearCursors': c.clearExtraCursors,
        'next': c.selectNextOccurrence,
        'left': () => c.moveHorizontal(-1, extend: r.nextBool()),
        'right': () => c.moveHorizontal(1, extend: r.nextBool()),
        'vertical': () => c.moveVertical(r.nextBool() ? 1 : -1, extend: r.nextBool(), count: r.nextInt(4) + 1),
        'home': () => c.moveToLineStart(extend: r.nextBool()),
        'end': () => c.moveToLineEnd(extend: r.nextBool()),
        'edge': () => c.moveToDocumentEdge(start: r.nextBool(), extend: r.nextBool()),
        'wordLeft': c.moveCursorToWordBoundaryBackward,
        'wordRight': c.moveCursorToWordBoundaryForward,
        'extendLeft': c.extendSelectionToWordBoundaryBackward,
        'extendRight': c.extendSelectionToWordBoundaryForward,
        'fold': () {
          final a = r.nextInt(c.lineCount);
          c.collapseChunk(a, min(c.lineCount - 1, a + r.nextInt(4)));
        },
        'unfold': () {
          final i = r.nextInt(c.lineCount);
          if (c.codeLines[i].chunkParent) c.expandChunk(i);
        },
        'undo': c.undo,
        'redo': c.redo,
        'selected': () => c.selectedText,
        'setText': () => c.text = _junk(r, 10),
        'staleReplace': () => c.replaceSelection('q', anywhere()),
      };
      final names = ops.keys.toList();

      for (var i = 0; i < 300; i++) {
        final name = names[r.nextInt(names.length)];
        log.add(name);
        if (log.length > 12) log = log.sublist(log.length - 12);
        try {
          ops[name]!();
          final s = c.selection;
          expect(s.extentIndex, inInclusiveRange(0, c.lineCount - 1));
          expect(s.baseIndex, inInclusiveRange(0, c.lineCount - 1));
          expect(s.extentOffset, inInclusiveRange(0, c.codeLines[s.extentIndex].length));
          expect(s.baseOffset, inInclusiveRange(0, c.codeLines[s.baseIndex].length));
          for (final e in c.extraSelections) {
            expect(e.extentOffset, inInclusiveRange(0, c.codeLines[e.extentIndex].length));
          }
        } catch (e, stack) {
          fail('seed $seed, after ${log.join(' > ')}: $e\n${stack.toString().split('\n').take(6).join('\n')}');
        }
      }

      // A run can stop part way back through undo; redo first, so the end is the real end.
      while (c.canRedo) {
        c.redo();
      }
      final end = c.text;
      for (var i = 0; c.canUndo && i < 5000; i++) {
        try {
          c.undo();
        } catch (e) {
          fail('undo, seed $seed: $e');
        }
      }
      expect(c.text, start, reason: 'undo all, seed $seed');
      for (var i = 0; c.canRedo && i < 5000; i++) {
        try {
          c.redo();
        } catch (e) {
          fail('redo, seed $seed: $e');
        }
      }
      expect(c.text, end, reason: 'redo all, seed $seed');
    }
  });

  test('stray input never breaks a parser', () {
    final dart = languageForExtension('.dart')!;
    for (var seed = 0; seed < 4000; seed++) {
      final r = Random(seed);
      final text = _junk(r, 60);
      try {
        parseStatus(text);
        parseMarks(text);
        parseSideBySide(text);
        parseBlame(text);
        parseSnippet(text);
        parseMarkdown(text);
        ansiSpan(text, const TextStyle());
        levelOf(text);
        splitLineSuffix(text);
        matchFile(text, 'C:/repo/lib/$text.dart', 'C:/repo');
        bracketPairs(text.split('\n'));
        var state = const LexState.code();
        for (final line in text.split('\n')) {
          state = tokenizeLine(line, dart, state).$2;
        }
        applyTextEdits(text, [
          {
            'range': {
              'start': {'line': r.nextInt(5), 'character': r.nextInt(50)},
              'end': {'line': r.nextInt(5) + 5, 'character': r.nextInt(50)},
            },
            'newText': 'x',
          },
        ]);
      } catch (e, stack) {
        fail('seed $seed on ${jsonEncode(text)}: $e\n${stack.toString().split('\n').take(5).join('\n')}');
      }
    }
  });

  test('a printer can send anything', () {
    for (var seed = 0; seed < 200; seed++) {
      final r = Random(seed);
      final parser = EscPosParser(onCut: (_) {}, respond: (_) {});
      try {
        for (var chunk = 0; chunk < 6; chunk++) {
          // Mostly control bytes, so commands with lengths get exercised.
          parser.add([for (var i = r.nextInt(120); i > 0; i--) r.nextBool() ? [0x1B, 0x1D, 0x10, 0x28, 0x6B, 0x76, 0x2A, 0x16, 0x15, 49, 80, 81][r.nextInt(12)] : r.nextInt(256)]);
        }
      } catch (e, stack) {
        fail('seed $seed: $e\n${stack.toString().split('\n').take(5).join('\n')}');
      }
    }
  });

  group('what the analysis server sends', () {
    test('a framing parser skips what it can\'t read', () {
      final parser = LspFrameParser();
      List<int> frame(String body) => utf8.encode('Content-Length: ${utf8.encode(body).length}\r\n\r\n$body');
      expect(parser.add(utf8.encode('Some banner the SDK printed\r\n\r\n')), isEmpty, reason: 'no Content-Length');
      expect(parser.add(frame('{not json')), isEmpty);
      expect(parser.add(frame('[1, 2]')), isEmpty, reason: 'not a message');
      expect(parser.add(frame('{"id": 1}')).single['id'], 1);
    });

    test('random bytes don\'t stop it', () {
      for (var seed = 0; seed < 100; seed++) {
        final r = Random(seed);
        final parser = LspFrameParser();
        parser.add(utf8.encode(_junk(r)));
        parser.add(List.generate(r.nextInt(50), (_) => r.nextInt(256)));
        parser.add(utf8.encode('\r\n\r\n'));
      }
    });

    test('odd signature help is tolerated', () {
      expect(SignatureInfo.fromLsp(null), isNull);
      expect(SignatureInfo.fromLsp({'signatures': const []}), isNull);
      final answers = [
        {'label': 'f(int a)', 'parameters': [{'label': 'int a'}], 'activeParameter': -1},
        {'label': 'f(int a)', 'parameters': [{'label': [2, 7]}], 'activeParameter': 0},
        {'label': 'f()', 'parameters': [{'label': 'nowhere'}], 'activeParameter': 0},
        {'label': 'f()', 'activeParameter': 9},
      ];
      for (final sig in answers) {
        final info = SignatureInfo.fromLsp({'signatures': [sig], 'activeSignature': 4})!;
        expect(info.activeStart, inInclusiveRange(0, info.label.length));
        expect(info.activeEnd, inInclusiveRange(info.activeStart, info.label.length));
      }
    });
  });

  test('a text edit past its line stops at the line end', () {
    Map<String, dynamic> edit(int line, int from, int to) => {
      'range': {
        'start': {'line': line, 'character': from},
        'end': {'line': line, 'character': to},
      },
      'newText': 'X',
    };
    expect(applyTextEdits('ab\ncd', [edit(0, 1, 99)]), 'aX\ncd');
    expect(applyTextEdits('ab\ncd', [edit(0, 99, 99)]), 'abX\ncd');
    expect(applyTextEdits('ab\ncd', [edit(1, 99, 1)]), 'abcdX'.replaceFirst('ab', 'ab\n'));
    expect(applyTextEdits('ab\ncd', [edit(9, 0, 0)]), 'ab\ncdX');
  });

  test('an answer arriving after the document closed is ignored', () {
    final c = CodeLineEditingController(codeLines: CodeLines.fromText('a'));
    c.dispose();
    c.forceRepaint();
    c.selection = const CodeLineSelection.collapsed(index: 0, offset: 1);
  });

  test('a bad snippet session stays quiet when its text goes away', () {
    final c = CodeLineEditingController(codeLines: CodeLines.fromText(r'a b'));
    final s = SnippetSession(c, 0, parseSnippet(r'${1:a} ${2:b}'));
    c.text = '';
    expect(s.move(1), isFalse);
  });
}
