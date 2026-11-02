import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/embed_window.dart';
import '../../core/native_bridge.dart';
import 'chat_service.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _flashWindowEx = _user32.lookupFunction<Int32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>(
  'FlashWindowEx',
);

/// [NSApp requestUserAttention:NSInformationalRequest], through the Objective-C runtime.
void _bounceDock() {
  final objc = DynamicLibrary.process();
  final getClass = objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('objc_getClass');
  final selector = objc.lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>('sel_registerName');
  final send = objc.lookup<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>>('objc_msgSend').asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>();
  final sendLong = objc.lookup<NativeFunction<Long Function(Pointer<Void>, Pointer<Void>, UnsignedLong)>>('objc_msgSend').asFunction<int Function(Pointer<Void>, Pointer<Void>, int)>();
  final names = ['NSApplication'.toNativeUtf8(), 'sharedApplication'.toNativeUtf8(), 'requestUserAttention:'.toNativeUtf8()];
  final app = send(getClass(names[0]), selector(names[1]));
  sendLong(app, selector(names[2]), 10);
  names.forEach(calloc.free);
}

/// Toast + taskbar flash (a Dock bounce on macOS) for incoming chat messages.
class ChatNotifier {
  static Future<void> show(ChatMessage m, {required void Function() onOpen}) async {
    flashTaskbar();
    await NativeBridge.notify(
      title: m.to == everyone ? '${m.fromName} → Everyone' : m.fromName,
      body: m.text.length > 180 ? '${m.text.substring(0, 180)}…' : m.text,
      onClick: onOpen,
    );
  }

  /// Flashes the taskbar button until the window is focused (FLASHW_ALL | FLASHW_TIMERNOFG).
  static void flashTaskbar() {
    if (Platform.isMacOS) return _bounceDock();
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
