import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:hotrestart/extensions/maintenance/core_deps.dart';

const _pubspec = '''
name: my_app
dependencies:
  provider: ^6.0.1
  shared_plugin:
#    path: ../shared_plugin
     git:
       url: git@git.example.com:team/shared_plugin.git
       ref: fix/magtek-debit-surcharge
  # Shared domain layer.
  shared_core:
    git:
      url: git@git.example.com:team/shared-core.git
  qr: ^3.0.2
''';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('core_deps');
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(_pubspec);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('finds the git packages, through odd indentation', () async {
    expect(await CoreDeps.gitPackages(dir.path), ['shared_plugin', 'shared_core']);
    final deps = await CoreDeps.read(dir.path, ['shared_plugin', 'shared_core']);
    expect(deps[0].url, 'git@git.example.com:team/shared_plugin.git');
    expect(deps.map((d) => d.repo), ['shared_plugin', 'shared-core']);
  });
}
