import 'package:devkit/modules/editor/editor_workspace.dart';
import 'package:devkit/modules/editor/engine/code_model.dart';
import 'package:devkit/modules/editor/engine/snippet.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSnippet', () {
    test('placeholders, order and the final stop', () {
      final s = parseSnippet(r'for (var ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {' '\n  \$0\n}');
      expect(s.text, 'for (var i = 0; i < n; i++) {\n  \n}');
      expect(s.stops.map((g) => g.length), [3, 1, 1]);
      expect(s.text.substring(s.stops[1].first.start, s.stops[1].first.end), 'n');
      expect(s.stops.last.first.isCollapsed, isTrue);
    });

    test('no final stop means the end of the text', () {
      final s = parseSnippet(r'a$1b');
      expect(s.text, 'ab');
      expect(s.stops.last, [const TextRange.collapsed(2)]);
    });

    test('escapes, choices, nesting and bare mirrors', () {
      expect(parseSnippet(r'\$a \} \\').text, r'$a } \');
      expect(parseSnippet(r'${1|one,two|}').text, 'one');
      expect(parseSnippet(r'${1:a${2:b}c}').text, 'abc');
      expect(parseSnippet(r'${1:x} $1').text, 'x x');
      expect(parseSnippet(r'$HOME').text, r'$HOME');
    });
  });

  test('a snippet stays in view even when the server sorts it last', () {
    CompletionEntry entry(String name, int kind, String sort) => CompletionEntry({'label': name, 'filterText': name, 'kind': kind, 'sortText': sort});
    final items = [for (var i = 0; i < 100; i++) entry('stuff$i', 6, 'a${i + 100}'), entry('stless', 15, 'zzz')];
    final shown = filterCompletions(items, 'st').map((c) => c.label).toList();
    expect(shown.indexOf('stless'), 3);
    expect(filterCompletions([entry('stless', 15, 'zzz')], 'st').single.label, 'stless');
  });

  group('SnippetSession', () {
    late CodeLineEditingController c;

    SnippetSession insert(String source, {String before = ''}) {
      final snippet = parseSnippet(source);
      c = CodeLineEditingController(codeLines: CodeLines.fromText(before + snippet.text));
      return SnippetSession(c, before.length, snippet);
    }

    test('typing in mirrored stops changes them all, and later stops follow', () {
      final s = insert(r'class ${1:Name} { ${1:Name}(${2:a}); $0}', before: '\n');
      expect(c.selectedText, 'Name');
      expect(c.extraSelections, hasLength(1));
      c.insertTyped('Foo');
      expect(c.text, '\nclass Foo { Foo(a); }');

      expect(s.move(1), isTrue);
      expect(c.selectedText, 'a');
      expect(c.hasExtraCursors, isFalse);
      c.insertTyped('longer');
      expect(c.text, '\nclass Foo { Foo(longer); }');

      expect(s.move(1), isTrue);
      expect(s.active, isFalse);
      expect(c.selection.isCollapsed, isTrue);
      expect(c.selection.extentOffset, c.text.split('\n').last.length - 1);
    });

    test('Shift+Tab goes back to a stop as it now reads', () {
      final s = insert(r'${1:a} ${2:b}');
      c.insertTyped('xyz');
      s.move(1);
      expect(c.selectedText, 'b');
      s.move(-1);
      expect(c.selectedText, 'xyz');
    });

    test('a caret that left the stop ends it', () {
      final s = insert(r'${1:a} ${2:b}', before: 'text\n');
      c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
      expect(s.move(1), isFalse);
    });
  });
}
