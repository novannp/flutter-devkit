import 'dart:io';
import 'dart:typed_data';

import 'package:slipway/modules/editor/editor_workspace.dart';
import 'package:slipway/modules/editor/file_preview.dart';
import 'package:slipway/modules/editor/markdown_view.dart';
import 'package:slipway/modules/editor/preview_kind.dart';
import 'package:slipway/modules/editor/svg_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _zipOf(String name, int size) {
  final nameBytes = name.codeUnits;
  final entry = ByteData(46);
  entry.setUint32(0, 0x02014b50, Endian.little);
  entry.setUint32(24, size, Endian.little);
  entry.setUint16(28, nameBytes.length, Endian.little);
  final end = ByteData(22);
  end.setUint32(0, 0x06054b50, Endian.little);
  end.setUint16(10, 1, Endian.little);
  end.setUint32(12, 46 + nameBytes.length, Endian.little);
  return Uint8List.fromList([...entry.buffer.asUint8List(), ...nameBytes, ...end.buffer.asUint8List()]);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('preview'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('documents', () {
    test('a binary file opens as a preview instead of failing', () async {
      final file = File(p.join(dir.path, 'data.bin'))..writeAsBytesSync([0, 1, 2, 3]);
      final doc = await EditorDocument.open(file.path);
      addTearDown(doc.dispose);
      expect(doc.binary, isTrue);
      expect(doc.canPreview, isFalse);
      await doc.save();
      expect(file.readAsBytesSync(), [0, 1, 2, 3], reason: 'saving never writes over it');
    });

    test('text with a preview starts as code, except SVG', () async {
      final md = File(p.join(dir.path, 'a.md'))..writeAsStringSync('# Hi');
      final svg = File(p.join(dir.path, 'a.svg'))..writeAsStringSync('<svg/>');
      final mdDoc = await EditorDocument.open(md.path), svgDoc = await EditorDocument.open(svg.path);
      addTearDown(mdDoc.dispose);
      addTearDown(svgDoc.dispose);
      expect((mdDoc.canPreview, mdDoc.previewing), (true, false));
      expect((svgDoc.canPreview, svgDoc.previewing), (true, true));
      mdDoc.togglePreview();
      expect(mdDoc.previewing, isTrue);
    });
  });

  test('kinds go by extension, in any case', () {
    expect(previewKindOf('a/B.PNG'), PreviewKind.image);
    expect(previewKindOf('app-release.apk'), PreviewKind.archive);
    expect(previewKindOf('main.dart'), PreviewKind.none);
    expect(PreviewKind.pdf.onlyPreview, isTrue);
    expect(PreviewKind.markdown.onlyPreview, isFalse);
  });

  group('CSV', () {
    test('quotes hold separators, line breaks and doubled quotes', () {
      expect(parseDelimited('a,"b,c"\r\n"d\ne","f""g"\n', ','), [
        ['a', 'b,c'],
        ['d\ne', 'f"g'],
      ]);
    });

    test('a last line without a break still counts, and rows stop at the limit', () {
      expect(parseDelimited('a\tb', '\t'), [
        ['a', 'b'],
      ]);
      expect(parseDelimited('1\n2\n3\n', ',', maxRows: 2).length, 2);
    });
  });

  group('archives', () {
    test('lists what is inside from the table of contents', () async {
      final file = File(p.join(dir.path, 'a.zip'))..writeAsBytesSync(_zipOf('lib/x.so', 1234));
      final entries = (await readZipEntries(file.path))!;
      expect(entries.single.name, 'lib/x.so');
      expect(entries.single.size, 1234);
    });

    test('anything else with the extension is reported, not thrown', () async {
      final file = File(p.join(dir.path, 'a.zip'))..writeAsBytesSync(List.filled(40, 7));
      expect(await readZipEntries(file.path), isNull);
      final tiny = File(p.join(dir.path, 'b.zip'))..writeAsBytesSync([1]);
      expect(await readZipEntries(tiny.path), isNull);
    });
  });

  test('hex shows offsets, bytes and printable text', () {
    expect(hexDump([0x41, 0x00]).trimRight(), '${'00000000'}  41 00${' ' * 42}  A.');
  });

  group('SVG', () {
    test('path data can run its numbers together', () {
      final bounds = parseSvgPath('M1 1L5-1h2.5.5v3zM10,10a2 2 0 012 2').getBounds();
      expect(bounds.left, 1);
      expect(bounds.right, moreOrLessEquals(12));
      expect(bounds.top, -1);
    });

    test('broken path data keeps what came before it', () {
      expect(parseSvgPath('M1 1 L5 5 L').getBounds().right, 5);
      expect(parseSvgPath('nonsense').getBounds().isEmpty, isTrue);
    });

    test('groups pass down paint, and hidden parts stay hidden', () {
      final image = parseSvg('''
<!-- <circle r="9"/> -->
<svg viewBox="0 0 24 24"><defs><linearGradient id="g"><stop stop-color="#112233"/></linearGradient><rect width="9" height="9"/></defs>
<g fill="#f00" opacity=".5" transform="translate(2 3)"><rect width="4" height="4" style="stroke:blue;stroke-width:2"/><circle r="1" fill="none"/></g>
<path d="M0 0h1" fill="url(#g)"/></svg>''')!;
      expect(image.viewBox, const Rect.fromLTWH(0, 0, 24, 24));
      expect(image.shapes.length, 3);
      final rect = image.shapes.first;
      expect(rect.fill!.a, moreOrLessEquals(.5, epsilon: .01));
      expect(rect.strokeWidth, 2);
      expect(rect.matrix[12], 2);
      expect(image.shapes[1].fill, isNull);
      expect(image.shapes[2].fill, const Color(0xFF112233));
    });

    test('not SVG at all', () => expect(parseSvg('hello'), isNull));
  });

  group('Markdown', () {
    test('reads what a README uses', () {
      final blocks = parseMarkdown('''
## Title
> a quote
> goes on

- [x] done
  1. nested

| A | B |
|---|---|
| 1 | x\\|y |

[![badge](https://x/y.png)](https://x)
<div align="center">
<img src="a.png" width="9">
```yaml
a: 1
```''');
      expect(blocks.map((b) => b.kind), [MdKind.heading, MdKind.quote, MdKind.bullet, MdKind.bullet, MdKind.table, MdKind.images, MdKind.images, MdKind.code]);
      expect(blocks[0].level, 2);
      expect(blocks[1].text, 'a quote goes on');
      expect((blocks[2].marker, blocks[2].text), ('☑', 'done'));
      expect((blocks[3].marker, blocks[3].level), ('1.', 1));
      expect(blocks[4].rows.last, ['1', 'x|y']);
      expect(blocks[5].images.single.url, 'https://x/y.png');
      expect(blocks[6].images.single.url, 'a.png');
      expect(blocks[7].marker, 'yaml');
    });

    test('a generic type in a sentence stays text', () {
      expect(parseMarkdown('Returns a List<int> here').single.text, 'Returns a List<int> here');
    });
  });

  group('renders', () {
    // File reads and image decoding finish on the real clock, one step per pump.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
    }

    Future<void> show(WidgetTester tester, String name, Object content) async {
      final file = File(p.join(dir.path, name));
      content is String ? file.writeAsStringSync(content) : file.writeAsBytesSync(content as List<int>);
      final doc = await tester.runAsync(() => EditorDocument.open(file.path));
      addTearDown(doc!.dispose);
      if (!doc.binary && !doc.previewing) doc.togglePreview();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: FilePreview(doc: doc))));
      await settle(tester);
      expect(tester.takeException(), isNull);
    }

    testWidgets('Markdown, with a table and a missing image', (tester) async {
      await show(tester, 'a.md', '# Top\n\n| A |\n|---|\n| **b** |\n\n![gone](nope.png)\n');
      expect(find.text('Top'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('CSV, with short rows', (tester) async {
      await show(tester, 'a.csv', 'one,two\n1\n');
      expect(find.text('one'), findsOneWidget);
      expect(find.textContaining('1 rows'), findsOneWidget);
    });

    testWidgets('JSON folds, and bad JSON says so', (tester) async {
      await show(tester, 'a.json', '{"a":{"b":1}}');
      expect(find.text('b: '), findsOneWidget);
      await tester.tap(find.text('a: '));
      await tester.pump();
      expect(find.text('b: '), findsNothing);
      await show(tester, 'b.json', '{nope');
      expect(find.textContaining('Not valid JSON'), findsOneWidget);
    });

    testWidgets('SVG', (tester) async {
      await show(tester, 'a.svg', '<svg viewBox="0 0 10 10"><rect width="9" height="9"/></svg>');
      expect(find.byType(SvgView), findsOneWidget);
      await show(tester, 'b.svg', 'not svg');
      expect(find.textContaining('no <svg>'), findsOneWidget);
    });

    testWidgets('a broken image says so', (tester) async {
      await show(tester, 'a.png', [1, 2, 3]);
      expect(find.textContaining("couldn't be read"), findsOneWidget);
    });

    testWidgets('an archive and a binary file', (tester) async {
      await show(tester, 'a.apk', _zipOf('classes.dex', 2048));
      expect(find.text('classes.dex'), findsOneWidget);
      await show(tester, 'a.bin', [0, 65]);
      expect(find.textContaining('Binary file'), findsOneWidget);
    });
  });
}
