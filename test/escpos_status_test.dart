import 'package:flutter_test/flutter_test.dart';
import 'package:hotrestart/extensions/printer/escpos.dart';

void main() {
  List<int> replies(List<int> input) {
    final out = <int>[];
    EscPosParser(onCut: (_) {}, respond: out.addAll).add(input);
    return out;
  }

  test('GS a enables automatic status → 4-byte OK status', () {
    expect(replies([0x1D, 0x61, 0xFF]), autoStatusOk);
    expect(replies([0x1D, 0x61, 0x00]), isEmpty);
  });

  test('DLE EOT → online', () => expect(replies([0x10, 0x04, 0x01]), [0x12]));

  test('ESC ACK SOH → long status OK', () => expect(replies([0x1B, 0x06, 0x01]), longStatusOk));

  test('status commands mixed with text still print', () {
    final elements = <Object>[];
    EscPosParser(
      onCut: elements.addAll,
      respond: (_) {},
    ).add([0x1B, 0x06, 0x01, ...'Hello'.codeUnits, 0x0A, 0x1D, 0x56, 0x00]);
    expect(elements, isNotEmpty);
  });
}
