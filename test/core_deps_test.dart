import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:devkit/modules/maintenance/core_deps.dart';

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

  test('reads refs from odd indentation and missing ref', () async {
    final deps = await CoreDeps.read(dir.path, ['shared_plugin', 'shared_core']);
    expect(deps[0].ref, 'fix/magtek-debit-surcharge');
    expect(deps[0].url, 'git@git.example.com:team/shared_plugin.git');
    expect(deps[1].ref, isNull);
  });

  test('setRef replaces or inserts ref without touching other lines', () async {
    await CoreDeps.setRef(dir.path, 'shared_plugin', 'develop');
    await CoreDeps.setRef(dir.path, 'shared_core', 'feature/x');
    final text = File(p.join(dir.path, 'pubspec.yaml')).readAsStringSync();
    expect(text, contains('       ref: develop'));
    expect(text, contains('      url: git@git.example.com:team/shared-core.git\n      ref: feature/x'));
    expect(text, contains('#    path: ../shared_plugin'));
    expect(text, contains('  qr: ^3.0.2'));
  });

  test('local override round-trip', () async {
    final local = Directory(p.join(dir.parent.path, 'shared-core'));
    await CoreDeps.setLocal(dir.path, 'shared_core', local.path);
    final overrides = File(p.join(dir.path, 'pubspec_overrides.yaml'));
    expect(overrides.readAsStringSync(), 'dependency_overrides:\n  shared_core:\n    path: ../shared-core\n');
    expect((await CoreDeps.read(dir.path, ['shared_core'])).single.localPath, p.normalize(local.path));

    await CoreDeps.setLocal(dir.path, 'shared_core', null);
    expect(overrides.existsSync(), isFalse);
  });

  test('lists every local override and reads package names', () async {
    await CoreDeps.setLocal(dir.path, 'shared_core', p.join(dir.parent.path, 'shared-core'));
    await CoreDeps.setLocal(dir.path, 'qr', p.join(dir.parent.path, 'qr-fork'));
    final all = await CoreDeps.localOverrides(dir.path);
    expect(all.keys, unorderedEquals(['shared_core', 'qr']));
    expect(all['qr'], p.normalize(p.join(dir.parent.path, 'qr-fork')));
    expect(await CoreDeps.packageName(dir.path), 'my_app');
    expect(await CoreDeps.isDirect(dir.path, 'qr'), isTrue);
    expect(await CoreDeps.isDirect(dir.path, 'collection'), isFalse);
  });

  test('toSsh converts token https URLs', () {
    expect(
      CoreDeps.toSsh('https://__USERNAME__:__TOKEN__@git.example.com/team/shared_plugin.git'),
      'git@git.example.com:team/shared_plugin.git',
    );
    expect(
      CoreDeps.toSsh('https://git.example.com/team/shared-core'),
      'git@git.example.com:team/shared-core.git',
    );
  });
}
