import 'package:devkit/modules/help/getting_started.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, void Function(BuildContext) onReady) async {
    tester.view.physicalSize = const Size(560, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onReady(context));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('walks every step and fits the smallest window', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHost(tester, (context) => showGettingStartedOnce(context));
    expect(find.text('Open a project'), findsOneWidget);
    expect(tester.takeException(), isNull);

    for (final title in ['Write code', 'Run your app', 'Debug and commit', 'Make it yours']) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Skip'), findsNothing);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Debug and commit'), findsOneWidget);
  });

  testWidgets('shows only once', (tester) async {
    SharedPreferences.setMockInitialValues({'getting_started_seen': true});
    await pumpHost(tester, (context) => showGettingStartedOnce(context));
    expect(find.byType(GettingStartedDialog), findsNothing);
  });
}
