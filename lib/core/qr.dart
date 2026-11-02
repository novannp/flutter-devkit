import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

enum QrLevel { low, medium, quartile, high }

const _eccPerBlock = [
  [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];

const _blockCount = [
  [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];

/// The bits in a format field, by level, as the standard numbers them.
const _levelBits = [1, 0, 3, 2];

int _rawModules(int version) {
  var result = (16 * version + 128) * version + 64;
  if (version >= 2) {
    final align = version ~/ 7 + 2;
    result -= (25 * align - 10) * align - 55;
    if (version >= 7) result -= 36;
  }
  return result;
}

int _dataCodewords(int version, int level) =>
    (_rawModules(version) ~/ 8) - _eccPerBlock[level][version - 1] * _blockCount[level][version - 1];

int _gfMultiply(int x, int y) {
  var z = 0;
  for (var i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >> 7) * 0x11D);
    z ^= ((y >> i) & 1) * x;
  }
  return z;
}

List<int> _reedSolomonDivisor(int degree) {
  final result = List<int>.filled(degree, 0);
  result[degree - 1] = 1;
  var root = 1;
  for (var i = 0; i < degree; i++) {
    for (var j = 0; j < degree; j++) {
      result[j] = _gfMultiply(result[j], root);
      if (j + 1 < degree) result[j] ^= result[j + 1];
    }
    root = _gfMultiply(root, 2);
  }
  return result;
}

List<int> _reedSolomonRemainder(List<int> data, List<int> divisor) {
  final result = List<int>.filled(divisor.length, 0, growable: true);
  for (final b in data) {
    final factor = b ^ result.first;
    result.removeAt(0);
    result.add(0);
    for (var i = 0; i < result.length; i++) {
      result[i] ^= _gfMultiply(divisor[i], factor);
    }
  }
  return result;
}

/// A finished QR symbol: [isDark] is indexed by row, then column.
class QrMatrix {
  QrMatrix._(this.size, this.version, this.mask, this._modules);

  final int size, version, mask;
  final List<bool> _modules;

  bool isDark(int row, int column) => _modules[row * size + column];

  /// Encodes [text] as bytes in the smallest version that holds it. Without a [mask], picks the
  /// one the standard's penalty rules score best.
  factory QrMatrix.encode(String text, {QrLevel level = QrLevel.low, int? mask}) {
    final data = utf8.encode(text);
    final l = level.index;
    var version = 1;
    while (true) {
      final countBits = version < 10 ? 8 : 16;
      if (4 + countBits + data.length * 8 <= _dataCodewords(version, l) * 8) break;
      if (++version > 40) throw ArgumentError('Too much data for a QR code: ${data.length} bytes');
    }
    final codewords = _withErrorCorrection(_dataBits(data, version, l), version, l);
    final base = _Builder(version, l)..drawFunctionPatterns()..drawCodewords(codewords);
    if (mask != null) return base.finish(mask);
    var bestPenalty = 1 << 62;
    QrMatrix? best;
    for (var m = 0; m < 8; m++) {
      final candidate = base.finish(m);
      final penalty = _penalty(candidate);
      if (penalty < bestPenalty) {
        bestPenalty = penalty;
        best = candidate;
      }
    }
    return best!;
  }

  static List<int> _dataBits(List<int> data, int version, int level) {
    final capacity = _dataCodewords(version, level) * 8;
    final bits = <int>[];
    void append(int value, int count) {
      for (var i = count - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    append(0x4, 4);
    append(data.length, version < 10 ? 8 : 16);
    for (final b in data) {
      append(b, 8);
    }
    append(0, min(4, capacity - bits.length));
    append(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < capacity; pad ^= 0xEC ^ 0x11) {
      append(pad, 8);
    }
    return [
      for (var i = 0; i < bits.length; i += 8) bits.sublist(i, i + 8).fold<int>(0, (a, b) => (a << 1) | b),
    ];
  }

  static List<int> _withErrorCorrection(List<int> data, int version, int level) {
    final blocks = _blockCount[level][version - 1];
    final ecc = _eccPerBlock[level][version - 1];
    final raw = _rawModules(version) ~/ 8;
    final shortBlocks = blocks - raw % blocks;
    final shortLength = raw ~/ blocks;
    final divisor = _reedSolomonDivisor(ecc);
    final out = <List<int>>[];
    var at = 0;
    for (var i = 0; i < blocks; i++) {
      final length = shortLength - ecc + (i < shortBlocks ? 0 : 1);
      final part = data.sublist(at, at + length);
      at += length;
      final remainder = _reedSolomonRemainder(part, divisor);
      // Short blocks hold a gap so columns of the interleave line up.
      out.add([...part, if (i < shortBlocks) -1, ...remainder]);
    }
    return [
      for (var column = 0; column < out.first.length; column++)
        for (final block in out)
          if (block[column] >= 0) block[column],
    ];
  }

  static int _penalty(QrMatrix q) {
    final n = q.size;
    var result = 0;
    int runs(bool Function(int a, int b) at) {
      var penalty = 0;
      for (var a = 0; a < n; a++) {
        var color = false;
        var run = 0;
        final history = List<int>.filled(7, 0, growable: true);
        void push(int value) {
          history
            ..removeLast()
            ..insert(0, value);
        }

        int finderLike() {
          final core = history[1];
          final ok = core > 0 && history[2] == core && history[3] == core * 3 && history[4] == core && history[5] == core;
          return (ok && history[0] >= core * 4 && history[6] >= core ? 1 : 0) + (ok && history[6] >= core * 4 && history[0] >= core ? 1 : 0);
        }

        for (var b = 0; b < n; b++) {
          final dark = at(a, b);
          if (dark == color) {
            run++;
            if (run == 5) {
              penalty += 3;
            } else if (run > 5) {
              penalty++;
            }
          } else {
            if (history[0] == 0) run += n;
            push(run);
            if (!color) penalty += finderLike() * 40;
            color = dark;
            run = 1;
          }
        }
        if (color) {
          if (history[0] == 0) run += n;
          push(run);
          run = 0;
        }
        run += n;
        if (history[0] == 0) run += n;
        push(run);
        penalty += finderLike() * 40;
      }
      return penalty;
    }

    result += runs((a, b) => q.isDark(a, b));
    result += runs((a, b) => q.isDark(b, a));
    var dark = 0;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (q.isDark(y, x)) dark++;
        if (y + 1 < n && x + 1 < n && q.isDark(y, x) == q.isDark(y, x + 1) && q.isDark(y, x) == q.isDark(y + 1, x) && q.isDark(y, x) == q.isDark(y + 1, x + 1)) result += 3;
      }
    }
    final total = n * n;
    result += (((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1) * 10;
    return result;
  }
}

class _Builder {
  _Builder(this.version, this.level) : size = version * 4 + 17 {
    modules = List<bool>.filled(size * size, false);
    function = List<bool>.filled(size * size, false);
  }

  final int version, level, size;
  late final List<bool> modules, function;

  void _set(int x, int y, bool dark) {
    modules[y * size + x] = dark;
    function[y * size + x] = true;
  }

  List<int> get _alignment {
    if (version == 1) return const [];
    final count = version ~/ 7 + 2;
    final step = version == 32 ? 26 : (version * 4 + count * 2 + 1) ~/ (count * 2 - 2) * 2;
    final result = <int>[6];
    for (var pos = size - 7; result.length < count; pos -= step) {
      result.insert(1, pos);
    }
    return result;
  }

  void drawFunctionPatterns() {
    for (var i = 0; i < size; i++) {
      _set(6, i, i.isEven);
      _set(i, 6, i.isEven);
    }
    void finder(int x, int y) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final dist = max(dx.abs(), dy.abs());
          final xx = x + dx, yy = y + dy;
          if (xx >= 0 && xx < size && yy >= 0 && yy < size) _set(xx, yy, dist != 2 && dist != 4);
        }
      }
    }

    finder(3, 3);
    finder(size - 4, 3);
    finder(3, size - 4);
    final align = _alignment;
    for (var i = 0; i < align.length; i++) {
      for (var j = 0; j < align.length; j++) {
        if ((i == 0 && j == 0) || (i == 0 && j == align.length - 1) || (i == align.length - 1 && j == 0)) continue;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            _set(align[i] + dx, align[j] + dy, max(dx.abs(), dy.abs()) != 1);
          }
        }
      }
    }
    _drawFormat(0, modules);
    if (version >= 7) {
      var rem = version;
      for (var i = 0; i < 12; i++) {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
      }
      final bits = version << 12 | rem;
      for (var i = 0; i < 18; i++) {
        final dark = (bits >> i) & 1 != 0;
        final a = size - 11 + i % 3, b = i ~/ 3;
        _set(a, b, dark);
        _set(b, a, dark);
      }
    }
  }

  void _drawFormat(int mask, List<bool> target) {
    final data = _levelBits[level] << 3 | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 != 0;
    void put(int x, int y, bool dark) {
      target[y * size + x] = dark;
      function[y * size + x] = true;
    }

    for (var i = 0; i <= 5; i++) {
      put(8, i, bit(i));
    }
    put(8, 7, bit(6));
    put(8, 8, bit(7));
    put(7, 8, bit(8));
    for (var i = 9; i < 15; i++) {
      put(14 - i, 8, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      put(size - 1 - i, 8, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      put(8, size - 15 + i, bit(i));
    }
    put(8, size - 8, true);
  }

  void drawCodewords(List<int> data) {
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!function[y * size + x] && i < data.length * 8) {
            modules[y * size + x] = (data[i >> 3] >> (7 - (i & 7))) & 1 != 0;
            i++;
          }
        }
      }
    }
  }

  QrMatrix finish(int mask) {
    final out = List<bool>.of(modules);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (function[y * size + x]) continue;
        final invert = switch (mask) {
          0 => (x + y) % 2 == 0,
          1 => y % 2 == 0,
          2 => x % 3 == 0,
          3 => (x + y) % 3 == 0,
          4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
          5 => x * y % 2 + x * y % 3 == 0,
          6 => (x * y % 2 + x * y % 3) % 2 == 0,
          _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
        };
        if (invert) out[y * size + x] = !out[y * size + x];
      }
    }
    _drawFormat(mask, out);
    return QrMatrix._(size, version, mask, out);
  }
}

/// Draws a QR code. A quiet zone is the caller's: put it on a light background with some margin.
void paintQr(Canvas canvas, Size size, QrMatrix qr, {required Color color}) {
  final cell = min(size.width, size.height) / qr.size;
  final paint = Paint()
    ..color = color
    ..isAntiAlias = false;
  for (var y = 0; y < qr.size; y++) {
    for (var x = 0; x < qr.size; x++) {
      if (!qr.isDark(y, x)) continue;
      // A hair wider, so no seams show between cells when the size isn't a whole number.
      canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + .5, cell + .5), paint);
    }
  }
}

class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, required this.size, this.color = Colors.black});

  final String data;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _QrPainter(QrMatrix.encode(data), color));
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr, this.color);

  final QrMatrix qr;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => paintQr(canvas, size, qr, color: color);

  @override
  bool shouldRepaint(_QrPainter old) => !identical(old.qr, qr) || old.color != color;
}
