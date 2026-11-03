import 'package:hotrestart/core/qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Checked module by module against the qr package, for all levels, masks and versions.
  const hello = [
    '#######..#.##.#######',
    '#.....#..###..#.....#',
    '#.###.#.##.##.#.###.#',
    '#.###.#..#.#..#.###.#',
    '#.###.#...#.#.#.###.#',
    '#.....#.....#.#.....#',
    '#######.#.#.#.#######',
    '........##.##........',
    '###.########.##...#..',
    '...#....#.....#....#.',
    '#.#...#...#.#...#####',
    '##..#...#.#...#....#.',
    '#.#..##..##.#.#.#.#..',
    '........##.#.#.#..##.',
    '#######.#..#.###..###',
    '#.....#.######.##....',
    '#.###.#.#..#.###..###',
    '#.###.#...#...##..##.',
    '#.###.#.###.#...#.#.#',
    '#.....#.##....#.#..#.',
    '#######.##..#.##..###',
  ];

  test('encodes known text to the known symbol', () {
    final q = QrMatrix.encode('HELLO');
    expect([for (var y = 0; y < q.size; y++) [for (var x = 0; x < q.size; x++) q.isDark(y, x) ? '#' : '.'].join()], hello);
  });

  test('picks the smallest version that fits, up to the limit', () {
    expect(QrMatrix.encode('a' * 17).version, 1);
    expect(QrMatrix.encode('a' * 18).version, 2);
    expect(QrMatrix.encode('a' * 2953).version, 40);
    expect(() => QrMatrix.encode('a' * 2954), throwsFormatException);
  });

  testWidgets('too much data leaves a blank instead of failing the page', (tester) async {
    await tester.pumpWidget(Center(child: QrView(data: 'a' * 3000, size: 100)));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(QrView)), const Size.square(100));
  });
}
