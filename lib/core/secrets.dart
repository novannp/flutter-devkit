import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

// Tokens are encrypted with Windows DPAPI, so only this Windows user on this PC can read them.
final class _Blob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> data;
}

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _CryptNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _CryptDart = int Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);

final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _unprotect = _crypt32
    .lookupFunction<
      Int32 Function(
        Pointer<_Blob>,
        Pointer<Pointer<Utf16>>,
        Pointer<_Blob>,
        Pointer<Void>,
        Pointer<Void>,
        Uint32,
        Pointer<_Blob>,
      ),
      int Function(
        Pointer<_Blob>,
        Pointer<Pointer<Utf16>>,
        Pointer<_Blob>,
        Pointer<Void>,
        Pointer<Void>,
        int,
        Pointer<_Blob>,
      )
    >('CryptUnprotectData');
final _localFree = _kernel32.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('LocalFree');

List<int>? dpapi(List<int> input, {required bool encrypt}) {
  return using((arena) {
    final inBlob = arena<_Blob>();
    final outBlob = arena<_Blob>();
    final buf = arena<Uint8>(input.length);
    buf.asTypedList(input.length).setAll(0, input);
    inBlob.ref
      ..size = input.length
      ..data = buf;
    const uiForbidden = 0x1;
    final ok = encrypt
        ? _protect(inBlob, nullptr, nullptr, nullptr, nullptr, uiForbidden, outBlob)
        : _unprotect(inBlob, nullptr, nullptr, nullptr, nullptr, uiForbidden, outBlob);
    if (ok == 0) return null;
    final out = List<int>.of(outBlob.ref.data.asTypedList(outBlob.ref.size));
    _localFree(outBlob.ref.data.cast());
    return out;
  });
}

/// macOS: the login Keychain. Fed through stdin so the token never shows in a process listing.
class _Keychain {
  static const _service = 'Flutter DevKit';

  static Future<String?> read(String name) async {
    final r = await Process.run('security', ['find-generic-password', '-a', name, '-s', _service, '-w']);
    return r.exitCode == 0 ? (r.stdout as String).trimRight() : null;
  }

  static Future<void> write(String name, String? value) async {
    if (value == null || value.isEmpty) {
      await Process.run('security', ['delete-generic-password', '-a', name, '-s', _service]);
      return;
    }
    final quoted = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final p = await Process.start('security', ['-i']);
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    p.stdin.writeln('add-generic-password -U -a "$name" -s "$_service" -w "$quoted"');
    await p.stdin.close();
    await p.exitCode;
    if (await read(name) != value) throw StateError('The Keychain could not save the token');
  }
}

class Secrets {
  static Future<File> _file(String name) async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$name.secret');

  static Future<String?> read(String name) async {
    if (Platform.isMacOS) return _Keychain.read(name);
    try {
      final f = await _file(name);
      if (!f.existsSync()) return null;
      final plain = dpapi(await f.readAsBytes(), encrypt: false);
      return plain == null ? null : utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String name, String? value) async {
    if (Platform.isMacOS) return _Keychain.write(name, value);
    final f = await _file(name);
    if (value == null || value.isEmpty) {
      if (f.existsSync()) await f.delete();
      return;
    }
    final enc = dpapi(utf8.encode(value), encrypt: true);
    if (enc == null) throw StateError('Windows could not encrypt the token');
    await f.writeAsBytes(enc);
  }
}
