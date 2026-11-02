import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'embed_window_mac.dart';

// Minimal user32 bindings; deliberately not using package:win32 since its API changes often between versions.
final _user32 = DynamicLibrary.open('user32.dll');

final _findWindowEx = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
      'GetWindowThreadProcessId',
    );
final _getWindowLongPtr = _user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
  'GetWindowLongPtrW',
);
final _setWindowLongPtr = _user32.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>(
  'SetWindowLongPtrW',
);
final _setWindowPos = _user32
    .lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)
    >('SetWindowPos');
final _showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final _isWindow = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
final _isIconic = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final _clientToScreen = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('ClientToScreen');

final _gdi32 = DynamicLibrary.open('gdi32.dll');
final _createRectRgn = _gdi32
    .lookupFunction<IntPtr Function(Int32, Int32, Int32, Int32), int Function(int, int, int, int)>('CreateRectRgn');
final _combineRgn = _gdi32
    .lookupFunction<Int32 Function(IntPtr, IntPtr, IntPtr, Int32), int Function(int, int, int, int)>('CombineRgn');
final _deleteObject = _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
final _setWindowRgn = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32), int Function(int, int, int)>(
  'SetWindowRgn',
);

const _gwlStyle = -16;
const _gwlExStyle = -20;
const _gwlpHwndParent = -8;
const _wsPopup = 0x80000000;
const _wsChild = 0x40000000;
const _wsCaption = 0x00C00000;
const _wsThickFrame = 0x00040000;
const _wsSysMenu = 0x00080000;
const _wsMinMaxBox = 0x00030000;
const _wsExAppWindow = 0x00040000;
const _wsExToolWindow = 0x00000080;
const _swpNoActivate = 0x0010;
const _swpShowWindow = 0x0040;
const _swpFrameChanged = 0x0020;
const _swpNoZOrder = 0x0004;
const _swpNoSize = 0x0001;
const _swpNoMove = 0x0002;
const _swHide = 0;

/// Shows another process's window (scrcpy) over an area of this Flutter window.
///
/// It's an owned popup rather than a child window: cross-process GPU child windows ghost and
/// resize badly next to Flutter's own surface. An owned window still minimizes, hides and stacks
/// with DevKit, but composes on its own.
class EmbedWindow {
  static int? _own;

  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// Whether this app may place another app's window; on macOS the user grants that once.
  static bool get allowed => !Platform.isMacOS || MacEmbed.trusted;

  static Future<void> askPermission() => MacEmbed.openPermissionSettings();

  /// Screen coordinates per logical pixel: macOS positions windows in points, Windows in pixels.
  static double scale(double devicePixelRatio) => Platform.isMacOS ? 1 : devicePixelRatio;

  /// HWND of this process's Flutter runner window.
  static int? ownWindow() {
    if (Platform.isMacOS) return MacEmbed.ownWindow();
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

  static int findByTitle(String title, {required int processId}) {
    if (Platform.isMacOS) return MacEmbed.findByTitle(title, processId);
    final t = title.toNativeUtf16();
    try {
      return _findWindowEx(0, 0, nullptr, t);
    } finally {
      calloc.free(t);
    }
  }

  static void adopt(int child, int owner) {
    if (Platform.isMacOS) return;
    var style = _getWindowLongPtr(child, _gwlStyle);
    style &= ~(_wsChild | _wsCaption | _wsThickFrame | _wsSysMenu | _wsMinMaxBox);
    style |= _wsPopup;
    _setWindowLongPtr(child, _gwlStyle, style);
    // Tool window: no taskbar button / Alt+Tab entry of its own.
    final ex = (_getWindowLongPtr(child, _gwlExStyle) & ~_wsExAppWindow) | _wsExToolWindow;
    _setWindowLongPtr(child, _gwlExStyle, ex);
    _setWindowLongPtr(child, _gwlpHwndParent, owner);
    _setWindowPos(child, 0, 0, 0, 0, 0, _swpNoActivate | _swpFrameChanged | _swpNoSize | _swpNoMove | _swpNoZOrder);
  }

  /// Screen position of the owner's client area (physical pixels), to follow window moves.
  static (int, int) clientOrigin(int owner) {
    if (Platform.isMacOS) return MacEmbed.clientOrigin();
    final pt = calloc<Int32>(2);
    try {
      _clientToScreen(owner, pt);
      return (pt[0], pt[1]);
    } finally {
      calloc.free(pt);
    }
  }

  static bool isMinimized(int h) => Platform.isMacOS ? MacEmbed.isMinimized() : _isIconic(h) != 0;

  /// Moves (never resizes — scrcpy keeps its creation size) to screen coordinates in physical pixels.
  static void move(int child, int x, int y) => Platform.isMacOS
      ? MacEmbed.move(child, x, y)
      : _setWindowPos(child, 0, x, y, 0, 0, _swpNoActivate | _swpShowWindow | _swpNoZOrder | _swpNoSize);

  /// Cuts [holes] (window-local physical px) out of the window so Flutter overlays under it show through.
  /// Empty [holes] restores the full window. Returns false if Windows refused.
  static bool setHoles(int child, int width, int height, List<(int, int, int, int)> holes) {
    if (Platform.isMacOS) return holes.isEmpty;
    if (holes.isEmpty) return _setWindowRgn(child, 0, 1) != 0;
    final rgn = _createRectRgn(0, 0, width, height);
    for (final (l, t, r, b) in holes) {
      final hole = _createRectRgn(l, t, r, b);
      _combineRgn(rgn, rgn, hole, 4); // RGN_DIFF
      _deleteObject(hole);
    }
    // On success the system owns the region; only free it if the call failed.
    final ok = _setWindowRgn(child, rgn, 1) != 0;
    if (!ok) _deleteObject(rgn);
    return ok;
  }

  static void hide(int child) => Platform.isMacOS ? MacEmbed.hide(child) : _showWindow(child, _swHide);

  static bool isWindow(int h) => Platform.isMacOS ? MacEmbed.isWindow(h) : _isWindow(h) != 0;
}
