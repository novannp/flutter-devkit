import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Files dragged onto the window and PDF pages, which only the runner can do.
/// The other side is windows/runner/native_bridge.cpp and macos/Runner/MainFlutterWindow.swift.
class NativeBridge {
  static const _channel = MethodChannel('hotrestart/native');

  static final _areas = <_FileDropAreaState>{};
  static var _listening = false;

  /// One page as a PNG, drawn by the operating system's own PDF engine.
  static Future<({int pages, Uint8List png})> renderPdf(String path, int page, int width) async {
    final out = (await _channel.invokeMapMethod<String, Object?>('renderPdf', {'path': path, 'page': page, 'width': width}))!;
    return (pages: out['pages']! as int, png: out['png']! as Uint8List);
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
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
