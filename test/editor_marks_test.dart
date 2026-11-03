import 'package:flutter_test/flutter_test.dart';
import 'package:hotrestart/modules/editor/code_pane.dart';
import 'package:hotrestart/modules/editor/editor_workspace.dart';
import 'package:hotrestart/modules/editor/engine/code_editor.dart';

void main() {
  group('occurrencesOf', () {
    test('a word only matches whole words', () {
      expect(occurrencesOf('connType = PrinterConn.connType(conn);', 'connType'), [0, 23]);
      expect(occurrencesOf('connType conn', 'conn'), [9]);
    });

    test('other text matches anywhere, and nothing overlaps', () {
      expect(occurrencesOf('a.b a.bc', 'a.b'), [0, 4]);
      expect(occurrencesOf('--- ', '--'), [0]);
      expect(occurrencesOf('abc', ''), isEmpty);
    });
  });

  group('colors in text', () {
    int argb(String line, HexColors style) => hexColorMarks(line, style).single.argb;

    test('reads each form', () {
      expect(argb('color: #10B981;', HexColors.web), 0xFF10B981);
      expect(argb('color: #abc;', HexColors.web), 0xFFAABBCC);
      expect(argb('color: #10B98180;', HexColors.web), 0x8010B981, reason: 'the web puts alpha last');
      expect(argb('<color>#8010B981</color>', HexColors.android), 0x8010B981, reason: 'Android puts it first');
    });

    test('marks where it is', () {
      final m = hexColorMarks('a: "#10B981"', HexColors.data).single;
      expect((m.start, m.end), (4, 11));
    });

    test('leaves out what only looks like a color', () {
      expect(hexColorMarks('#add a comment', HexColors.data), isEmpty);
      expect(hexColorMarks('&#123; x#abc #12345 #xyz', HexColors.web), isEmpty);
    });

    test('only in files that write colors this way', () {
      expect(hexColorsOf('a/b.CSS'), HexColors.web);
      expect(hexColorsOf('res/values/colors.xml'), HexColors.android);
      expect(hexColorsOf('pubspec.yaml'), HexColors.data);
      expect(hexColorsOf('lib/main.dart'), isNull, reason: 'the analyzer knows better');
      expect(hexColorsOf('README.md'), isNull);
    });

    test('the analyzer answer goes by line', () {
      final marks = colorMarksFromLsp([
        {
          'range': {
            'start': {'line': 3, 'character': 8},
            'end': {'line': 3, 'character': 25},
          },
          'color': {'red': 1.0, 'green': 0.0, 'blue': 0.5, 'alpha': 1.0},
        },
      ]);
      final m = marks[3]!.single;
      expect((m.start, m.end, m.argb), (8, 25, 0xFFFF0080));
    });
  });

  test('text usages leave out other file types, other words and the place asked about', () {
    final hits = [
      const SearchHit('a.dart', 1, 0, 'conn connType conn'),
      const SearchHit('a.dart', 2, 0, 'conn'),
      const SearchHit('b.yaml', 1, 0, 'conn'),
    ];
    expect(textUsages(hits, 'conn', '.dart', 'a.dart', 2).map((h) => (h.line, h.column)), [(1, 0), (1, 14)]);
  });
}
