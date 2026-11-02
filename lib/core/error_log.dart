import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

File? errorLogFile;

/// Keeps uncaught errors with their stack traces in a file, where a bug report can find them.
Future<void> installErrorLog() async {
  try {
    final file = File(p.join((await getApplicationSupportDirectory()).path, 'errors.log'));
    if (file.existsSync() && file.lengthSync() > 1 << 20) file.deleteSync();
    errorLogFile = file;
  } on FileSystemException {
    return;
  }
  final present = FlutterError.onError;
  FlutterError.onError = (details) {
    present?.call(details);
    _write(details.exception, details.stack, details.context?.toString());
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _write(error, stack, null);
    return false;
  };
}

void _write(Object error, StackTrace? stack, String? context) {
  try {
    errorLogFile?.writeAsStringSync('--- ${DateTime.now()}${context == null ? '' : ' $context'}\n$error\n$stack\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Logging must never become a second error.
  }
}
