import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Minimal user32 bindings; deliberately not using package:win32 since its API changes often between versions.
final _user32 = DynamicLibrary.open('user32.dll');

final _findWindowEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _getWindowLongPtr =
    _user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
final _setWindowLongPtr =
    _user32.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>('SetWindowLongPtrW');
final _setParent = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('SetParent');
final _setWindowPos = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');
final _showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final _isWindow = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

const _gwlStyle = -16;
const _gwlExStyle = -20;
const _wsChild = 0x40000000;
const _wsVisible = 0x10000000;
const _wsPopup = 0x80000000;
const _wsCaption = 0x00C00000;
const _wsThickFrame = 0x00040000;
const _wsSysMenu = 0x00080000;
const _wsMinMaxBox = 0x00030000;
const _wsExAppWindow = 0x00040000;
const _swpNoActivate = 0x0010;
const _swpShowWindow = 0x0040;
const _swpFrameChanged = 0x0020;
const _swHide = 0;

/// Embeds another process's window (scrcpy) inside this Flutter window.
class EmbedWindow {
  static int? _own;

  static bool get supported => Platform.isWindows;

  /// HWND of this process's Flutter runner window.
  static int? ownWindow() {
    if (_own != null) return _own;
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final procId = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = _findWindowEx(0, h, cls, nullptr);
        if (h == 0) return null;
        _getWindowThreadProcessId(h, procId);
        if (procId.value == pid) return _own = h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(procId);
    }
  }

  static int findByTitle(String title) {
    final t = title.toNativeUtf16();
    try {
      return _findWindowEx(0, 0, nullptr, t);
    } finally {
      calloc.free(t);
    }
  }

  static void adopt(int child, int parent) {
    var style = _getWindowLongPtr(child, _gwlStyle);
    style &= ~(_wsPopup | _wsCaption | _wsThickFrame | _wsSysMenu | _wsMinMaxBox);
    style |= _wsChild | _wsVisible;
    _setWindowLongPtr(child, _gwlStyle, style);
    _setWindowLongPtr(child, _gwlExStyle, _getWindowLongPtr(child, _gwlExStyle) & ~_wsExAppWindow);
    _setParent(child, parent);
  }

  /// Physical pixel coordinates, relative to the parent window's client area.
  static void place(int child, int x, int y, int w, int h) =>
      _setWindowPos(child, 0, x, y, w, h, _swpNoActivate | _swpShowWindow | _swpFrameChanged);

  static void hide(int child) => _showWindow(child, _swHide);

  static bool isWindow(int h) => _isWindow(h) != 0;
}
