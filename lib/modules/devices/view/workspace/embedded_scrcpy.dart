import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/embed_window.dart';
import '../../services/adb_service.dart';

var _counter = 0;

// One persistent frame callback for all embeds: follows layout on frames that happen anyway, never forces new ones.
final _active = <_EmbeddedScrcpyState>{};
var _frameHooked = false;

void _watch(_EmbeddedScrcpyState s) {
  _active.add(s);
  if (_frameHooked) return;
  _frameHooked = true;
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (_active.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final e in _active.toList()) {
        e._syncPosition();
      }
    });
  });
}

/// scrcpy with its window embedded in this widget's area: smooth 60 fps, still inside DevKit.
/// Note: the native window always sits above Flutter widgets, so it's hidden while a dialog/menu is open.
class EmbeddedScrcpy extends StatefulWidget {
  const EmbeddedScrcpy({super.key, required this.adb, required this.target, this.maxSize, this.onFailed});

  final AdbService adb;
  final String target;
  final int? maxSize;

  /// Called when scrcpy can't run, so the caller can fall back to lite mode.
  final void Function(String reason)? onFailed;

  @override
  State<EmbeddedScrcpy> createState() => _EmbeddedScrcpyState();
}

class _EmbeddedScrcpyState extends State<EmbeddedScrcpy> {
  final _title = 'devkit-embed-$pid-${_counter++}';
  Process? _process;
  int? _hwnd;
  Timer? _sync;
  DateTime _lastResize = DateTime(0);
  Rect? _lastRect;
  var _hidden = false;
  var _visibleInTree = true;
  String? _error;
  final _log = StringBuffer();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final scrcpy = widget.adb.tools.scrcpy;
    if (scrcpy == null) return _fail('scrcpy not found in PATH');
    setState(() {
      _error = null;
      _hwnd = null;
      _lastRect = null;
    });
    final p = await Process.start(
      scrcpy,
      [
        '-s', widget.target,
        '--window-title=$_title',
        '--window-borderless',
        // Spawn off-screen first so it doesn't flicker before embedding.
        '--window-x=-32000', '--window-y=-32000',
        '--no-audio',
        '--stay-awake',
        if (widget.maxSize != null) '--max-size=${widget.maxSize}',
      ],
      environment: {if (widget.adb.tools.adb != null) 'ADB': widget.adb.tools.adb!},
    );
    _process = p;
    p.stdout.transform(const SystemEncoding().decoder).listen(_log.write);
    p.stderr.transform(const SystemEncoding().decoder).listen(_log.write);
    p.exitCode.then((code) {
      if (!mounted || _process != p) return;
      _process = null;
      _hwnd = null;
      final reason = _log
          .toString()
          .trim()
          .split('\n')
          .lastWhere((l) => l.contains('ERROR'), orElse: () => 'scrcpy stopped (exit $code)');
      _fail(reason);
    });

    final parent = EmbedWindow.ownWindow();
    for (var i = 0; i < 100 && mounted && _process == p; i++) {
      final h = EmbedWindow.findByTitle(_title);
      if (h != 0 && parent != null) {
        EmbedWindow.adopt(h, parent);
        _hwnd = h;
        _watch(this);
        // Fallback for moves without a Flutter frame (e.g. window restored).
        _sync ??= Timer.periodic(const Duration(milliseconds: 250), (_) => _syncPosition());
        _syncPosition();
        if (mounted) setState(() {});
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (mounted && _process == p && _hwnd == null) _fail('scrcpy window did not appear');
  }

  void _fail(String reason) {
    _sync?.cancel();
    _sync = null;
    _active.remove(this);
    if (!mounted) return;
    setState(() => _error = reason);
    widget.onFailed?.call(reason);
  }

  void _syncPosition() {
    final h = _hwnd;
    if (h == null || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    // Hide when another route (dialog, popup menu) is on top, or the widget isn't visible.
    final visible = box != null && box.attached && box.hasSize && _visibleInTree;
    if (!visible) {
      if (!_hidden) EmbedWindow.hide(h);
      _hidden = true;
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final topLeft = box.localToGlobal(Offset.zero) * dpr;
    final rect = Rect.fromLTWH(topLeft.dx, topLeft.dy, box.size.width * dpr, box.size.height * dpr);
    if (rect == _lastRect && !_hidden) return;
    // Resizing makes scrcpy re-layout its frame; throttle that while a splitter is dragged.
    final resized = _lastRect != null && rect.size != _lastRect!.size;
    if (resized && !_hidden && DateTime.now().difference(_lastResize).inMilliseconds < 80) return;
    if (resized) _lastResize = DateTime.now();
    _lastRect = rect;
    _hidden = false;
    EmbedWindow.place(h, rect.left.round(), rect.top.round(), rect.width.round(), rect.height.round());
  }

  @override
  void dispose() {
    _sync?.cancel();
    _active.remove(this);
    final p = _process;
    _process = null;
    if (p != null) Process.run('taskkill', ['/T', '/F', '/PID', '${p.pid}']);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read in build so the widget rebuilds when a dialog/menu opens or the tab is hidden.
    _visibleInTree = (ModalRoute.of(context)?.isCurrent ?? true) && TickerMode.valuesOf(context).enabled;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPosition());
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: _error != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _start, child: const Text('Retry')),
                ],
              ),
            )
          : _hwnd == null
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 8),
                Text('Opening screen (scrcpy)…', style: TextStyle(color: Colors.white70)),
              ],
            )
          : const SizedBox.expand(),
    );
  }
}
