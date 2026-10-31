import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'chat_service.dart';

/// In-app fake peer so Chat can be tried on a single PC: shows up on the LAN like another DevKit and echoes.
class ChatTestBot extends ChangeNotifier {
  ChatTestBot._();

  static final instance = ChatTestBot._();

  static const name = 'Test Bot 🤖';
  final _id = 'bot-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  Timer? _ping;
  final _peers = <String, (String ip, int port)>{};

  bool get running => _server != null;
  int? get port => _server?.port;
  bool get pinging => _ping != null;

  Future<void> start() async {
    if (running) return;
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_onConnection);
    _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, ChatService.beaconPort, reuseAddress: true)
      ..broadcastEnabled = true
      ..listen(_onDatagram);
    _beacon = Timer.periodic(const Duration(seconds: 4), (_) => _sendBeacon());
    _sendBeacon();
    notifyListeners();
  }

  Future<void> stop() async {
    _sendBeacon(bye: true);
    _beacon?.cancel();
    _ping?.cancel();
    _beacon = _ping = null;
    _udp?.close();
    await _server?.close();
    _udp = null;
    _server = null;
    notifyListeners();
  }

  /// Sends a direct message every [every] so notifications can be tested with DevKit minimized.
  void setPing(bool on, {Duration every = const Duration(seconds: 20)}) {
    _ping?.cancel();
    _ping = on
        ? Timer.periodic(every, (_) {
            final t = DateTime.now();
            for (final id in _peers.keys) {
              _send(
                id,
                id,
                'Ping ${t.hour}:${t.minute.toString().padLeft(2, '0')} — minimize DevKit to see the notification',
              );
            }
          })
        : null;
    notifyListeners();
  }

  void _sendBeacon({bool bye = false}) {
    final udp = _udp;
    if (udp == null) return;
    final data = utf8.encode(
      jsonEncode({
        'app': 'ravo-devkit',
        'type': bye ? 'bye' : 'hello',
        'id': _id,
        'name': name,
        'host': 'this PC',
        'port': _server?.port ?? 0,
      }),
    );
    // Loopback is enough: the bot only talks to the DevKit on this PC.
    udp.send(data, InternetAddress('255.255.255.255'), ChatService.beaconPort);
    udp.send(data, InternetAddress.loopbackIPv4, ChatService.beaconPort);
  }

  void _onDatagram(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = _udp?.receive();
    if (d == null) return;
    try {
      final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
      if (j['app'] != 'ravo-devkit' || j['id'] == _id || j['type'] != 'hello') return;
      _peers[j['id'] as String] = (d.address.address, j['port'] as int);
    } catch (_) {}
  }

  void _onConnection(Socket s) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            try {
              final j = jsonDecode(line) as Map<String, dynamic>;
              if (j['type'] != 'msg') return;
              final from = j['from'] as String;
              await Future<void>.delayed(const Duration(milliseconds: 700));
              _send(from, j['to'] == everyone ? everyone : from, 'Echo: ${j['text']}');
            } catch (_) {}
          },
          onDone: s.destroy,
          onError: (_) => s.destroy(),
          cancelOnError: true,
        );
  }

  Future<void> _send(String peerId, String to, String text) async {
    final peer = _peers[peerId];
    if (peer == null) return;
    final msg = {
      'type': 'msg',
      'id': '$_id-${DateTime.now().microsecondsSinceEpoch}',
      'from': _id,
      'fromName': name,
      'to': to,
      'text': text,
      'time': DateTime.now().toIso8601String(),
    };
    try {
      final s = await Socket.connect(peer.$1, peer.$2, timeout: const Duration(seconds: 3));
      s.write('${jsonEncode(msg)}\n');
      await s.flush();
      await s.close();
    } catch (_) {}
  }
}
