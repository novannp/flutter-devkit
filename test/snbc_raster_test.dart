import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:devkit/extensions/printer/escpos.dart';

void main() {
  test('SNBC line raster (GS D 1, SYN n data, NAK n) becomes one image, 1 = white', () {
    final out = <ReceiptElement>[];
    final p = EscPosParser(onCut: out.addAll, respond: (_) {});
    p.add([
      0x1D, 0x44, 0x01, // raster on
      0x16, 0x02, 0xFF, 0x0F, 0x15, 0x01, // row 0: white, then 4 white + 4 black dots
      0x16, 0x02, 0x00, 0xFF, 0x15, 0x01, // row 1: 8 black + 8 white
      0x1D, 0x44, 0x00, // raster off
      ...'TOTAL'.codeUnits, 0x0A,
      0x1D, 0x56, 0x00, // cut
    ]);
    final img = out.whereType<RasterImage>().single;
    expect((img.width, img.height), (16, 2));
    expect(img.pixel(0, 0), isFalse);
    expect(img.pixel(8, 0), isTrue);
    expect(img.pixel(12, 0), isFalse);
    expect(img.pixel(0, 1), isTrue);
    expect(img.pixel(8, 1), isFalse);
    expect(out.whereType<TextLine>().map((l) => l.plain), contains('TOTAL'));
    expect(img.bits, isA<Uint8List>());
  });
}
