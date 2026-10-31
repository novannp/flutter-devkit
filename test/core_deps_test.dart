import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ravo_devkit/modules/maintenance/core_deps.dart';

const _pubspec = '''
name: zotapos
dependencies:
  provider: ^6.0.1
  pf_processor_plugin:
#    path: ../pf_processor_plugin
     git:
       url: git@bitbucket.org:payfirst101/pf_processor_plugin.git
       ref: fix/magtek-debit-surcharge
  # Shared domain layer.
  pos_core:
    git:
      url: git@bitbucket.org:payfirst101/pos-resource.git
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
    final deps = await CoreDeps.read(dir.path, ['pf_processor_plugin', 'pos_core']);
    expect(deps[0].ref, 'fix/magtek-debit-surcharge');
    expect(deps[0].url, 'git@bitbucket.org:payfirst101/pf_processor_plugin.git');
    expect(deps[1].ref, isNull);
  });

  test('setRef replaces or inserts ref without touching other lines', () async {
    await CoreDeps.setRef(dir.path, 'pf_processor_plugin', 'develop');
    await CoreDeps.setRef(dir.path, 'pos_core', 'feature/x');
    final text = File(p.join(dir.path, 'pubspec.yaml')).readAsStringSync();
    expect(text, contains('       ref: develop'));
    expect(text, contains('      url: git@bitbucket.org:payfirst101/pos-resource.git\n      ref: feature/x'));
    expect(text, contains('#    path: ../pf_processor_plugin'));
    expect(text, contains('  qr: ^3.0.2'));
  });

  test('local override round-trip', () async {
    final local = Directory(p.join(dir.parent.path, 'pos-resource'));
    await CoreDeps.setLocal(dir.path, 'pos_core', local.path);
    final overrides = File(p.join(dir.path, 'pubspec_overrides.yaml'));
    expect(overrides.readAsStringSync(), 'dependency_overrides:\n  pos_core:\n    path: ../pos-resource\n');
    expect((await CoreDeps.read(dir.path, ['pos_core'])).single.localPath, p.normalize(local.path));

    await CoreDeps.setLocal(dir.path, 'pos_core', null);
    expect(overrides.existsSync(), isFalse);
  });

  test('toSsh converts token https URLs', () {
    expect(CoreDeps.toSsh('https://__USERNAME__:__TOKEN__@bitbucket.org/payfirst101/pf_processor_plugin.git'),
        'git@bitbucket.org:payfirst101/pf_processor_plugin.git');
    expect(CoreDeps.toSsh('https://bitbucket.org/payfirst101/pos-resource'), 'git@bitbucket.org:payfirst101/pos-resource.git');
  });
}
