import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/device.dart';
import 'device_adb.dart';

const _labelDir = '/sdcard/Pictures/RavoDevKit';

/// A wallpaper with the device's name, IP, model and serial, so identical tablets can be told apart.
Future<List<int>> renderDeviceLabel(Device d, {required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), const [Color(0xFF0F172A), Color(0xFF1E3A5F)]),
  );
  final unit = size.shortestSide / 100;

  TextPainter paragraph(
    String text,
    double fontSize,
    Color color, {
    FontWeight weight = FontWeight.w400,
    int maxLines = 2,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, color: color, fontWeight: weight, fontFamily: 'Segoe UI'),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: size.width * 0.9);

  final title = paragraph(d.displayName, unit * 13, Colors.white, weight: FontWeight.w700);
  final details = paragraph(
    [d.model, d.ip ?? 'USB', if (d.serial != null) 'SN ${d.serial}'].nonNulls.join('\n'),
    unit * 4.5,
    const Color(0xCCFFFFFF),
    maxLines: 3,
  );
  final qrSize = unit * 28;
  final gap = unit * 5;
  final total = title.height + gap + details.height + gap + qrSize;

  // Centered vertically so launchers and lock screens crop as little as possible.
  var y = (size.height - total) / 2;
  title.paint(canvas, Offset((size.width - title.width) / 2, y));
  y += title.height + gap;
  details.paint(canvas, Offset((size.width - details.width) / 2, y));
  y += details.height + gap;
  canvas.save();
  canvas.translate((size.width - qrSize) / 2, y);
  QrPainter(
    data: [d.displayName, d.adbTarget, d.serial].nonNulls.join('\n'),
    version: QrVersions.auto,
    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.white),
    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.white),
  ).paint(canvas, Size.square(qrSize));
  canvas.restore();

  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

extension DeviceLabel on DeviceAdb {
  /// Pushes the label image and opens Android's "Set as" picker; apps can't set a wallpaper over adb without root.
  Future<String> setLabelWallpaper(Device d) async {
    final m = RegExp(r'Physical size: (\d+)x(\d+)').firstMatch(await sh('wm size'));
    final png = await renderDeviceLabel(
      d,
      width: int.tryParse(m?[1] ?? '') ?? 1080,
      height: int.tryParse(m?[2] ?? '') ?? 1920,
    );
    final local = File('${Directory.systemTemp.path}${Platform.pathSeparator}ravo_label.png');
    await local.writeAsBytes(png);

    // A new name each time, so the media store doesn't hand back a stale cached image.
    final name = 'ravo_label_${DateTime.now().millisecondsSinceEpoch}.png';
    await shell('rm -f $_labelDir/ravo_label_*.png; mkdir -p $_labelDir');
    if (!(await push(local.path, '$_labelDir/$name')).ok) return 'Could not copy the label to ${d.displayName}';
    await shell(
      'am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://$_labelDir/$name > /dev/null; '
      'content call --uri content://media/ --method scan_volume --arg external_primary > /dev/null 2>&1',
    );

    String? id;
    for (var i = 0; i < 6 && id == null; i++) {
      final out = await sh(
        "content query --uri content://media/external/images/media --projection _id --where \"_display_name='$name'\"",
      );
      id = RegExp(r'_id=(\d+)').firstMatch(out)?[1];
      if (id == null) await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (id == null) return 'Label saved to Pictures/RavoDevKit on ${d.displayName}; set it as wallpaper from Gallery';
    await shell(
      'input keyevent KEYCODE_WAKEUP; '
      'am start -a android.intent.action.ATTACH_DATA -d content://media/external/images/media/$id -t image/png -f 1',
    );
    return 'On ${d.displayName}: choose Wallpaper to apply the label';
  }
}
