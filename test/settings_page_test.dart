import 'package:devkit/core/tools.dart';
import 'package:devkit/modules/devices/services/adb_service.dart';
import 'package:devkit/modules/editor/editor_view.dart';
import 'package:devkit/modules/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
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

    final size = EditorView.fontSize.value;
    await tester.tap(find.byTooltip('Larger'));
    await tester.pump();
    expect(EditorView.fontSize.value, size + 1);
    await tester.tap(find.byTooltip('Smaller'));
    await tester.pump();
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
