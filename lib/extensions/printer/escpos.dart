import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

enum ReceiptAlign { left, center, right }

class TextStyleState {
  const TextStyleState({
    this.bold = false,
    this.underline = false,
    this.width = 1,
    this.height = 1,
    this.invert = false,
  });

  final bool bold;
  final bool underline;
  final int width;
  final int height;
  final bool invert;

  TextStyleState copyWith({bool? bold, bool? underline, int? width, int? height, bool? invert}) => TextStyleState(
    bold: bold ?? this.bold,
    underline: underline ?? this.underline,
    width: width ?? this.width,
    height: height ?? this.height,
    invert: invert ?? this.invert,
  );
}

class TextRun {
  TextRun(this.text, this.style);

  String text;
  final TextStyleState style;
}

sealed class ReceiptElement {}

class TextLine extends ReceiptElement {
  TextLine(this.runs, this.align);

  final List<TextRun> runs;
  final ReceiptAlign align;

  String get plain => runs.map((r) => r.text).join();
}

class RasterImage extends ReceiptElement {
  RasterImage(this.width, this.height, this.bits, this.align);

  /// Width in dots; [bits] 1 = black, row by row, packed per byte (MSB first).
  final int width;
  final int height;
  final Uint8List bits;
  final ReceiptAlign align;

  bool pixel(int x, int y) {
    final bytesPerRow = (width + 7) >> 3;
    return bits[y * bytesPerRow + (x >> 3)] & (0x80 >> (x & 7)) != 0;
  }
}

class QrElement extends ReceiptElement {
  QrElement(this.data, this.moduleSize, this.align);

  final String data;
  final int moduleSize;
  final ReceiptAlign align;
}

class BarcodeElement extends ReceiptElement {
  BarcodeElement(this.data, this.align);

  final String data;
  final ReceiptAlign align;
}

class FeedElement extends ReceiptElement {
  FeedElement(this.lines);

  final int lines;
}

class EventElement extends ReceiptElement {
  EventElement(this.label);

  final String label;
}

/// Streaming ESC/POS parser. Bytes may arrive in chunks; incomplete trailing commands are buffered.
/// 4-byte automatic status: online, cover closed, paper OK, no errors.
const autoStatusOk = [0x14, 0x00, 0x00, 0x0F];

/// 9-byte automatic status: online, no errors, paper OK.
const longStatusOk = [0x23, 0x86, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

class EscPosParser {
  EscPosParser({required this.onCut, required this.respond});

  /// Called on a paper cut command, with the receipt elements up to that point.
  final void Function(List<ReceiptElement> elements) onCut;

  /// Replies to the printer client (DLE EOT status requests etc.) so the driver doesn't hang.
  final void Function(List<int> bytes) respond;

  final _buf = <int>[];
  final elements = <ReceiptElement>[];
  final _runs = <TextRun>[];
  var _style = const TextStyleState();
  var _align = ReceiptAlign.left;
  var _lineAlign = ReceiptAlign.left;
  String _qrData = '';
  var _qrSize = 4;
  final raw = BytesBuilder(copy: false);

  void add(List<int> data) {
    raw.add(data);
    _buf.addAll(data);
    var i = 0;
    while (i < _buf.length) {
      final used = _step(i);
      if (used == 0) break; // need more bytes
      i += used;
    }
    _buf.removeRange(0, i);
  }

  /// Call when the connection closes: leftover text becomes one receipt.
  void flush() {
    _endLine(force: false);
    if (elements.isNotEmpty) _cut();
  }

  int? _at(int i) => i < _buf.length ? _buf[i] : null;

  void _write(String s) {
    if (_runs.isEmpty) _lineAlign = _align;
    if (_runs.isNotEmpty && identical(_runs.last.style, _style)) {
      _runs.last.text += s;
    } else {
      _runs.add(TextRun(s, _style));
    }
  }

  void _endLine({bool force = true}) {
    if (_runs.isEmpty) {
      if (force) elements.add(TextLine([], _align));
      return;
    }
    elements.add(TextLine(List.of(_runs), _lineAlign));
    _runs.clear();
  }

  void _cut() {
    _flushSnbcRaster();
    _endLine(force: false);
    onCut(List.of(elements));
    elements.clear();
  }

  ReceiptAlign _alignOf(int n) => switch (n) {
    1 || 49 => ReceiptAlign.center,
    2 || 50 => ReceiptAlign.right,
    _ => ReceiptAlign.left,
  };

  // Line raster (GS D 1 … GS D 0): SYN n <n bytes> prints a dot line, NAK n advances n lines.
  var _lineRaster = false;
  final _rasterRows = <Uint8List>[];

  void _flushSnbcRaster() {
    if (_rasterRows.isEmpty) return;
    final bytesPerRow = _rasterRows.map((r) => r.length).fold(0, max);
    final bits = Uint8List(bytesPerRow * _rasterRows.length);
    for (var y = 0; y < _rasterRows.length; y++) {
      final row = _rasterRows[y];
      for (var x = 0; x < bytesPerRow; x++) {
        // This mode sends 1 = paper (white); blank lines/padding stay white.
        bits[y * bytesPerRow + x] = x < row.length ? (~row[x] & 0xFF) : 0;
      }
    }
    // Row padding (width rounded up to whole bytes) comes out black after inverting; drop columns of the
    // last byte that are black on every non-empty row.
    final rows = [
      for (var y = 0; y < _rasterRows.length; y++)
        if (_rasterRows[y].length == bytesPerRow) y,
    ];
    for (var bit = 0; bit < 8 && rows.isNotEmpty; bit++) {
      final mask = 0x80 >> bit;
      if (rows.every((y) => bits[y * bytesPerRow + bytesPerRow - 1] & mask != 0)) {
        for (final y in rows) {
          bits[y * bytesPerRow + bytesPerRow - 1] &= ~mask;
        }
      }
    }
    _endLine(force: false);
    elements.add(RasterImage(bytesPerRow * 8, _rasterRows.length, bits, _align));
    _rasterRows.clear();
  }

  int _lineRasterStep(int i) {
    final b = _buf[i];
    final n = _at(i + 1);
    if (b == 0x16) {
      if (n == null || _buf.length < i + 2 + n) return 0;
      _rasterRows.add(Uint8List.fromList(_buf.sublist(i + 2, i + 2 + n)));
      return 2 + n;
    }
    if (b == 0x15) {
      if (n == null) return 0;
      for (var k = 1; k < n; k++) {
        _rasterRows.add(Uint8List(0));
      }
      return 2;
    }
    return -1;
  }

  /// Processes one command/char at [i]; returns bytes consumed, or 0 if incomplete.
  int _step(int i) {
    final b = _buf[i];
    if (_lineRaster) {
      final used = _lineRasterStep(i);
      if (used >= 0) return used;
    }
    switch (b) {
      case 0x0A:
        _endLine();
        return 1;
      case 0x0D || 0x00:
        return 1;
      case 0x09:
        _write('    ');
        return 1;
      case 0x0C:
        _cut();
        return 1;
      case 0x10: // DLE
        final c = _at(i + 1);
        final n = _at(i + 2);
        if (c == null || n == null) return 0;
        if (c == 0x04) respond([0x12]); // status: online, no errors
        if (c == 0x14) return _at(i + 4) == null ? 0 : 5;
        return 3;
      case 0x1B:
        return _esc(i);
      case 0x1D:
        return _gs(i);
      case 0x1C: // FS
        final c = _at(i + 1);
        if (c == null) return 0;
        if (c == 0x70) return _at(i + 3) == null ? 0 : 4; // FS p n m: NV logo
        if (c == 0x21 || c == 0x43 || c == 0x2D || c == 0x57) return _at(i + 2) == null ? 0 : 3;
        return 2;
      default:
        if (b < 0x20) return 1;
        // Text: read up to the next control byte.
        var j = i;
        while (j < _buf.length && _buf[j] >= 0x20) {
          j++;
        }
        _write(latin1.decode(_buf.sublist(i, j)));
        return j - i;
    }
  }

  int _esc(int i) {
    final c = _at(i + 1);
    if (c == null) return 0;
    final n = _at(i + 2);
    switch (c) {
      case 0x06: // ESC ACK SOH: status request
        if (n == null) return 0;
        if (n == 0x01) respond(longStatusOk);
        return 3;
      case 0x1D when n == 0x03: // ESC GS ETX: checked-block and status commands
        return _at(i + 4) == null ? 0 : 5;
      case 0x40: // ESC @
        _style = const TextStyleState();
        _align = ReceiptAlign.left;
        return 2;
      case 0x21: // ESC ! mode
        if (n == null) return 0;
        _style = _style.copyWith(
          bold: n & 0x08 != 0,
          height: n & 0x10 != 0 ? 2 : 1,
          width: n & 0x20 != 0 ? 2 : 1,
          underline: n & 0x80 != 0,
        );
        return 3;
      case 0x45 || 0x47: // ESC E / ESC G bold
        if (n == null) return 0;
        _style = _style.copyWith(bold: n & 1 == 1);
        return 3;
      case 0x2D: // ESC - underline
        if (n == null) return 0;
        _style = _style.copyWith(underline: n != 0 && n != 48);
        return 3;
      case 0x61: // ESC a align
        if (n == null) return 0;
        _align = _alignOf(n);
        if (_runs.isEmpty) _lineAlign = _align;
        return 3;
      case 0x64: // ESC d n: feed lines
        if (n == null) return 0;
        _endLine(force: false);
        if (n > 0) elements.add(FeedElement(n));
        return 3;
      case 0x4A: // ESC J n: feed dots
        if (n == null) return 0;
        _endLine(force: false);
        return 3;
      case 0x70: // ESC p: open drawer
        if (_at(i + 4) == null) return 0;
        _endLine(force: false);
        elements.add(EventElement('Cash drawer opened'));
        return 5;
      case 0x2A: // ESC * m nL nH: column bit image
        final m = n, nl = _at(i + 3), nh = _at(i + 4);
        if (m == null || nl == null || nh == null) return 0;
        final cols = nl + nh * 256;
        final bytesPerCol = (m == 32 || m == 33) ? 3 : 1;
        final total = 5 + cols * bytesPerCol;
        if (_buf.length < i + total) return 0;
        _endLine(force: false);
        elements.add(_columnImage(_buf.sublist(i + 5, i + total), cols, bytesPerCol));
        return total;
      case 0x32 || 0x3C:
        return 2;
      case 0x33 || 0x4D || 0x74 || 0x52 || 0x20 || 0x55 || 0x56 || 0x7B || 0x63 || 0x72:
        return n == null ? 0 : 3;
      case 0x24 || 0x5C: // absolute/relative position
        return _at(i + 3) == null ? 0 : 4;
      case 0x44: // ESC D: tab stops, NUL-terminated
        final end = _buf.indexOf(0, i + 2);
        return end < 0 ? 0 : end - i + 1;
      case 0x69 || 0x6D: // ESC i / ESC m: cut
        _cut();
        return 2;
      default:
        return 2;
    }
  }

  int _gs(int i) {
    final c = _at(i + 1);
    if (c == null) return 0;
    final n = _at(i + 2);
    switch (c) {
      case 0x44: // GS D n: line raster mode on/off
        if (n == null) return 0;
        if (n == 0) _flushSnbcRaster();
        _lineRaster = n == 1;
        return 3;
      case 0x21: // GS ! character size
        if (n == null) return 0;
        _style = _style.copyWith(width: (n >> 4) + 1, height: (n & 0x0F) + 1);
        return 3;
      case 0x42: // GS B reverse
        if (n == null) return 0;
        _style = _style.copyWith(invert: n & 1 == 1);
        return 3;
      case 0x56: // GS V cut
        if (n == null) return 0;
        _cut();
        return (n == 65 || n == 66) ? (_at(i + 3) == null ? 0 : 4) : 3;
      case 0x76: // GS v 0 m xL xH yL yH: raster
        final xl = _at(i + 4), xh = _at(i + 5), yl = _at(i + 6), yh = _at(i + 7);
        if (yh == null) return 0;
        final wBytes = xl! + xh! * 256;
        final h = yl! + yh * 256;
        final total = 8 + wBytes * h;
        if (_buf.length < i + total) return 0;
        _endLine(force: false);
        elements.add(RasterImage(wBytes * 8, h, Uint8List.fromList(_buf.sublist(i + 8, i + total)), _align));
        return total;
      case 0x28: // GS ( fn pL pH ...
        final fn = n, pl = _at(i + 3), ph = _at(i + 4);
        if (fn == null || pl == null || ph == null) return 0;
        final len = pl + ph * 256;
        final total = 5 + len;
        if (_buf.length < i + total) return 0;
        if (fn == 0x6B) _qr(_buf.sublist(i + 5, i + total));
        return total;
      case 0x6B: // GS k barcode
        final m = n;
        if (m == null) return 0;
        if (m <= 6) {
          final end = _buf.indexOf(0, i + 3);
          if (end < 0) return 0;
          _barcode(_buf.sublist(i + 3, end));
          return end - i + 1;
        }
        final len = _at(i + 3);
        if (len == null || _buf.length < i + 4 + len) return 0;
        _barcode(_buf.sublist(i + 4, i + 4 + len));
        return 4 + len;
      case 0x72 || 0x49: // GS r / GS I: status & info
        if (n == null) return 0;
        respond([0x00]);
        return 3;
      case 0x61: // GS a: auto status back; some drivers wait for this 4-byte "all OK" status
        if (n == null) return 0;
        if (n != 0) respond(autoStatusOk);
        return 3;
      case 0x48 || 0x68 || 0x77 || 0x66 || 0x62 || 0x2F:
        return n == null ? 0 : 3;
      case 0x4C || 0x57 || 0x50:
        return _at(i + 3) == null ? 0 : 4;
      default:
        return 2;
    }
  }

  void _qr(List<int> p) {
    if (p.length < 2 || p[0] != 49) return; // cn 49 = QR
    final fn = p[1];
    if (fn == 67 && p.length >= 3) _qrSize = p[2];
    if (fn == 80 && p.length >= 3) _qrData = utf8.decode(p.sublist(3), allowMalformed: true);
    if (fn == 81) {
      _endLine(force: false);
      elements.add(QrElement(_qrData, _qrSize, _align));
    }
  }

  void _barcode(List<int> data) {
    _endLine(force: false);
    var text = latin1.decode(data);
    // CODE128 starts with a {A/{B/{C set selector.
    if (text.startsWith('{') && text.length > 2) text = text.substring(2);
    elements.add(BarcodeElement(text, _align));
  }

  RasterImage _columnImage(List<int> data, int cols, int bytesPerCol) {
    final h = bytesPerCol * 8;
    final bytesPerRow = (cols + 7) >> 3;
    final bits = Uint8List(bytesPerRow * h);
    for (var x = 0; x < cols; x++) {
      for (var b = 0; b < bytesPerCol; b++) {
        final v = data[x * bytesPerCol + b];
        for (var bit = 0; bit < 8; bit++) {
          if (v & (0x80 >> bit) == 0) continue;
          final y = b * 8 + bit;
          bits[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }
    return RasterImage(cols, h, bits, _align);
  }
}
