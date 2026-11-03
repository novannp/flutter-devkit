import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One drawable, with what it inherited from its groups already applied.
class SvgShape {
  const SvgShape(this.path, this.matrix, {this.fill, this.stroke, this.strokeWidth = 1, this.cap = StrokeCap.butt, this.join = StrokeJoin.miter});

  final ui.Path path;
  final Float64List matrix;
  final Color? fill, stroke;
  final double strokeWidth;
  final StrokeCap cap;
  final StrokeJoin join;
}

class SvgImage {
  const SvgImage(this.viewBox, this.shapes);

  final Rect viewBox;
  final List<SvgShape> shapes;
}

const _namedColors = {
  'black': 0xFF000000,
  'white': 0xFFFFFFFF,
  'red': 0xFFFF0000,
  'green': 0xFF008000,
  'lime': 0xFF00FF00,
  'blue': 0xFF0000FF,
  'yellow': 0xFFFFFF00,
  'orange': 0xFFFFA500,
  'purple': 0xFF800080,
  'pink': 0xFFFFC0CB,
  'brown': 0xFFA52A2A,
  'cyan': 0xFF00FFFF,
  'magenta': 0xFFFF00FF,
  'navy': 0xFF000080,
  'teal': 0xFF008080,
  'gray': 0xFF808080,
  'grey': 0xFF808080,
  'silver': 0xFFC0C0C0,
  'gold': 0xFFFFD700,
};

Color? _parseColor(String value) {
  final v = value.trim().toLowerCase();
  if (v.startsWith('#')) {
    final hex = v.substring(1);
    final full = switch (hex.length) {
      3 || 4 => hex.split('').map((c) => '$c$c').join(),
      6 || 8 => hex,
      _ => null,
    };
    if (full == null) return null;
    final n = int.tryParse(full, radix: 16);
    if (n == null) return null;
    return Color(full.length == 6 ? 0xFF000000 | n : ((n & 0xFF) << 24) | (n >>> 8));
  }
  final rgb = RegExp(r'^rgba?\(([^)]*)\)').firstMatch(v);
  if (rgb != null) {
    final parts = rgb[1]!.split(RegExp(r'[\s,/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) return null;
    int channel(String s) => (s.endsWith('%') ? (double.tryParse(s.substring(0, s.length - 1)) ?? 0) * 2.55 : (double.tryParse(s) ?? 0)).round().clamp(0, 255);
    final alpha = parts.length > 3 ? (double.tryParse(parts[3]) ?? 1).clamp(0.0, 1.0) : 1.0;
    return Color.fromARGB((alpha * 255).round(), channel(parts[0]), channel(parts[1]), channel(parts[2]));
  }
  final named = _namedColors[v];
  return named == null ? null : Color(named);
}

/// Reads path data, where numbers can run together: `1-2.5.5` is three, and an arc's flags need no spaces at all.
class _PathScanner {
  _PathScanner(this.text);

  final String text;
  var at = 0;
  static final _number = RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?');

  void _skip() {
    while (at < text.length && ' ,\t\r\n'.contains(text[at])) {
      at++;
    }
  }

  bool get done {
    _skip();
    return at >= text.length;
  }

  bool get atCommand {
    _skip();
    return at < text.length && RegExp('[a-zA-Z]').hasMatch(text[at]) && text[at] != 'e' && text[at] != 'E';
  }

  String command() => text[at++];

  double? number() {
    _skip();
    final m = _number.matchAsPrefix(text, at);
    if (m == null) return null;
    at = m.end;
    return double.tryParse(m[0]!);
  }

  bool? flag() {
    _skip();
    if (at >= text.length || (text[at] != '0' && text[at] != '1')) return null;
    return text[at++] == '1';
  }
}

ui.Path parseSvgPath(String data) {
  final path = ui.Path();
  final s = _PathScanner(data);
  var cur = Offset.zero, start = Offset.zero, control = Offset.zero;
  String? cmd, last;
  while (!s.done) {
    if (s.atCommand) {
      cmd = s.command();
    } else if (cmd == null) {
      break;
    }
    final c = cmd;
    final rel = c == c.toLowerCase();
    final base = rel ? cur : Offset.zero;
    Offset? point() {
      final x = s.number(), y = s.number();
      return x == null || y == null ? null : base + Offset(x, y);
    }

    switch (c.toUpperCase()) {
      case 'M':
        final to = point();
        if (to == null) return path;
        path.moveTo(to.dx, to.dy);
        cur = start = control = to;
        cmd = rel ? 'l' : 'L';
      case 'L':
        final to = point();
        if (to == null) return path;
        path.lineTo(to.dx, to.dy);
        cur = control = to;
      case 'H':
        final x = s.number();
        if (x == null) return path;
        cur = control = Offset(rel ? cur.dx + x : x, cur.dy);
        path.lineTo(cur.dx, cur.dy);
      case 'V':
        final y = s.number();
        if (y == null) return path;
        cur = control = Offset(cur.dx, rel ? cur.dy + y : y);
        path.lineTo(cur.dx, cur.dy);
      case 'C':
        final a = point(), b = point(), to = point();
        if (a == null || b == null || to == null) return path;
        path.cubicTo(a.dx, a.dy, b.dx, b.dy, to.dx, to.dy);
        control = b;
        cur = to;
      case 'S':
        final b = point(), to = point();
        if (b == null || to == null) return path;
        final a = last != null && 'CS'.contains(last.toUpperCase()) ? cur * 2 - control : cur;
        path.cubicTo(a.dx, a.dy, b.dx, b.dy, to.dx, to.dy);
        control = b;
        cur = to;
      case 'Q':
        final a = point(), to = point();
        if (a == null || to == null) return path;
        path.quadraticBezierTo(a.dx, a.dy, to.dx, to.dy);
        control = a;
        cur = to;
      case 'T':
        final to = point();
        if (to == null) return path;
        final a = last != null && 'QT'.contains(last.toUpperCase()) ? cur * 2 - control : cur;
        path.quadraticBezierTo(a.dx, a.dy, to.dx, to.dy);
        control = a;
        cur = to;
      case 'A':
        final rx = s.number(), ry = s.number(), rotation = s.number(), large = s.flag(), sweep = s.flag(), to = point();
        if (rx == null || ry == null || rotation == null || large == null || sweep == null || to == null) return path;
        path.arcToPoint(to, radius: Radius.elliptical(rx.abs(), ry.abs()), rotation: rotation, largeArc: large, clockwise: sweep);
        cur = control = to;
      case 'Z':
        path.close();
        cur = control = start;
      default:
        return path;
    }
    last = c;
  }
  return path;
}

List<double> _numbers(String text) => [for (final m in RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?').allMatches(text)) double.parse(m[0]!)];

Matrix4 _parseTransform(String text) {
  final out = Matrix4.identity();
  for (final m in RegExp(r'(\w+)\s*\(([^)]*)\)').allMatches(text)) {
    final n = _numbers(m[2]!);
    if (n.isEmpty) continue;
    final Matrix4? step = switch (m[1]) {
      'translate' => Matrix4.translationValues(n[0], n.length > 1 ? n[1] : 0, 0),
      'scale' => Matrix4.diagonal3Values(n[0], n.length > 1 ? n[1] : n[0], 1),
      'rotate' => () {
        final turn = Matrix4.rotationZ(n[0] * pi / 180);
        if (n.length < 3) return turn;
        return Matrix4.translationValues(n[1], n[2], 0)
          ..multiply(turn)
          ..multiply(Matrix4.translationValues(-n[1], -n[2], 0));
      }(),
      'skewX' => Matrix4.skewX(n[0] * pi / 180),
      'skewY' => Matrix4.skewY(n[0] * pi / 180),
      'matrix' when n.length == 6 => Matrix4(n[0], n[1], 0, 0, n[2], n[3], 0, 0, 0, 0, 1, 0, n[4], n[5], 0, 1),
      _ => null,
    };
    if (step != null) out.multiply(step);
  }
  return out;
}

ui.Path? _shapePath(String tag, Map<String, String> a) {
  double n(String key) => double.tryParse((a[key] ?? '').replaceAll(RegExp(r'[a-z%]+$'), '')) ?? 0;
  switch (tag) {
    case 'path':
      return parseSvgPath(a['d'] ?? '');
    case 'rect':
      final r = Rect.fromLTWH(n('x'), n('y'), n('width'), n('height'));
      final rx = a.containsKey('rx') ? n('rx') : n('ry'), ry = a.containsKey('ry') ? n('ry') : n('rx');
      return ui.Path()..addRRect(RRect.fromRectXY(r, min(rx, r.width / 2), min(ry, r.height / 2)));
    case 'circle':
      return ui.Path()..addOval(Rect.fromCircle(center: Offset(n('cx'), n('cy')), radius: n('r')));
    case 'ellipse':
      return ui.Path()..addOval(Rect.fromCenter(center: Offset(n('cx'), n('cy')), width: n('rx') * 2, height: n('ry') * 2));
    case 'line':
      return ui.Path()
        ..moveTo(n('x1'), n('y1'))
        ..lineTo(n('x2'), n('y2'));
    case 'polyline' || 'polygon':
      final v = _numbers(a['points'] ?? '');
      final path = ui.Path();
      for (var i = 0; i + 1 < v.length; i += 2) {
        i == 0 ? path.moveTo(v[i], v[i + 1]) : path.lineTo(v[i], v[i + 1]);
      }
      if (tag == 'polygon') path.close();
      return path;
  }
  return null;
}

final _tags = RegExp(r'''<(/?)([\w:.-]+)((?:\s+[\w:.-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(/?)>''');
final _attributes = RegExp(r'''([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

/// The common part of SVG: shapes, groups, transforms and solid colors. A gradient paints as its first color.
SvgImage? parseSvg(String source) {
  final clean = source.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final shapes = <SvgShape>[];
  final gradients = <String, Color>{};
  Rect? viewBox;
  final inherited = <Map<String, String>>[{}];
  final matrices = <Matrix4>[Matrix4.identity()];
  var hidden = 0;
  String? gradient;
  const hiddenTags = {'defs', 'clipPath', 'mask', 'symbol', 'pattern', 'title', 'desc', 'metadata', 'style', 'script'};
  const paintKeys = ['fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin', 'opacity', 'fill-opacity', 'stroke-opacity', 'fill-rule', 'clip-rule', 'color'];

  for (final m in _tags.allMatches(clean)) {
    final closing = m[1]!.isNotEmpty, selfClosing = m[4]!.isNotEmpty;
    final tag = m[2]!.split(':').last;
    if (closing) {
      if (hiddenTags.contains(tag)) {
        hidden = max(0, hidden - 1);
      } else if (tag == 'g' || tag == 'svg' || tag == 'a') {
        if (inherited.length > 1) {
          inherited.removeLast();
          matrices.removeLast();
        }
      } else if (tag.endsWith('Gradient')) {
        gradient = null;
      }
      continue;
    }
    final a = <String, String>{
      for (final at in _attributes.allMatches(m[3]!)) at[1]!: at[2] ?? at[3] ?? '',
    };
    for (final rule in (a['style'] ?? '').split(';')) {
      final split = rule.indexOf(':');
      if (split > 0) a[rule.substring(0, split).trim()] = rule.substring(split + 1).trim();
    }
    if (tag == 'linearGradient' || tag == 'radialGradient') {
      gradient = selfClosing ? null : a['id'];
      continue;
    }
    if (tag == 'stop') {
      final color = _parseColor(a['stop-color'] ?? 'black');
      if (gradient != null && color != null) gradients.putIfAbsent(gradient, () => color);
      continue;
    }
    if (hiddenTags.contains(tag)) {
      if (!selfClosing) hidden++;
      continue;
    }
    if (hidden > 0) continue;
    final style = <String, String>{...inherited.last};
    final opacity = (double.tryParse(style['opacity'] ?? '') ?? 1) * (double.tryParse(a['opacity'] ?? '') ?? 1);
    for (final key in paintKeys) {
      if (a[key] case final value?) style[key] = value;
    }
    style['opacity'] = '$opacity';
    final matrix = matrices.last.clone();
    if (a['transform'] case final t?) matrix.multiply(_parseTransform(t));

    if (tag == 'svg' || tag == 'g' || tag == 'a') {
      if (tag == 'svg' && viewBox == null) {
        final box = _numbers(a['viewBox'] ?? '');
        final w = _numbers(a['width'] ?? ''), h = _numbers(a['height'] ?? '');
        if (box.length == 4) {
          viewBox = Rect.fromLTWH(box[0], box[1], box[2], box[3]);
        } else if (w.isNotEmpty && h.isNotEmpty) {
          viewBox = Rect.fromLTWH(0, 0, w.first, h.first);
        }
      }
      if (!selfClosing) {
        inherited.add(style);
        matrices.add(matrix);
      }
      continue;
    }
    final path = _shapePath(tag, a);
    if (path == null) continue;
    path.fillType = style['fill-rule'] == 'evenodd' ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
    Color? paint(String? value, double alpha) {
      if (value == null || value == 'none' || value == 'transparent') return null;
      final link = RegExp(r'url\(#([^)]+)\)').firstMatch(value);
      final color = link != null ? gradients[link[1]] : (value == 'currentColor' ? _parseColor(style['color'] ?? 'black') : _parseColor(value));
      return color?.withValues(alpha: color.a * alpha * opacity);
    }

    shapes.add(SvgShape(
      path,
      Float64List.fromList(matrix.storage),
      fill: paint(style['fill'] ?? 'black', double.tryParse(style['fill-opacity'] ?? '') ?? 1),
      stroke: paint(style['stroke'], double.tryParse(style['stroke-opacity'] ?? '') ?? 1),
      strokeWidth: _numbers(style['stroke-width'] ?? '1').firstOrNull ?? 1,
      cap: switch (style['stroke-linecap']) {
        'round' => StrokeCap.round,
        'square' => StrokeCap.square,
        _ => StrokeCap.butt,
      },
      join: switch (style['stroke-linejoin']) {
        'round' => StrokeJoin.round,
        'bevel' => StrokeJoin.bevel,
        _ => StrokeJoin.miter,
      },
    ));
  }
  if (viewBox == null && !clean.contains('<svg')) return null;
  return SvgImage(viewBox ?? const Rect.fromLTWH(0, 0, 100, 100), shapes);
}

class SvgView extends StatelessWidget {
  const SvgView(this.image, {super.key});

  final SvgImage image;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: image.viewBox.height <= 0 ? 1 : max(.01, image.viewBox.width / image.viewBox.height),
    child: CustomPaint(painter: _SvgPainter(image)),
  );
}

class _SvgPainter extends CustomPainter {
  const _SvgPainter(this.image);

  final SvgImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final box = image.viewBox;
    if (box.width <= 0 || box.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / box.width, size.height / box.height);
    canvas.translate(-box.left, -box.top);
    for (final s in image.shapes) {
      canvas.save();
      canvas.transform(s.matrix);
      if (s.fill case final fill?) canvas.drawPath(s.path, Paint()..color = fill..isAntiAlias = true);
      if (s.stroke case final stroke?) {
        canvas.drawPath(
          s.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = stroke
            ..strokeWidth = s.strokeWidth
            ..strokeCap = s.cap
            ..strokeJoin = s.join,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SvgPainter old) => !identical(old.image, image);
}
