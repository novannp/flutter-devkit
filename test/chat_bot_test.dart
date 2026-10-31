import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ravo_devkit/modules/chat/chat_service.dart';
import 'package:ravo_devkit/modules/chat/chat_test_bot.dart';

void main() {
  test('test bot learns a peer from its beacon and echoes messages back', () async {
    final bot = ChatTestBot.instance;
    await bot.start();
    addTearDown(bot.stop);

    final app = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(app.close);
    final echo = Completer<Map<String, dynamic>>();
    app.listen(
      (s) => s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        if (!echo.isCompleted) echo.complete(jsonDecode(l) as Map<String, dynamic>);
      }),
    );

    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
      ..broadcastEnabled = true;
    addTearDown(udp.close);
    udp.send(
      utf8.encode(jsonEncode({'app': 'ravo-devkit', 'type': 'hello', 'id': 'app1', 'name': 'Me', 'port': app.port})),
      InternetAddress('255.255.255.255'),
      ChatService.beaconPort,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final s = await Socket.connect(InternetAddress.loopbackIPv4, bot.port!);
    s.write(
      '${jsonEncode({'type': 'msg', 'id': 'm1', 'from': 'app1', 'fromName': 'Me', 'to': 'bot', 'text': 'hi', 'time': DateTime.now().toIso8601String()})}\n',
    );
    await s.close();

    final reply = await echo.future.timeout(const Duration(seconds: 5));
    expect(reply['text'], 'Echo: hi');
    expect(reply['to'], 'app1');
  });
}
