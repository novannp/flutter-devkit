import '../../core/qr.dart';
import 'dart:math';

import 'package:flutter/material.dart';

import 'escpos.dart';

/// Renders an ESC/POS receipt like thermal paper.
class ReceiptPaper extends StatelessWidget {
  const ReceiptPaper({super.key, required this.elements, required this.paperMm});

  final List<ReceiptElement> elements;
  final int paperMm;

  int get _dots => paperMm >= 80 ? 576 : 384;
  int get _chars => paperMm >= 80 ? 48 : 32;

  @override
  Widget build(BuildContext context) {
    final width = paperMm >= 80 ? 380.0 : 270.0;
    final scale = width / _dots;
    // Consolas char width ≈ 0.55 × font size; tuned so N columns fill the paper width.
    final fontSize = width / (_chars * 0.55);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width + 32,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: DefaultTextStyle(
            style: TextStyle(fontFamily: 'Consolas', fontSize: fontSize, color: const Color(0xFF111111), height: 1.25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final e in elements) _element(e, scale, fontSize)],
            ),
          ),
        ),
        CustomPaint(size: Size(width + 32, 10), painter: _ZigzagPainter()),
      ],
    );
  }

  Alignment _align(ReceiptAlign a) => switch (a) {
    ReceiptAlign.center => Alignment.center,
    ReceiptAlign.right => Alignment.centerRight,
    ReceiptAlign.left => Alignment.centerLeft,
  };

  Widget _element(ReceiptElement e, double scale, double fontSize) {
    return switch (e) {
      TextLine() => Align(
        alignment: _align(e.align),
        child: e.runs.isEmpty
            ? SizedBox(height: fontSize * 1.25)
            : Text.rich(
                TextSpan(
                  children: [
                    for (final r in e.runs)
                      TextSpan(
                        text: r.text,
                        style: TextStyle(
                          fontWeight: r.style.bold ? FontWeight.bold : FontWeight.normal,
                          decoration: r.style.underline ? TextDecoration.underline : null,
                          fontSize: fontSize * max(r.style.width, r.style.height),
                          color: r.style.invert ? Colors.white : null,
                          backgroundColor: r.style.invert ? Colors.black : null,
                        ),
                      ),
                  ],
                ),
                softWrap: true,
              ),
      ),
      RasterImage() => Align(
        alignment: _align(e.align),
        child: CustomPaint(size: Size(e.width * scale, e.height * scale), painter: _RasterPainter(e)),
      ),
      QrElement() => Align(
        alignment: _align(e.align),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: QrView(data: e.data.isEmpty ? ' ' : e.data, size: max(80, e.moduleSize * 25 * scale)),
        ),
      ),
      BarcodeElement() => Align(
        alignment: _align(e.align),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              CustomPaint(size: const Size(200, 48), painter: _BarcodePainter(e.data)),
              Text(e.data, style: TextStyle(fontSize: fontSize * 0.9)),
            ],
          ),
        ),
      ),
      FeedElement() => SizedBox(height: fontSize * 1.25 * e.lines),
      EventElement() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(20)),
            child: Text(
              '⚡ ${e.label}',
              style: const TextStyle(fontFamily: 'Segoe UI', fontSize: 12, color: Color(0xFFB45309)),
            ),
          ),
        ),
      ),
    };
  }
}

class _RasterPainter extends CustomPainter {
  _RasterPainter(this.image);

  final RasterImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / image.width;
    final sy = size.height / image.height;
    final paint = Paint()..color = const Color(0xFF111111);
    // Merge consecutive black pixels per row into one rect for speed.
    for (var y = 0; y < image.height; y++) {
      var start = -1;
      for (var x = 0; x <= image.width; x++) {
        final on = x < image.width && image.pixel(x, y);
        if (on && start < 0) start = x;
        if (!on && start >= 0) {
          canvas.drawRect(Rect.fromLTWH(start * sx, y * sy, (x - start) * sx + 0.3, sy + 0.3), paint);
          start = -1;
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RasterPainter old) => old.image != image;
}

class _BarcodePainter extends CustomPainter {
  _BarcodePainter(this.data);

  final String data;

  // Not a real barcode encoding; just a visual marker, the data is shown below.
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final rnd = Random(data.hashCode);
    var x = 0.0;
    while (x < size.width) {
      final w = 1.0 + rnd.nextInt(3);
      if (rnd.nextBool()) canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
      x += w + 1;
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) => old.data != data;
}

class _ZigzagPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, 0);
    const tooth = 10.0;
    for (var x = 0.0; x < size.width; x += tooth) {
      path
        ..lineTo(x + tooth / 2, size.height)
        ..lineTo(x + tooth, 0);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ZigzagPainter old) => false;
}
