import 'dart:io';

import 'package:devkit/modules/editor/packages_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _pubspec = '''
name: app
dependencies:
  flutter:
    sdk: flutter
  http: ^1.0.0 # a comment
  local_thing:
    path: ../local_thing
  inline: {git: https://x}

flutter:
  uses-material-design: true
  assets:
    - a.png

dev_dependencies:
  lints: ^2.0.0
''';

const _lock = '''
packages:
  http:
    dependency: "direct main"
    description:
      name: http
    version: "1.1.0"
  lints:
    dependency: "direct dev"
    version: "2.0.0"
''';

const _outdated = '''
Resolving...
{"packages":[
 {"package":"http","kind":"direct","isDiscontinued":false,"current":{"version":"1.1.0"},"upgradable":{"version":"1.2.0"},"resolvable":{"version":"1.2.0"},"latest":{"version":"2.0.0"}},
 {"package":"lints","kind":"dev","isDiscontinued":true,"current":{"version":"2.0.0"},"upgradable":{"version":"2.0.0"},"latest":{"version":"3.0.0"}},
 {"package":"meta","kind":"transitive","isDiscontinued":false,"current":{"version":"1.0.0"},"upgradable":null,"latest":{"version":"1.0.0"}}
]}
''';

void main() {
  test('names that could break a shell command are refused', () {
    expect(isValidPubName('http_parser'), isTrue);
    expect(isValidPubName('_private'), isTrue);
    for (final bad in ['Http', 'a b', 'a&calc', 'a;rm', 'a^1', '-x', '']) {
      expect(isValidPubName(bad), isFalse, reason: bad);
    }
  });

  group('parsing', () {
    test('reads declared packages, and only from the dependency sections', () {
      final found = parseDeclaredPackages(_pubspec, _lock);
      expect(found.map((x) => x.name), ['flutter', 'http', 'local_thing', 'inline', 'lints']);
      final http = found[1];
      expect((http.kind, http.current, http.fromPubDev), (PubKind.direct, '1.1.0', true));
      expect(found[0].fromPubDev, isFalse);
      expect(found[2].fromPubDev, isFalse);
      expect(found[3].fromPubDev, isFalse);
      expect(found[4].kind, PubKind.dev);
    });

    test('a missing lock file still lists what is declared', () {
      expect(parseDeclaredPackages(_pubspec, null)[1].current, isNull);
    });

    test('reads pub outdated, past anything printed before its JSON', () {
      final found = parsePubOutdated(_outdated)!;
      expect(found.length, 3);
      expect((found[0].canUpgrade, found[0].hasNewer), (true, true));
      expect((found[1].canUpgrade, found[1].hasNewer, found[1].discontinued), (false, true, true));
      expect((found[2].kind, found[2].canUpgrade, found[2].hasNewer), (PubKind.transitive, false, false));
    });

    test('anything else is not an answer', () {
      expect(parsePubOutdated('Could not resolve'), isNull);
      expect(parsePubOutdated('{broken'), isNull);
      expect(parsePubOutdated('{"other":1}'), isNull);
    });

    test('merging keeps declared kinds and adds what others pulled in', () {
      final merged = mergePackages(parseDeclaredPackages(_pubspec, _lock), parsePubOutdated(_outdated)!);
      expect(merged.map((x) => x.name), ['flutter', 'http', 'local_thing', 'inline', 'lints', 'meta']);
      expect(merged[1].latest, '2.0.0');
      expect(merged.last.kind, PubKind.transitive);
    });
  });

  group('sorting pubspec.yaml', () {
    test('orders by name, SDK first, keeping nested lines and comments', () {
      const before = '''
name: app
# about the app
dependencies:
  zebra: ^1.0.0
  # why apple is pinned
  apple: 1.2.3
  flutter:
    sdk: flutter
  mango:
    git:
      url: https://x
  flutter_localizations: {sdk: flutter}

  # a note at the end of the section

flutter:
  zzz: 1
  aaa: 2

dev_dependencies:
  lints: ^2.0.0
  flutter_test:
    sdk: flutter
''';
      const after = '''
name: app
# about the app
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations: {sdk: flutter}
  # why apple is pinned
  apple: 1.2.3
  mango:
    git:
      url: https://x
  zebra: ^1.0.0

  # a note at the end of the section

flutter:
  zzz: 1
  aaa: 2

dev_dependencies:
  flutter_test:
    sdk: flutter
  lints: ^2.0.0
''';
      expect(sortPubspecDependencies(before), after);
      expect(sortPubspecDependencies(after), after, reason: 'sorting twice changes nothing');
    });

    test('keeps Windows line breaks, and leaves a file without dependencies alone', () {
      expect(sortPubspecDependencies('dependencies:\r\n  b: 1\r\n  a: 2\r\n'), 'dependencies:\r\n  a: 2\r\n  b: 1\r\n');
      expect(sortPubspecDependencies('name: x\n'), 'name: x\n');
      expect(sortPubspecDependencies(''), '');
    });
  });

  group('view', () {
    late Directory dir;
    late List<String> ran;
    late int checks;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('pub');
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(_pubspec);
      File(p.join(dir.path, 'pubspec.lock')).writeAsStringSync(_lock);
      ran = [];
      checks = 0;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Widget view({bool visible = true, int revision = 0, bool busy = false}) => MaterialApp(
      home: Scaffold(
        body: PackagesView(
          root: dir.path,
          visible: visible,
          busy: busy,
          revision: revision,
          onRun: ran.add,
          onSort: () => ran.add('sort'),
          check: (_) async {
            checks++;
            return parsePubOutdated(_outdated);
          },
          search: (q) async => q == 'fail' ? throw const SocketException('offline') : [const PubSearchResult('dio', version: '5.0.0', description: 'HTTP client')],
        ),
      ),
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
      }
    }

    testWidgets('waits until it is shown, and checks again after a pub command', (tester) async {
      await tester.pumpWidget(view(visible: false));
      await settle(tester);
      expect(checks, 0);
      await tester.pumpWidget(view());
      await settle(tester);
      expect(checks, 1);
      await tester.pumpWidget(view(revision: 1));
      await settle(tester);
      expect(checks, 2);
    });

    testWidgets('shows versions and upgrades one package', (tester) async {
      await tester.pumpWidget(view());
      await settle(tester);
      expect(find.text('Packages  •  2 to update'), findsOneWidget);
      final shown = tester.getTopLeft(find.text('flutter')).dy, http = tester.getTopLeft(find.text('http')).dy, inline = tester.getTopLeft(find.text('inline')).dy;
      expect(shown < http && http < inline, isTrue, reason: 'listed by name');
      expect(find.text('http'), findsOneWidget);
      expect(find.text('meta'), findsNothing, reason: 'folded until asked for');
      await tester.tap(find.byTooltip('Upgrade to 1.2.0'));
      expect(ran, ['pub upgrade http']);
      await tester.tap(find.byTooltip('Upgrade to 3.0.0 (changes pubspec.yaml)'));
      expect(ran.last, 'pub upgrade --major-versions lints');
      await tester.tap(find.textContaining('Pulled in by others'));
      await tester.pump();
      expect(find.text('meta'), findsOneWidget);
    });

    testWidgets('nothing runs while another command is busy', (tester) async {
      await tester.pumpWidget(view(busy: true));
      await settle(tester);
      await tester.tap(find.byTooltip('pub get'), warnIfMissed: false);
      await tester.tap(find.byTooltip('Upgrade to 1.2.0'), warnIfMissed: false);
      expect(ran, isEmpty);
    });

    testWidgets('searches pub.dev and adds what it finds', (tester) async {
      await tester.pumpWidget(view());
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'dio');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.text('HTTP client'), findsOneWidget);
      await tester.tap(find.byTooltip('Add as a dependency'));
      await tester.pump();
      expect(ran, ['pub add dio']);
      expect(find.text('http'), findsOneWidget, reason: 'back to the list');
    });

    testWidgets('being offline says so, and a typed name can still be added', (tester) async {
      await tester.pumpWidget(view());
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'fail');
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.textContaining("Couldn't reach pub.dev"), findsOneWidget);
      await tester.tap(find.byTooltip('Add as a dependency'));
      expect(ran, ['pub add fail']);
    });

    testWidgets('a folder without a pubspec says so', (tester) async {
      File(p.join(dir.path, 'pubspec.yaml')).deleteSync();
      await tester.pumpWidget(view());
      await settle(tester);
      expect(find.textContaining('no pubspec.yaml'), findsOneWidget);
      expect(checks, 0);
    });
  });
}
