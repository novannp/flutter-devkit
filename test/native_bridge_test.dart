import 'package:hotrestart/core/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('hotrestart/native');

  Future<void> fromRunner(String method, [Object? arguments]) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );

  testWidgets('a file drop area hears the drag and gets the paths', (tester) async {
    final events = <String>[];
    await tester.pumpWidget(
      FileDropArea(
        onEnter: () => events.add('enter'),
        onExit: () => events.add('exit'),
        onDrop: (paths) => events.add(paths.join('|')),
        child: const SizedBox(),
      ),
    );
    await fromRunner('dragEntered');
    await fromRunner('dragExited');
    await fromRunner('dropped', ['C:/a b/app.apk', 'C:/c.txt']);
    expect(events, ['enter', 'exit', 'C:/a b/app.apk|C:/c.txt']);

    await tester.pumpWidget(const SizedBox());
    await fromRunner('dragEntered');
    expect(events, hasLength(3), reason: 'it stops listening once gone');
  });
}
