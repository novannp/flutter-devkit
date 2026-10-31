import 'dart:ui';

import 'device_adb.dart';

/// Screen input in relative coordinates (0..1) so it can be replayed on devices with other resolutions.
sealed class ScreenInput {
  const ScreenInput();
}

class TapInput extends ScreenInput {
  const TapInput(this.x, this.y);
  final double x, y;
}

class SwipeInput extends ScreenInput {
  const SwipeInput(this.x1, this.y1, this.x2, this.y2, this.ms);
  final double x1, y1, x2, y2;
  final int ms;
}

class KeyInput extends ScreenInput {
  const KeyInput(this.keycode);
  final String keycode;
}

class TypeInput extends ScreenInput {
  const TypeInput(this.text);
  final String text;
}

/// Last known screen size per device; set by ScreenPanel.
class ScreenMirrorController {
  Size? size;
}

Future<void> applyInput(DeviceAdb dev, Size size, ScreenInput input) {
  int px(double f) => (f * size.width).round();
  int py(double f) => (f * size.height).round();
  return switch (input) {
    TapInput(:final x, :final y) => dev.tap(px(x), py(y)),
    SwipeInput(:final x1, :final y1, :final x2, :final y2, :final ms) => dev.swipe(px(x1), py(y1), px(x2), py(y2), ms),
    KeyInput(:final keycode) => dev.key(keycode),
    TypeInput(:final text) => dev.text(text),
  };
}
