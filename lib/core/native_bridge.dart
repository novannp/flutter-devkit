import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the runner does natively: system notifications, and files dragged onto the window.
/// The other side is windows/runner/native_bridge.cpp and macos/Runner/MainFlutterWindow.swift.
class NativeBridge {
  static const _channel = MethodChannel('devkit/native');

  static final _clicks = <int, VoidCallback>{};
  static final _areas = <_FileDropAreaState>{};
  static var _nextId = 0;
  static var _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'notificationClicked':
          _clicks.remove(call.arguments as int)?.call();
        case 'dragEntered':
          for (final a in _areas.toList()) {
            a.widget.onEnter?.call();
          }
        case 'dragExited':
          for (final a in _areas.toList()) {
            a.widget.onExit?.call();
          }
        case 'dropped':
          final paths = (call.arguments as List).cast<String>();
          for (final a in _areas.toList()) {
            a.widget.onDrop(paths);
          }
      }
    });
  }

  /// Toasts are optional, so failing to show one isn't an error for the caller.
  static Future<void> notify({required String title, required String body, VoidCallback? onClick}) async {
    _listen();
    final id = _nextId++;
    if (onClick != null) {
      _clicks[id] = onClick;
      // Only the newest few can still be on screen.
      if (_clicks.length > 50) _clicks.remove(_clicks.keys.first);
    }
    try {
      await _channel.invokeMethod<void>('notify', {'id': id, 'title': title, 'body': body});
    } on PlatformException {
      _clicks.remove(id);
    } on MissingPluginException {
      _clicks.remove(id);
    }
  }
}

/// Receives files dragged from the system anywhere onto the window.
class FileDropArea extends StatefulWidget {
  const FileDropArea({super.key, required this.child, required this.onDrop, this.onEnter, this.onExit});

  final Widget child;
  final ValueChanged<List<String>> onDrop;
  final VoidCallback? onEnter, onExit;

  @override
  State<FileDropArea> createState() => _FileDropAreaState();
}

class _FileDropAreaState extends State<FileDropArea> {
  @override
  void initState() {
    super.initState();
    NativeBridge._listen();
    NativeBridge._areas.add(this);
  }

  @override
  void dispose() {
    NativeBridge._areas.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
