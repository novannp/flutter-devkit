import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipway/modules/help/licenses_page.dart';

import 'ink_audit.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = String.fromCharCodes(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
      return ByteData.sublistView(File(Uri.decodeFull(key)).readAsBytesSync());
    });
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LicensesDialog())));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  testWidgets('credits what ships, what it runs and every package', (tester) async {
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(['some_package'], 'The text of the license');
    });
    await open(tester);
    expect(inksHiddenBehindABox(), isEmpty);
    expect(find.textContaining('MIT License'), findsOneWidget, reason: "Slipway's own text opens first");
    for (final name in ['scrcpy', 'FFmpeg', 'SDL2']) {
      expect(find.text(name), findsOneWidget);
    }

    await tester.enterText(find.byType(TextField), 'farias');
    await tester.pump();
    expect(find.text('scrcpy'), findsNothing);
    await tester.tap(find.text('FVM'));
    await tester.pump();
    expect(find.text('By Leo Farias and contributors'), findsOneWidget);
    expect(find.text('Open its page'), findsOneWidget);
    expect(find.textContaining('Not part of Slipway'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'some_package');
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(InkWell), matching: find.text('some_package')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('The text of the license'), findsOneWidget);
  });
}
