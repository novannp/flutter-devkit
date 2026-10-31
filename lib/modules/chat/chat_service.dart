import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const everyone = 'all';

class Peer {
  Peer({required this.id, required this.name, required this.host, required this.ip, required this.port});

  final String id;
  String name;
  String host;
  String ip;
  int port;
  DateTime lastSeen = DateTime.now();

  bool get online => DateTime.now().difference(lastSeen) < ChatService._peerTimeout;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.fromName,
    required this.to,
    required this.text,
    required this.time,
  });

  final String id;
  final String from;
  final String fromName;

  /// Peer id for a direct message, or [everyone].
  final String to;
  final String text;
  final DateTime time;

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    'fromName': fromName,
    'to': to,
    'text': text,
    'time': time.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String,
    from: j['from'] as String,
    fromName: j['fromName'] as String? ?? '?',
    to: j['to'] as String? ?? everyone,
    text: j['text'] as String? ?? '',
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
  );
}

/// LAN-only chat between DevKit users: UDP broadcast beacons for discovery, TCP for messages.
class ChatService extends ChangeNotifier {
  ChatService._();

  static final instance = ChatService._();

  static const beaconPort = 47232;
  static const _preferredPort = 47231;
  static const _beaconEvery = Duration(seconds: 4);
  static const _peerTimeout = Duration(seconds: 15);
  static const _maxPerConversation = 500;

  late String myId;
  late String myName;

  /// False until the user has picked a display name (asked on first launch).
  bool hasName = false;
  final myHost = Platform.localHostname;
  int port = 0;

  final peers = <String, Peer>{};
  final conversations = <String, List<ChatMessage>>{};
  final unread = <String, int>{};
  final _seen = <String>{};

  /// Fires for every incoming message (for in-app notifications).
  final incoming = StreamController<ChatMessage>.broadcast();

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  bool started = false;

  /// Completes once the saved name/id are loaded.
  final ready = Completer<void>();
  String? error;

  int get totalUnread => unread.values.fold(0, (a, b) => a + b);

  // Offline test bots are just noise in the list.
  List<Peer> get sortedPeers => peers.values.where((p) => p.online || !p.id.startsWith('bot-')).toList()
    ..sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  Future<void> start() async {
    if (started) return;
    started = true;
    final prefs = await SharedPreferences.getInstance();
    myId = prefs.getString('chat_id') ?? _randomId();
    await prefs.setString('chat_id', myId);
    hasName = prefs.getString('chat_name') != null;
    myName = prefs.getString('chat_name') ?? Platform.environment['USERNAME'] ?? myHost;
    await _loadHistory();
    ready.complete();

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _preferredPort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    port = _server!.port;
    _server!.listen(_onConnection);

    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, beaconPort, reuseAddress: true)
        ..broadcastEnabled = true
        ..listen(_onDatagram);
    } on SocketException catch (e) {
      error = 'Discovery port $beaconPort unavailable: ${e.message}';
    }
    _beacon = Timer.periodic(_beaconEvery, (_) => _sendBeacon());
    await _sendBeacon();
    notifyListeners();
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<void> rename(String name) async {
    myName = name.trim().isEmpty ? myName : name.trim();
    hasName = true;
    await (await SharedPreferences.getInstance()).setString('chat_name', myName);
    await _sendBeacon();
    notifyListeners();
  }

  Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in nic.addresses) {
        if (a.isLoopback) continue;
        // Directed /24 broadcast reaches peers when the limited broadcast is filtered.
        targets.add('${a.address.substring(0, a.address.lastIndexOf('.'))}.255');
      }
    }
    return targets.map(InternetAddress.new).toList();
  }

  Future<void> _sendBeacon({bool bye = false}) async {
    final udp = _udp;
    if (udp == null) return;
    final data = utf8.encode(
      jsonEncode({
        'app': 'ravo-devkit',
        'type': bye ? 'bye' : 'hello',
        'id': myId,
        'name': myName,
        'host': myHost,
        'port': port,
      }),
    );
    for (final t in await _broadcastTargets()) {
      try {
        udp.send(data, t, beaconPort);
      } catch (_) {}
    }
    _expirePeers();
  }

  void _expirePeers() {
    // Repaint so online dots turn grey after the timeout.
    if (peers.values.any((p) => !p.online)) notifyListeners();
  }

  void _onDatagram(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = _udp?.receive();
    if (d == null) return;
    try {
      final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
      if (j['app'] != 'ravo-devkit' || j['id'] == myId) return;
      final id = j['id'] as String;
      if (j['type'] == 'bye') {
        peers[id]?.lastSeen = DateTime(0);
        notifyListeners();
        return;
      }
      final peer = peers.putIfAbsent(
        id,
        () => Peer(id: id, name: '', host: '', ip: d.address.address, port: j['port'] as int),
      );
      final wasOnline = peer.online && peer.name.isNotEmpty;
      peer
        ..name = j['name'] as String? ?? 'Unknown'
        ..host = j['host'] as String? ?? ''
        ..ip = d.address.address
        ..port = j['port'] as int
        ..lastSeen = DateTime.now();
      if (!wasOnline) {
        notifyListeners();
        // Answer right away so a newcomer sees us without waiting for the next beacon.
        _sendBeacon();
      }
    } catch (_) {}
  }

  void _onConnection(Socket s) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final j = jsonDecode(line) as Map<String, dynamic>;
              if (j['type'] != 'msg') return;
              final m = ChatMessage.fromJson(j);
              _store(m, incomingMessage: true);
              final peer = peers[m.from];
              if (peer != null) {
                peer
                  ..lastSeen = DateTime.now()
                  ..ip = s.remoteAddress.address;
              }
            } catch (_) {}
          },
          onDone: s.destroy,
          onError: (_) => s.destroy(),
          cancelOnError: true,
        );
  }

  String conversationOf(ChatMessage m) => m.to == everyone ? everyone : (m.from == myId ? m.to : m.from);

  void _store(ChatMessage m, {required bool incomingMessage}) {
    if (!_seen.add(m.id)) return;
    final key = conversationOf(m);
    final list = conversations.putIfAbsent(key, () => []);
    list.add(m);
    if (list.length > _maxPerConversation) list.removeAt(0);
    if (incomingMessage) {
      unread[key] = (unread[key] ?? 0) + 1;
      incoming.add(m);
    }
    notifyListeners();
    _saveHistory();
  }

  void markRead(String conversation) {
    if ((unread[conversation] ?? 0) == 0) return;
    unread.remove(conversation);
    notifyListeners();
  }

  /// Sends to one peer, or to every online peer for [everyone]. Returns how many peers got it.
  Future<int> send(String to, String text) async {
    final body = text.trim();
    if (body.isEmpty) return 0;
    final m = ChatMessage(
      id: '$myId-${DateTime.now().microsecondsSinceEpoch}',
      from: myId,
      fromName: myName,
      to: to,
      text: body,
      time: DateTime.now(),
    );
    _store(m, incomingMessage: false);
    final targets = to == everyone ? peers.values.where((p) => p.online) : [?peers[to]];
    final line = '${jsonEncode({'type': 'msg', ...m.toJson()})}\n';
    final results = await Future.wait(targets.map((p) => _deliver(p, line)));
    return results.where((ok) => ok).length;
  }

  Future<bool> _deliver(Peer p, String line) async {
    try {
      final s = await Socket.connect(p.ip, p.port, timeout: const Duration(seconds: 3));
      s.write(line);
      await s.flush();
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<File> _historyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}chat_history.json');
  }

  Future<void> _loadHistory() async {
    try {
      final f = await _historyFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      for (final e in (j['peers'] as Map<String, dynamic>? ?? {}).entries) {
        final p = e.value as Map<String, dynamic>;
        peers[e.key] = Peer(
          id: e.key,
          name: p['name'] as String,
          host: p['host'] as String? ?? '',
          ip: p['ip'] as String? ?? '',
          port: p['port'] as int? ?? _preferredPort,
        )..lastSeen = DateTime(0);
      }
      for (final e in (j['conversations'] as Map<String, dynamic>? ?? {}).entries) {
        final list = [for (final m in e.value as List) ChatMessage.fromJson(m as Map<String, dynamic>)];
        conversations[e.key] = list;
        _seen.addAll(list.map((m) => m.id));
      }
    } catch (_) {
      // A corrupt history file shouldn't stop chat.
    }
  }

  Timer? _saveDebounce;

  void _saveHistory() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), () async {
      final f = await _historyFile();
      await f.writeAsString(
        jsonEncode({
          'peers': {
            for (final p in peers.values) p.id: {'name': p.name, 'host': p.host, 'ip': p.ip, 'port': p.port},
          },
          'conversations': {
            for (final e in conversations.entries) e.key: [for (final m in e.value) m.toJson()],
          },
        }),
      );
    });
  }

  Future<void> stop() async {
    await _sendBeacon(bye: true);
    _beacon?.cancel();
    _udp?.close();
    await _server?.close();
  }
}
