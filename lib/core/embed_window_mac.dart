import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

final _cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
final _ax = DynamicLibrary.open('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');

typedef _Ref = Pointer<Void>;

final _cfStringCreate = _cf.lookupFunction<_Ref Function(_Ref, Pointer<Utf8>, Uint32), _Ref Function(_Ref, Pointer<Utf8>, int)>('CFStringCreateWithCString');
final _cfStringGet = _cf.lookupFunction<Uint8 Function(_Ref, Pointer<Utf8>, Long, Uint32), int Function(_Ref, Pointer<Utf8>, int, int)>('CFStringGetCString');
final _cfRelease = _cf.lookupFunction<Void Function(_Ref), void Function(_Ref)>('CFRelease');
final _cfArrayCount = _cf.lookupFunction<Long Function(_Ref), int Function(_Ref)>('CFArrayGetCount');
final _cfArrayGet = _cf.lookupFunction<_Ref Function(_Ref, Long), _Ref Function(_Ref, int)>('CFArrayGetValueAtIndex');
final _cfRetain = _cf.lookupFunction<_Ref Function(_Ref), _Ref Function(_Ref)>('CFRetain');
final _true = _cf.lookup<_Ref>('kCFBooleanTrue').value;
final _false = _cf.lookup<_Ref>('kCFBooleanFalse').value;

final _isTrusted = _ax.lookupFunction<Uint8 Function(), int Function()>('AXIsProcessTrusted');
final _createApp = _ax.lookupFunction<_Ref Function(Int32), _Ref Function(int)>('AXUIElementCreateApplication');
final _createSystemWide = _ax.lookupFunction<_Ref Function(), _Ref Function()>('AXUIElementCreateSystemWide');
final _copyAttr = _ax.lookupFunction<Int32 Function(_Ref, _Ref, Pointer<_Ref>), int Function(_Ref, _Ref, Pointer<_Ref>)>('AXUIElementCopyAttributeValue');
final _setAttr = _ax.lookupFunction<Int32 Function(_Ref, _Ref, _Ref), int Function(_Ref, _Ref, _Ref)>('AXUIElementSetAttributeValue');
final _getPid = _ax.lookupFunction<Int32 Function(_Ref, Pointer<Int32>), int Function(_Ref, Pointer<Int32>)>('AXUIElementGetPid');
final _valueCreate = _ax.lookupFunction<_Ref Function(Uint32, Pointer<Void>), _Ref Function(int, Pointer<Void>)>('AXValueCreate');

const _utf8 = 0x08000100;
const _axPoint = 1;

_Ref _string(String s) {
  final c = s.toNativeUtf8();
  try {
    return _cfStringCreate(nullptr, c, _utf8);
  } finally {
    calloc.free(c);
  }
}

final _attrs = <String, _Ref>{};
_Ref _attr(String name) => _attrs[name] ??= _string(name);

String? _dartString(_Ref s) {
  final buffer = calloc<Uint8>(1024).cast<Utf8>();
  try {
    return _cfStringGet(s, buffer, 1024, _utf8) == 0 ? null : buffer.toDartString();
  } finally {
    calloc.free(buffer);
  }
}

_Ref? _copy(_Ref element, String name) {
  final out = calloc<_Ref>();
  try {
    return _copyAttr(element, _attr(name), out) == 0 ? out.value : null;
  } finally {
    calloc.free(out);
  }
}

/// macOS can't own another process's window, so scrcpy floats above this one and the Accessibility
/// API keeps it over its area. That API can't be called on our own window from the main thread
/// without hanging, so our position comes from window_manager, polled into [_origin].
class MacEmbed {
  static (int, int)? _origin;
  static var _minimized = false;
  static Timer? _poll;
  static final _pids = <int, int>{};
  static final _apps = <int, _Ref>{};
  static final _hidden = <int>{};

  static bool get trusted => _isTrusted() != 0;

  static Future<void> openPermissionSettings() =>
      Process.run('open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility']);

  static void _startPolling() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 30), (_) async {
      try {
        final bounds = await windowManager.getBounds();
        // A workspace window keeps its native title bar, so its content starts below the frame's top.
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final titleBar = bounds.height - view.physicalSize.height / view.devicePixelRatio;
        _origin = (bounds.left.round(), (bounds.top + titleBar).round());
        _minimized = await windowManager.isMinimized();
      } catch (_) {
        // The next tick asks again.
      }
    });
  }

  /// Non-null once our position is known; the value only says there's a window to follow.
  static int? ownWindow() {
    _startPolling();
    return _origin == null ? null : pid;
  }

  static (int, int) clientOrigin() => _origin ?? (0, 0);

  static int findByTitle(String title, int processId) {
    final app = _appOf(processId);
    final windows = _copy(app, 'AXWindows');
    if (windows == null) return 0;
    try {
      for (var i = 0; i < _cfArrayCount(windows); i++) {
        final window = _cfArrayGet(windows, i);
        final name = _copy(window, 'AXTitle');
        if (name == null) continue;
        final matches = _dartString(name) == title;
        _cfRelease(name);
        if (matches) {
          final handle = _cfRetain(window).address;
          _pids[handle] = processId;
          return handle;
        }
      }
      return 0;
    } finally {
      _cfRelease(windows);
    }
  }

  static _Ref _appOf(int processId) => _apps[processId] ??= _createApp(processId);

  static var _frontCheck = DateTime(0);
  static var _frontAllowed = true;

  /// Whether we or one of our screens is the app in front: the screen floats, so it has to get out
  /// of the way of other apps by itself.
  static bool inFront() {
    final now = DateTime.now();
    if (now.difference(_frontCheck).inMilliseconds < 150) return _frontAllowed;
    _frontCheck = now;
    final system = _createSystemWide();
    final app = _copy(system, 'AXFocusedApplication');
    _cfRelease(system);
    if (app == null) return _frontAllowed = true;
    final out = calloc<Int32>();
    try {
      if (_getPid(app, out) != 0) return _frontAllowed = true;
      return _frontAllowed = out.value == pid || _pids.containsValue(out.value);
    } finally {
      calloc.free(out);
      _cfRelease(app);
    }
  }

  static bool isMinimized() => _minimized || !inFront();

  static void move(int handle, int x, int y) {
    final processId = _pids[handle];
    if (processId != null && _hidden.remove(processId)) _setAttr(_appOf(processId), _attr('AXHidden'), _false);
    final point = calloc<Double>(2);
    point[0] = x.toDouble();
    point[1] = y.toDouble();
    final value = _valueCreate(_axPoint, point.cast());
    _setAttr(Pointer.fromAddress(handle), _attr('AXPosition'), value);
    _cfRelease(value);
    calloc.free(point);
  }

  static void hide(int handle) {
    final processId = _pids[handle];
    if (processId == null || !_hidden.add(processId)) return;
    _setAttr(_appOf(processId), _attr('AXHidden'), _true);
  }

  static bool isWindow(int handle) {
    final role = _copy(Pointer.fromAddress(handle), 'AXRole');
    if (role == null) return false;
    _cfRelease(role);
    return true;
  }
}
