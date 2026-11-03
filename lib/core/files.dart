import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<Directory> outputDir() async {
  final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  return Directory('${base.path}${Platform.pathSeparator}HotRestart').create(recursive: true);
}

String timestamp() => DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);

String safeFileName(String s) => s.replaceAll(RegExp(r'[^\w\-]+'), '_');

/// A file, folder or URL, in whatever the system opens it with.
Future<void> openExternal(String target) async {
  await Process.run(Platform.isMacOS ? 'open' : 'explorer', [target]);
}

Future<void> revealInExplorer(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  }
}
