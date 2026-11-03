import 'dart:io';

import 'package:slipway/modules/editor/project_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _fvmList = '{"size":"1 GB","versions":[{"name":"stable","type":"channel","flutterSdkVersion":"3.47.6","dartSdkVersion":"3.13.5","isSetup":true},'
    '{"name":"3.47.5","flutterSdkVersion":"3.47.5","dartSdkVersion":"3.13.4","isSetup":true},{"name":"bad & name","isSetup":true}]}';
const _fvmReleases = '{"versions":[{"version":"3.47.9","dart_sdk_version":"3.13.7","release_date":"2026-10-29T19:16:00Z"},{"version":"3.47.5","dart_sdk_version":"3.13.4"}]}';
const _logins = '{"status":"success","result":[{"user":{"email":"me@example.com"}}]}';
const _projects = '{"status":"success","result":[{"projectId":"my-app-1","displayName":"My App"},{"projectId":"Bad Id","displayName":"x"}]}';

void main() {
  late Directory dir;
  late List<List<String>> ran;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tools');
    Directory(p.join(dir.path, 'android')).createSync();
    Directory(p.join(dir.path, 'web')).createSync();
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: a\ndependencies:\n  firebase_auth: ^5.0.0\n');
    ran = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> show(WidgetTester tester, Widget dialog) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => showDialog<void>(context: context, builder: (_) => dialog), child: const Text('Open')),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await settle(tester);
  }

  group('parsing', () {
    test('fvm versions, leaving out what a shell could trip on', () {
      final versions = parseFvmVersions('note before\n$_fvmList')!;
      expect(versions.map((v) => v.name), ['stable', '3.47.5']);
      expect(versions.first.flutter, '3.47.6');
      expect(parseFvmVersions('not json'), isNull);
    });

    test('fvm releases', () {
      final releases = parseFvmReleases(_fvmReleases)!;
      expect((releases.first.version, releases.first.date), ('3.47.9', '2026-10-29'));
      expect(releases.last.date, isNull);
    });

    test('firebase answers', () {
      expect(parseFirebaseAccount(_logins), 'me@example.com');
      expect(parseFirebaseAccount('{"status":"success","result":[]}'), isNull);
      expect(parseFirebaseAccount('Error'), isNull);
      expect(parseFirebaseProjects(_projects)!.single.id, 'my-app-1');
    });

    test('names that reach a shell', () {
      expect(isValidFirebaseId('my-app-1'), isTrue);
      for (final bad in ['Upper', 'a b', 'x&y', 'short', '-start', 'ends-', '']) {
        expect(isValidFirebaseId(bad), isFalse, reason: bad);
      }
      expect(isValidFirebaseName('My App 2'), isTrue);
      expect(isValidFirebaseName('a & calc'), isFalse);
      expect(isValidFlutterVersion('3.47.5-0.1.pre'), isTrue);
      expect(isValidFlutterVersion('x;rm'), isFalse);
    });

    test('the project and its platforms', () {
      expect(flutterPlatformsIn(dir.path), ['android', 'web']);
      expect(pinnedFvmVersion(dir.path), isNull);
      File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter":"3.47.5"}');
      expect(pinnedFvmVersion(dir.path), '3.47.5');
    });
  });

  group('FVM', () {
    Future<(int, String)> probe(List<String> command) async => switch (command[2]) {
      'list' => (0, _fvmList),
      _ => (0, _fvmReleases),
    };

    testWidgets('lists versions and pins one for the project', (tester) async {
      File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter":"3.47.5"}');
      await show(tester, FvmDialog(root: dir.path, onRun: ran.add, probe: probe));
      expect(find.text('stable'), findsOneWidget);
      expect(find.text(' This project'), findsOneWidget);
      await tester.tap(find.text('Use here').first);
      await tester.pump();
      expect(ran.single, ['fvm', 'use', 'stable', '--force']);
    });

    testWidgets('installs a release', (tester) async {
      await show(tester, FvmDialog(root: dir.path, onRun: ran.add, probe: probe));
      await tester.tap(find.text('Available'));
      await tester.pump();
      expect(find.text('3.47.9'), findsOneWidget);
      await tester.tap(find.text('Install').first);
      await tester.pump();
      expect(ran.single, ['fvm', 'install', '3.47.9']);
    });

    testWidgets('offers to install FVM when it is missing', (tester) async {
      await show(tester, FvmDialog(root: dir.path, onRun: ran.add, probe: (_) async => (-1, 'not found')));
      await tester.tap(find.text('Install FVM'));
      await tester.pump();
      expect(ran.single, ['dart', 'pub', 'global', 'activate', 'fvm']);
    });
  });

  group('Firebase', () {
    Future<(int, String)> ready(List<String> command) async {
      final line = command.join(' ');
      if (line == 'firebase --version') return (0, '15.0.0');
      if (line == 'npm --version') return (0, '10.0.0');
      if (line == 'dart pub global list') return (0, 'flutterfire_cli 1.0.0\n');
      if (line.startsWith('firebase login:list')) return (0, _logins);
      if (line.startsWith('firebase projects:list')) return (0, _projects);
      return (1, '');
    }

    Widget dialog(ToolProbe probe, List<List<String>> terminal) => FirebaseDialog(root: dir.path, onRun: ran.add, onSignIn: (c) async => terminal.add(c), probe: probe);

    testWidgets('configures the chosen project for the chosen platforms', (tester) async {
      await show(tester, dialog(ready, []));
      expect(find.textContaining('me@example.com'), findsOneWidget);
      await tester.tap(find.text('web'));
      await tester.pump();
      await tester.tap(find.text('Run flutterfire configure'));
      await tester.pump();
      expect(ran.single, ['dart', 'pub', 'global', 'run', 'flutterfire_cli:flutterfire', 'configure', '--project=my-app-1', '--yes', '--platforms=android']);
    });

    testWidgets('adds only the packages the project lacks', (tester) async {
      await show(tester, dialog(ready, []));
      await tester.ensureVisible(find.text('cloud_firestore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cloud_firestore'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add 2 packages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 2 packages'));
      await tester.pump();
      expect(ran.single.take(3), ['flutter', 'pub', 'add']);
      expect(ran.single.skip(3).toSet(), {'firebase_core', 'cloud_firestore'});
    });

    testWidgets('creates a project only with a valid id', (tester) async {
      await show(tester, dialog(ready, []));
      await tester.enterText(find.byType(TextField).first, 'Bad Id');
      await tester.pump();
      expect(find.textContaining('6 to 30 lowercase'), findsOneWidget);
      await tester.tap(find.text('Create'), warnIfMissed: false);
      expect(ran, isEmpty);
      await tester.enterText(find.byType(TextField).first, 'fresh-app');
      await tester.enterText(find.byType(TextField).last, 'Fresh App');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(ran.single, ['firebase', 'projects:create', 'fresh-app', '--display-name', 'Fresh App']);
    });

    testWidgets('without the tools or an account it says what to do first', (tester) async {
      final terminal = <List<String>>[];
      await show(tester, dialog((command) async {
        final line = command.join(' ');
        if (line == 'firebase --version') return (0, '15.0.0');
        if (line.startsWith('firebase login:list')) return (0, '{"status":"success","result":[]}');
        return (1, '');
      }, terminal));
      expect(find.text('Install FlutterFire CLI'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sign in'));
      await tester.pump();
      expect(terminal.single, ['firebase', 'login']);
      expect(find.text('Firebase'), findsOneWidget, reason: 'the dialog stays, for Check again');
    });
  });
}
