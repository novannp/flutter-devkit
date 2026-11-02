import 'package:devkit/core/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('devkit/native');

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

  testWidgets('a notification click reaches its own callback, once', (tester) async {
    final sent = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      sent.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    var first = 0, second = 0;
    await NativeBridge.notify(title: 'A', body: 'one', onClick: () => first++);
    await NativeBridge.notify(title: 'B', body: 'two', onClick: () => second++);
    expect(sent.map((m) => m['title']), ['A', 'B']);

    await fromRunner('notificationClicked', sent[1]['id']);
    await fromRunner('notificationClicked', sent[1]['id']);
    expect((first, second), (0, 1));
  });

  testWidgets('a failing toast stays quiet', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'toast_failed'));
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await NativeBridge.notify(title: 'A', body: 'one');
  });
}
