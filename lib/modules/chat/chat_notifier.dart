import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:local_notifier/local_notifier.dart';

import '../../core/embed_window.dart';
import 'chat_service.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _flashWindowEx = _user32.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
  'FlashWindowEx',
);

/// Windows toast + taskbar flash for incoming chat messages.
class ChatNotifier {
  static var _ready = false;

  static Future<void> setup() async {
    try {
      await localNotifier.setup(appName: 'DevKit');
      _ready = true;
    } catch (_) {
      // Toasts are optional; badge and taskbar flash still work.
    }
  }

  static Future<void> show(ChatMessage m, {required void Function() onOpen}) async {
    flashTaskbar();
    if (!_ready) return;
    final n = LocalNotification(
      title: m.to == everyone ? '${m.fromName} → Everyone' : m.fromName,
      body: m.text.length > 180 ? '${m.text.substring(0, 180)}…' : m.text,
    )..onClick = onOpen;
    await n.show();
  }

  /// Flashes the taskbar button until the window is focused (FLASHW_ALL | FLASHW_TIMERNOFG).
  static void flashTaskbar() {
    final hwnd = EmbedWindow.ownWindow();
    if (hwnd == null) return;
    const size = 32; // sizeof(FLASHWINFO) on x64
    final info = calloc<Uint8>(size);
    try {
      info.cast<Uint32>().value = size;
      (info + 8).cast<IntPtr>().value = hwnd;
      (info + 16).cast<Uint32>().value = 0x3 | 0xC;
      (info + 20).cast<Uint32>().value = 0;
      (info + 24).cast<Uint32>().value = 0;
      _flashWindowEx(info);
    } finally {
      calloc.free(info);
    }
  }
}
