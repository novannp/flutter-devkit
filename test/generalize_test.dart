import 'package:slipway/core/firewall.dart';
import 'dart:io';

import 'package:slipway/core/apps.dart';
import 'package:slipway/modules/devices/services/network_scanner.dart';
import 'package:slipway/extensions/maintenance/core_deps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the firewall fix touches only its own rules, away from Public networks', () {
    final script = firewallFixScript('Slipway', [r'C:\Program Files\Slipway\slipway.exe']);
    expect(script, contains(r'program="C:\Program Files\Slipway\slipway.exe"'));
    expect(script, contains('profile=private,domain'));
    for (final risky in ['Bypass', 'Set-NetConnectionProfile', 'profile=any', 'public']) {
      expect(script, isNot(contains(risky)));
    }
  });

  group('subnetHosts', () {
    test('accepts the short forms as a /24', () {
      for (final s in ['192.168.5', '192.168.5.*', '192.168.5.0/24', ' 192.168.5.77/24 ']) {
        final hosts = subnetHosts(s)!;
        expect(hosts.length, 254, reason: s);
        expect(hosts.first, '192.168.5.1');
        expect(hosts.last, '192.168.5.254');
      }
    });

    test('handles wider masks and single hosts', () {
      final hosts = subnetHosts('10.1.2.3/22')!;
      expect(hosts.length, 1022);
      expect(hosts.first, '10.1.0.1');
      expect(hosts.last, '10.1.3.254');
      expect(subnetHosts('10.1.2.3'), ['10.1.2.3']);
    });

    test('rejects invalid or too wide input', () {
      for (final s in ['', 'abc', '300.1.1', '10.0.0.0/16', '10.0.0.0/33', '10.0', '1.2.3.4.5']) {
        expect(subnetHosts(s), isNull, reason: s);
      }
    });
  });

  group('apps', () {
    tearDown(() {
      knownApps = const [];
      appPrefixes = const [];
    });

    test('are nobody until configured', () {
      expect(isOurApp('com.example.app'), isFalse);
      expect(ourPackagesShell(), 'true');
    });

    test('match projects exactly and prefixes by start', () {
      knownApps = const [KnownApp('shop', 'shop', 'com.acme.shop')];
      appPrefixes = const ['org.team.'];
      expect(isOurApp('com.acme.shop'), isTrue);
      expect(isOurApp('com.acme.shop2'), isFalse);
      expect(isOurApp('org.team.any'), isTrue);
      expect(appName('com.acme.shop'), 'shop');
      expect(appShort('org.team.any'), 'any');
      expect(ourPackagesShell(), contains(r"grep -E '^(com\.acme\.shop$|org\.team\.)'"));
    });

    test('package ids that could break a shell command are refused', () {
      expect(isValidPackageId('com.acme.shop'), isTrue);
      expect(isValidPackageId(r'com.acme.$flavor'), isFalse);
      expect(isValidPackageId("x'; reboot; '"), isFalse);
    });
  });

  test('gitPackages finds both pubspec forms and skips the rest', () async {
    final dir = await Directory.systemTemp.createTemp('gitdeps');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: app
dependencies:
  flutter:
    sdk: flutter
  http: ^1.0.0
  long_form:
    git:
      url: git@example.com:team/long-repo.git
      ref: main
  short_form:
    git: https://example.com/team/short-repo.git
  local:
    path: ../local
''');
    expect(await CoreDeps.gitPackages(dir.path), ['long_form', 'short_form']);
    final deps = await CoreDeps.read(dir.path, ['long_form', 'short_form']);
    expect(deps.map((d) => d.repo), ['long-repo', 'short-repo']);
  });
}
