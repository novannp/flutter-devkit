import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/child_processes.dart';
import '../../../../core/embed_window.dart';
import '../../services/adb_service.dart';

var _counter = 0;

// One persistent frame callback for all embeds: follows layout on frames that happen anyway, never forces new ones.
final _active = <_EmbeddedScrcpyState>{};
var _frameHooked = false;

/// Global rects (logical px) of Flutter overlays that must show above the native screen.
var _overlays = <Rect>[];
const _overlayWidgets = {'_TooltipBox', 'SnackBar'};

List<Rect> _findOverlays() {
  final found = <Rect>[];
  void visit(Element e) {
    if (_overlayWidgets.contains(e.widget.runtimeType.toString())) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.attached && ro.hasSize) found.add(ro.localToGlobal(Offset.zero) & ro.size);
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

void _watch(_EmbeddedScrcpyState s) {
  _active.add(s);
  if (_frameHooked) return;
  _frameHooked = true;
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (_active.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _overlays = _findOverlays();
      for (final e in _active.toList()) {
        e._sync();
      }
    });
  });
}

/// scrcpy's window kept exactly over this widget's area: smooth 60 fps, still inside DevKit.
///
/// scrcpy only scales its picture to the size it was created with, so it's started at the exact
/// area and restarted when that size changes; moves just reposition the window.
/// The native window sits above Flutter widgets, so it's hidden while a dialog/menu is open.
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
  String _title = '';
  Process? _process;
  int? _hwnd;
  int? _owner;
  Timer? _poll;
  Timer? _restart;

  /// Screen rect (physical px) scrcpy was started with, and where its window currently is.
  Rect? _spawned;
  Offset? _placedAt;
  var _starting = false;
  var _hidden = false;
  var _visibleInTree = true;
  String? _error;
  final _log = StringBuffer();

  @override
  void initState() {
    super.initState();
    _owner = EmbedWindow.ownWindow();
    _watch(this);
    // Window moves don't produce Flutter frames; poll the (cheap) client origin to follow them.
    _poll = Timer.periodic(const Duration(milliseconds: 30), (_) => _sync());
  }

  /// Where the widget is on screen, in physical pixels; null while hidden or not laid out.
  Rect? _screenRect() {
    final owner = _owner;
    if (owner == null || !mounted || !_visibleInTree || EmbedWindow.isMinimized(owner)) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize || box.size.isEmpty) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final (ox, oy) = EmbedWindow.clientOrigin(owner);
    final tl = box.localToGlobal(Offset.zero) * dpr + Offset(ox.toDouble(), oy.toDouble());
    return Rect.fromLTWH(
      tl.dx.roundToDouble(),
      tl.dy.roundToDouble(),
      (box.size.width * dpr).roundToDouble(),
      (box.size.height * dpr).roundToDouble(),
    );
  }

  void _sync() {
    if (!mounted || _error != null) return;
    final rect = _screenRect();
    final h = _hwnd;
    if (rect == null) {
      if (h != null && !_hidden) EmbedWindow.hide(h);
      _hidden = true;
      return;
    }
    if (_process == null && !_starting) {
      _start(rect);
      return;
    }
    final spawned = _spawned;
    if (h == null || spawned == null) return;
    final sizeChanged = (rect.width - spawned.width).abs() > 2 || (rect.height - spawned.height).abs() > 2;
    if (sizeChanged) {
      // Hide the stale-size picture and restart once resizing settles.
      if (!_hidden) EmbedWindow.hide(h);
      _hidden = true;
      if (!(_restart?.isActive ?? false) || _pendingSize != rect.size) {
        _pendingSize = rect.size;
        _restart?.cancel();
        _restart = Timer(const Duration(milliseconds: 500), _relaunch);
      }
      return;
    }
    if (_hidden || rect.topLeft != _placedAt) {
      EmbedWindow.move(h, rect.left.toInt(), rect.top.toInt());
      _placedAt = rect.topLeft;
      _hidden = false;
    }
    _applyHoles(h, rect);
  }

  String _holesKey = '';
  var _holesUnsupported = false;
  var _hiddenForOverlay = false;

  /// Tooltips/snackbars over the screen: cut them out of the scrcpy window so they stay readable.
  void _applyHoles(int h, Rect rect) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final (ox, oy) = EmbedWindow.clientOrigin(_owner!);
    final holes = <(int, int, int, int)>[];
    for (final o in _overlays) {
      final local = Rect.fromLTRB(
        o.left * dpr + ox - rect.left,
        o.top * dpr + oy - rect.top,
        o.right * dpr + ox - rect.left,
        o.bottom * dpr + oy - rect.top,
      ).inflate(2).intersect(Offset.zero & rect.size);
      if (local.width > 0 && local.height > 0) {
        holes.add((local.left.floor(), local.top.floor(), local.right.ceil(), local.bottom.ceil()));
      }
    }
    final key = holes.join();
    if (key == _holesKey) return;
    _holesKey = key;
    if (_holesUnsupported) {
      // Fallback: get out of the way while an overlay is shown.
      if (holes.isNotEmpty && !_hiddenForOverlay) {
        EmbedWindow.hide(h);
        _hiddenForOverlay = true;
      } else if (holes.isEmpty && _hiddenForOverlay) {
        _hiddenForOverlay = false;
        EmbedWindow.move(h, rect.left.toInt(), rect.top.toInt());
      }
      return;
    }
    if (!EmbedWindow.setHoles(h, rect.width.toInt(), rect.height.toInt(), holes)) {
      _holesUnsupported = true;
      _holesKey = '';
      _applyHoles(h, rect);
    }
  }

  Size? _pendingSize;

  void _relaunch() {
    _kill();
    if (mounted) setState(() {});
    _sync();
  }

  Future<void> _start(Rect rect) async {
    final scrcpy = widget.adb.tools.scrcpy;
    if (scrcpy == null) return _fail('scrcpy not found');
    _starting = true;
    _title = 'devkit-embed-$pid-${_counter++}';
    setState(() => _hwnd = null);
    final Process p;
    try {
      p = await Process.start(
        scrcpy,
        [
          '-s',
          widget.target,
          '--window-title=$_title',
          '--window-borderless',
          '--window-x=${rect.left.toInt()}',
          '--window-y=${rect.top.toInt()}',
          '--window-width=${rect.width.toInt()}',
          '--window-height=${rect.height.toInt()}',
          '--no-audio',
          '--stay-awake',
          if (widget.maxSize != null) '--max-size=${widget.maxSize}',
        ],
        environment: {if (widget.adb.tools.adb != null) 'ADB': widget.adb.tools.adb!},
      );
    } catch (e) {
      _starting = false;
      return _fail('$e');
    }
    _process = p;
    _spawned = rect;
    _placedAt = rect.topLeft;
    ChildProcesses.bind(p);
    p.stdout.transform(const SystemEncoding().decoder).listen(_log.write);
    p.stderr.transform(const SystemEncoding().decoder).listen(_log.write);
    p.exitCode.then((code) {
      if (!mounted || _process != p) return;
      final reason = _log
          .toString()
          .trim()
          .split('\n')
          .lastWhere((l) => l.contains('ERROR'), orElse: () => 'scrcpy stopped (exit $code)');
      _fail(reason);
    });

    final owner = _owner;
    for (var i = 0; i < 100 && mounted && _process == p; i++) {
      final h = EmbedWindow.findByTitle(_title);
      if (h != 0 && owner != null) {
        EmbedWindow.adopt(h, owner);
        _hwnd = h;
        _hidden = false;
        _starting = false;
        if (mounted) setState(() {});
        _sync();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _starting = false;
    if (mounted && _process == p && _hwnd == null) _fail('scrcpy window did not appear');
  }

  void _kill() {
    // Hide right away; taskkill is async and the window would otherwise linger as a ghost.
    if (_hwnd case final h? when EmbedWindow.isWindow(h)) EmbedWindow.hide(h);
    _hwnd = null;
    _spawned = null;
    _starting = false;
    _holesKey = '';
    _hiddenForOverlay = false;
    final p = _process;
    _process = null;
    if (p != null) Process.run('taskkill', ['/T', '/F', '/PID', '${p.pid}']);
  }

  void _fail(String reason) {
    _kill();
    if (!mounted) return;
    setState(() => _error = reason);
    widget.onFailed?.call(reason);
  }

  void _retry() {
    setState(() => _error = null);
    _sync();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _restart?.cancel();
    _active.remove(this);
    _kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read in build so the widget rebuilds when a dialog/menu opens or the tab is hidden.
    _visibleInTree = (ModalRoute.of(context)?.isCurrent ?? true) && TickerMode.valuesOf(context).enabled;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
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
                  OutlinedButton(onPressed: _retry, child: const Text('Retry')),
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
