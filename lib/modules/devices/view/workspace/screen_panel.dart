import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/device_adb.dart';
import '../../services/screen_input.dart';

/// Lightweight screencap-based mirror. For a smooth screen use scrcpy (Remote button).
class ScreenPanel extends StatefulWidget {
  const ScreenPanel({super.key, required this.dev, this.controller, this.onInput, this.compact = false});

  final DeviceAdb dev;
  final ScreenMirrorController? controller;

  /// Called for every input sent to this device (to broadcast to other devices).
  final void Function(ScreenInput input)? onInput;

  /// Compact view for the Multi Screen grid.
  final bool compact;

  @override
  State<ScreenPanel> createState() => _ScreenPanelState();
}

class _ScreenPanelState extends State<ScreenPanel> {
  Uint8List? _frame;
  Size? _size;
  var _live = true;
  var _loading = false;
  String? _error;
  Offset? _panStart;
  Offset? _panLast;
  final _panWatch = Stopwatch();
  final _keys = FocusNode(debugLabel: 'device-keyboard');
  final _pendingText = StringBuffer();
  Timer? _textFlush;
  final _frameTimes = <DateTime>[];
  var _loopId = 0;

  static final _keyMap = {
    LogicalKeyboardKey.backspace: 'KEYCODE_DEL',
    LogicalKeyboardKey.delete: 'KEYCODE_FORWARD_DEL',
    LogicalKeyboardKey.enter: 'KEYCODE_ENTER',
    LogicalKeyboardKey.numpadEnter: 'KEYCODE_ENTER',
    LogicalKeyboardKey.tab: 'KEYCODE_TAB',
    LogicalKeyboardKey.escape: 'KEYCODE_BACK',
    LogicalKeyboardKey.arrowUp: 'KEYCODE_DPAD_UP',
    LogicalKeyboardKey.arrowDown: 'KEYCODE_DPAD_DOWN',
    LogicalKeyboardKey.arrowLeft: 'KEYCODE_DPAD_LEFT',
    LogicalKeyboardKey.arrowRight: 'KEYCODE_DPAD_RIGHT',
    LogicalKeyboardKey.home: 'KEYCODE_MOVE_HOME',
    LogicalKeyboardKey.end: 'KEYCODE_MOVE_END',
  };

  DeviceAdb get dev => widget.dev;

  @override
  void initState() {
    super.initState();
    _loop();
  }

  @override
  void dispose() {
    _live = false;
    _keys.dispose();
    _textFlush?.cancel();
    super.dispose();
  }

  Future<void> _loop() async {
    // Prevent two loops running at once if live is toggled quickly.
    final id = ++_loopId;
    while (mounted && _live && id == _loopId) {
      await _capture();
      // Device disconnected: retry slowly, don't spam adb processes.
      await Future<void>.delayed(Duration(milliseconds: _error == null ? 150 : 2000));
    }
  }

  Future<void> _capture() async {
    if (_loading) return;
    _loading = true;
    final bytes = await dev.screenshot();
    _loading = false;
    if (!mounted) return;
    setState(() {
      if (bytes == null || bytes.length < 24) {
        _error = 'Device not connected to ADB\n(cable unplugged / ADB Wi-Fi dropped)\n\nRetrying automatically…';
        return;
      }
      _error = null;
      _frame = bytes;
      // Size from the PNG header (IHDR), same as `input tap` coordinates.
      final view = ByteData.sublistView(bytes);
      _size = Size(view.getUint32(16).toDouble(), view.getUint32(20).toDouble());
      widget.controller?.size = _size;
      final now = DateTime.now();
      _frameTimes
        ..add(now)
        ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
    });
  }

  double get _fps => _frameTimes.length < 2
      ? 0
      : (_frameTimes.length - 1) / (_frameTimes.last.difference(_frameTimes.first).inMilliseconds / 1000);

  Offset _rel(Offset local, Size box) =>
      Offset((local.dx / box.width).clamp(0, 1), (local.dy / box.height).clamp(0, 1));

  Future<void> _after(Future<void> action) async {
    await action;
    if (!_live) _capture();
  }

  void _send(ScreenInput input) {
    final size = _size;
    if (size == null && (input is TapInput || input is SwipeInput)) return;
    _after(applyInput(dev, size ?? Size.zero, input));
    widget.onInput?.call(input);
  }

  // Batch keystrokes; one `adb shell input` per character is too slow.
  void _flushText() {
    if (_pendingText.isEmpty) return;
    final text = _pendingText.toString();
    _pendingText.clear();
    _send(TypeInput(text));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed && e.logicalKey == LogicalKeyboardKey.keyV) {
      Clipboard.getData(Clipboard.kTextPlain).then((d) {
        final t = d?.text;
        if (t != null && t.isNotEmpty) _send(TypeInput(t));
      });
      return KeyEventResult.handled;
    }
    // Other Ctrl/Alt combos bubble up to workspace shortcuts.
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) return KeyEventResult.ignored;
    final mapped = _keyMap[e.logicalKey];
    if (mapped != null) {
      _textFlush?.cancel();
      _flushText();
      _send(KeyInput(mapped));
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _pendingText.write(ch);
      _textFlush?.cancel();
      _textFlush = Timer(const Duration(milliseconds: 150), _flushText);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleLive() {
    setState(() => _live = !_live);
    if (_live) _loop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 11.5, color: scheme.outline);
    final size = _size;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: widget.compact ? const EdgeInsets.all(4) : const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Center(child: _buildScreen(scheme)),
          ),
        ),
        if (!widget.compact)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
          child: Row(
            children: [
              InkWell(
                onTap: _toggleLive,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    children: [
                      Icon(_live ? Icons.circle : Icons.pause_circle_outline,
                          size: 9, color: _live ? Colors.green : scheme.outline),
                      const SizedBox(width: 6),
                      Text(
                        _live
                            ? '${_fps.toStringAsFixed(1)} fps · ${size == null ? '-' : '${size.width.round()}×${size.height.round()}'} · adb'
                            : 'Paused (click to resume)',
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Text(
                _keys.hasFocus ? '⌨ keyboard → device · Esc = Back · Ctrl+V = paste' : 'click screen to type from keyboard',
                style: _keys.hasFocus ? muted.copyWith(color: scheme.primary) : muted,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScreen(ColorScheme scheme) {
    if (_frame == null || _size == null) {
      return _error != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _capture, child: const Text('Retry')),
              ],
            )
          : const CircularProgressIndicator();
    }
    final borderColor = _keys.hasFocus ? scheme.primary : (_live ? Colors.green : scheme.outlineVariant);
    return AspectRatio(
      aspectRatio: _size!.width / _size!.height,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(
            builder: (context, box) {
              final boxSize = Size(box.maxWidth, box.maxHeight);
              return Listener(
                onPointerSignal: (e) {
                  if (e is! PointerScrollEvent) return;
                  final p = _rel(e.localPosition, boxSize);
                  final dy = (-e.scrollDelta.dy * 3 / _size!.height).clamp(-0.5, 0.5);
                  _send(SwipeInput(p.dx, p.dy, p.dx, (p.dy + dy).clamp(0, 1), 150));
                },
                child: GestureDetector(
                  onTapUp: (e) {
                    _keys.requestFocus();
                    final p = _rel(e.localPosition, boxSize);
                    _send(TapInput(p.dx, p.dy));
                  },
                  onLongPressStart: (e) {
                    final p = _rel(e.localPosition, boxSize);
                    _send(SwipeInput(p.dx, p.dy, p.dx, p.dy, 800));
                  },
                  onPanStart: (e) {
                    _panStart = _panLast = e.localPosition;
                    _panWatch
                      ..reset()
                      ..start();
                  },
                  onPanUpdate: (e) => _panLast = e.localPosition,
                  onPanEnd: (_) {
                    final a = _rel(_panStart!, boxSize);
                    final b = _rel(_panLast!, boxSize);
                    final ms = _panWatch.elapsedMilliseconds.clamp(80, 2000);
                    _send(SwipeInput(a.dx, a.dy, b.dx, b.dy, ms));
                  },
                  child: Focus(
                    focusNode: _keys,
                    onKeyEvent: _onKey,
                    onFocusChange: (_) => setState(() {}),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Image.memory(_frame!, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Vertical toolbar beside the screen.
class DeviceToolbar extends StatelessWidget {
  const DeviceToolbar({super.key, required this.dev, required this.onScreenshot, required this.onRecord, required this.recording});

  final DeviceAdb dev;
  final VoidCallback onScreenshot;
  final VoidCallback onRecord;
  final bool recording;

  // user_rotation 0..3; rotation relative to the current position.
  Future<void> _rotate(int delta) async {
    final current = int.tryParse(await dev.sh('settings get system user_rotation')) ?? 0;
    await dev.shell('settings put system accelerometer_rotation 0; '
        'settings put system user_rotation ${(current + delta) % 4}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: IconButton(
            tooltip: tip,
            onPressed: onTap,
            style: IconButton.styleFrom(
              backgroundColor: scheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: Icon(icon, size: 18, color: color),
          ),
        );
    const gap = SizedBox(height: 10);

    return Container(
      width: 54,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border.symmetric(vertical: BorderSide(color: scheme.outlineVariant))),
      child: SingleChildScrollView(
        child: Column(
          children: [
            btn(Icons.power_settings_new, 'Power', () => dev.key('KEYCODE_POWER')),
            btn(Icons.volume_up, 'Volume +', () => dev.key('KEYCODE_VOLUME_UP')),
            btn(Icons.volume_down, 'Volume -', () => dev.key('KEYCODE_VOLUME_DOWN')),
            gap,
            btn(Icons.rotate_left, 'Rotate left', () => _rotate(1)),
            btn(Icons.rotate_right, 'Rotate right', () => _rotate(3)),
            gap,
            btn(Icons.arrow_back_ios_new, 'Back (Esc)', () => dev.key('KEYCODE_BACK')),
            btn(Icons.circle_outlined, 'Home', () => dev.key('KEYCODE_HOME')),
            btn(Icons.crop_square, 'Recent apps', () => dev.key('KEYCODE_APP_SWITCH')),
            gap,
            btn(Icons.photo_camera_outlined, 'Screenshot + copy (Ctrl+S)', onScreenshot),
            btn(
              recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
              recording ? 'Records when Remote opens' : 'Record screen (via Remote)',
              onRecord,
              color: recording ? Colors.red : null,
            ),
            btn(Icons.notifications_outlined, 'Open notifications', () => dev.shell('cmd statusbar expand-notifications')),
            btn(Icons.lock_open, 'Wake & unlock', () => dev.shell('input keyevent KEYCODE_WAKEUP; input keyevent 82')),
          ],
        ),
      ),
    );
  }
}
