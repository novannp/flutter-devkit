import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'tools.dart';

final _libc = DynamicLibrary.process();
final _setenv = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
final _getenv = _libc.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('getenv');

const _marker = '__DEVKIT_PATH__';

String? _env(String name) {
  final key = name.toNativeUtf8();
  try {
    final value = _getenv(key);
    return value == nullptr ? null : value.toDartString();
  } finally {
    calloc.free(key);
  }
}

/// The PATH printed after [_marker], which sits past whatever a shell's startup files print.
String? pathFromShellOutput(String output) {
  final at = output.lastIndexOf(_marker);
  if (at < 0) return null;
  final path = output.substring(at + _marker.length).split('\n').first.trim();
  return path.isEmpty ? null : path;
}

/// An app opened from Finder gets a bare PATH, without flutter, git or adb, so it takes the one from
/// the login shell. Runs first thing: Dart caches Platform.environment the first time it's read.
Future<void> adoptLoginShellPath() async {
  if (!Platform.isMacOS) return;
  final shell = _env('SHELL') ?? '/bin/zsh';
  final home = _env('HOME') ?? '';
  String? path;
  try {
    final r = await Tools.run(shell, ['-ilc', 'printf "\\n$_marker%s\\n" "\$PATH"'], timeout: const Duration(seconds: 5));
    path = pathFromShellOutput(r.stdout);
  } catch (_) {
    // A broken shell config shouldn't stop the app; the folders below still help.
  }
  final parts = {
    ...(path ?? _env('PATH') ?? '').split(':').where((s) => s.isNotEmpty),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '$home/fvm/default/bin',
    '$home/.pub-cache/bin',
  };
  final key = 'PATH'.toNativeUtf8();
  final value = parts.join(':').toNativeUtf8();
  _setenv(key, value, 1);
  calloc.free(key);
  calloc.free(value);
}
