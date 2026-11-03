import 'dart:io';

import 'package:devkit/core/settings.dart';
import 'package:devkit/core/tools.dart';
import 'package:devkit/extensions/emulators/avd_service.dart';
import 'package:devkit/modules/devices/services/adb_service.dart';
import 'package:devkit/modules/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester, Size size) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tools = (await tester.runAsync(Tools.resolve))!;
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: AdbService(tools),
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  }

  testWidgets('shows one category at a time', (tester) async {
    await pumpPage(tester, const Size(1000, 700));
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Word wrap'), findsNothing);

    await tester.tap(find.text('Editor'));
    await tester.pump();
    expect(find.text('Word wrap'), findsOneWidget);
    expect(find.text('Theme'), findsNothing);

    final field = find.descendant(of: find.ancestor(of: find.text('Font size'), matching: find.byType(Row)).first, matching: find.byType(TextField));
    await tester.enterText(field, '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(Settings.instance.number('editor.fontSize'), 36, reason: 'kept in range');
    await Settings.instance.set(SettingScope.global, 'editor.fontSize', null);
    await tester.pump();
  });

  testWidgets('settings can be set for one project, and fall back when reset', (tester) async {
    final dir = Directory.systemTemp.createTempSync('scope');
    addTearDown(() {
      Settings.instance.openProject(null);
      dir.deleteSync(recursive: true);
    });
    Settings.instance.openProject(dir.path);
    await pumpPage(tester, const Size(1200, 900));
    await tester.tap(find.text('Dart'));
    await tester.pump();
    await tester.tap(find.textContaining('This project'));
    await tester.pump();
    final wrap = find.descendant(of: find.ancestor(of: find.text('Show TODOs in Problems'), matching: find.byType(Row)).first, matching: find.byType(Switch));
    await tester.tap(wrap);
    await tester.pump();
    expect(Settings.instance.valueIn(SettingScope.project, 'dart.showTodos'), isTrue);
    expect(Settings.instance.valueIn(SettingScope.global, 'dart.showTodos'), isNull);
    expect(File(p.join(dir.path, '.devkit', 'settings.json')).existsSync(), isTrue);
    await tester.tap(find.text('Use my setting'));
    await tester.pump();
    expect(Settings.instance.flag('dart.showTodos'), isFalse);
  });

  testWidgets('search finds settings across every category', (tester) async {
    await pumpPage(tester, const Size(1000, 700));
    await tester.enterText(find.byType(TextField).first, 'subnet');
    await tester.pump();
    expect(find.text('Network scan subnets'), findsOneWidget);
    expect(find.text('Theme'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'nothing like this');
    await tester.pump();
    expect(find.text('No settings match'), findsOneWidget);

    // Picking a category leaves the search.
    await tester.tap(find.text('Tools'));
    await tester.pump();
    expect(find.text('adb'), findsOneWidget);
    expect(find.text('No settings match'), findsNothing);
  });

  testWidgets('a chosen Android SDK without an emulator says so, and can be undone', (tester) async {
    await AvdService.setCustomSdk(null);
    addTearDown(() => AvdService.setCustomSdk(null));
    AvdService.customSdk.value = '/no/such/sdk';
    await pumpPage(tester, const Size(1000, 700));
    await tester.tap(find.text('Tools'));
    await tester.pump();
    expect(find.text('Android SDK'), findsOneWidget);
    expect(find.text('Use detected'), findsOneWidget);
    await tester.tap(find.text('Use detected'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(AvdService.customSdk.value, isNull);
    expect(find.text('Use detected'), findsNothing);
  });

  test('reads the SDK flutter config saved', () {
    expect(androidSdkInFlutterSettings('{"android-sdk": "D:/Android/Sdk", "x": 1}'), 'D:/Android/Sdk');
    expect(androidSdkInFlutterSettings('{"enable-web": true}'), isNull);
    expect(androidSdkInFlutterSettings('not json'), isNull);
  });

  testWidgets('every category fits the smallest window', (tester) async {
    await pumpPage(tester, const Size(560, 400));
    for (final label in ['General', 'Editor', 'Projects', 'Devices', 'Tools']) {
      await tester.ensureVisible(find.text(label).first);
      await tester.tap(find.text(label).first);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: label);
    }
  });
}
