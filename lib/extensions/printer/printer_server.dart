import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'escpos.dart';

class Receipt {
  Receipt(this.elements, this.source, this.raw, {DateTime? time}) : time = time ?? DateTime.now();

  final List<ReceiptElement> elements;
  final String source;
  final Uint8List raw;
  final DateTime time;

  String get text => elements
      .map(
        (e) => switch (e) {
          TextLine() => e.plain,
          QrElement() => '[QR] ${e.data}',
          BarcodeElement() => '[BARCODE] ${e.data}',
          RasterImage() => '[IMAGE ${e.width}×${e.height}]',
          FeedElement() => '\n' * (e.lines - 1),
          EventElement() => '[${e.label}]',
        },
      )
      .join('\n');

  String get title => elements
      .whereType<TextLine>()
      .map((l) => l.plain.trim())
      .firstWhere((t) => t.isNotEmpty, orElse: () => '(no text)');
}

/// Fake network printer: accepts raw ESC/POS over TCP (default 9100) like a LAN thermal printer.
class PrinterServer extends ChangeNotifier {
  static const _prefPort = 'printer_port';
  static const _prefAuto = 'printer_autostart';
  static const _prefPaper = 'printer_paper_mm';

  final _servers = <ServerSocket>[];
  final _statusServers = <ServerSocket>[];

  /// Addresses actually listening (LAN IPs, plus localhost when it's free).
  final boundAddresses = <String>[];

  /// Set when localhost:port is taken (usually Dart DevTools), so 10.0.2.2 from an emulator won't reach us.
  bool localhostBusy = false;

  RawDatagramSocket? _discovery;

  /// Network printer search: the POS broadcasts "BG" / "B[]G" to UDP 3000 and lists whoever answers.
  static const discoveryPort = 3000;

  Future<void> _startDiscovery() async {
    try {
      _discovery = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true)
        ..broadcastEnabled = true
        ..listen((e) async {
          if (e != RawSocketEvent.read) return;
          final d = _discovery?.receive();
          if (d == null) return;
          final msg = String.fromCharCodes(d.data);
          if (msg != 'BG' && msg != 'B[]G') return;
          final reply = await _discoveryReply(d.address);
          try {
            _discovery?.send(reply.codeUnits, d.address, d.port);
          } catch (_) {}
        });
    } on SocketException {
      // Discovery is a convenience; printing by IP still works.
    }
  }

  /// Answer with the LAN address in the asker's subnet (or the first one, e.g. for NAT'd emulators).
  Future<String> _discoveryReply(InternetAddress asker) async {
    final ips = await localIps();
    final prefix = asker.address.substring(0, asker.address.lastIndexOf('.') + 1);
    final ip = ips.where((i) => i.startsWith(prefix)).firstOrNull ?? ips.firstOrNull ?? '127.0.0.1';
    final gw = ip.contains('.') ? '${ip.substring(0, ip.lastIndexOf('.'))}.1' : ip;
    return 'IP:$ip;DEVICENAME:DevKit Printer;MAC:02:DE:7C:00:91:00;SUBNETWORK:255.255.255.0;GATEWAY:$gw;';
  }

  /// Some drivers read printer status from the next port (9101) over LAN.
  static const statusPortOffset = 1;
  static const defaultPort = 9100;
  final receipts = <Receipt>[];
  final _clients = <Socket>{};
  int port = 9100;
  int paperMm = 80;
  bool autoStart = true;
  String? error;
  int activeConnections = 0;
  final _received = StreamController<Receipt>.broadcast();

  Stream<Receipt> get onReceipt => _received.stream;
  bool get running => _servers.isNotEmpty;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    port = prefs.getInt(_prefPort) ?? 9100;
    paperMm = prefs.getInt(_prefPaper) ?? 80;
    autoStart = prefs.getBool(_prefAuto) ?? true;
    await _loadSaved();
    if (autoStart) await start();
    notifyListeners();
  }

  /// Receipts from earlier sessions, re-parsed from their saved raw bytes.
  Future<void> _loadSaved() async {
    try {
      final dir = await rawDir();
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.bin')).toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.take(_keepReceipts)) {
        final m = RegExp(r'receipt_([\dT-]+)_(?:([\d.]+)_)?\d+\.bin$').firstMatch(f.path);
        final t = m == null ? null : DateTime.tryParse(_isoFromName(m[1]!));
        final parsed = <List<ReceiptElement>>[];
        EscPosParser(onCut: parsed.add, respond: (_) {})
          ..add(await f.readAsBytes())
          ..flush();
        final elements = [for (final p in parsed) ...p];
        if (elements.isEmpty) continue;
        receipts.add(Receipt(elements, m?[2] ?? 'saved', await f.readAsBytes(), time: t ?? f.lastModifiedSync()));
      }
    } catch (_) {}
  }

  static String _isoFromName(String s) {
    // 2026-11-01T01-29-24-826415 → 2026-11-01T01:29:24.826415
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-?(\d*)$').firstMatch(s);
    return m == null ? s : '${m[1]}T${m[2]}:${m[3]}:${m[4]}${m[5]!.isEmpty ? '' : '.${m[5]}'}';
  }

  static const _keepReceipts = 500;

  // Bind each address separately: Dart DevTools grabs 127.0.0.1:9100/9101, which blocks a 0.0.0.0 bind.
  Future<List<ServerSocket>> _bindAll(int port, void Function(Socket) onClient) async {
    final out = <ServerSocket>[];
    final addresses = [InternetAddress.loopbackIPv4, for (final ip in await localIps()) InternetAddress(ip)];
    for (final a in addresses) {
      try {
        out.add((await ServerSocket.bind(a, port))..listen(onClient));
      } on SocketException {
        // Taken on this address only; others may still work.
      }
    }
    return out;
  }

  Future<void> start() async {
    if (running) return;
    _servers.addAll(await _bindAll(port, _onClient));
    boundAddresses
      ..clear()
      ..addAll(_servers.map((s) => s.address.address));
    localhostBusy = !boundAddresses.contains(InternetAddress.loopbackIPv4.address);
    final lanBound = boundAddresses.any((a) => a != InternetAddress.loopbackIPv4.address);
    if (!lanBound) {
      error = "Port $port is in use on this PC's network address. Close the app using it, or check Windows Firewall.";
    } else {
      error = null;
      // Status port is optional; most drivers only need the data port.
      _statusServers.addAll(await _bindAll(port + statusPortOffset, _onStatusClient));
      await _startDiscovery();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    for (final s in [..._servers, ..._statusServers]) {
      await s.close();
    }
    _servers.clear();
    _statusServers.clear();
    _discovery?.close();
    _discovery = null;
    boundAddresses.clear();
    for (final c in _clients) {
      c.destroy();
    }
    _clients.clear();
    notifyListeners();
  }

  Future<void> configure({int? port, int? paperMm, bool? autoStart}) async {
    final prefs = await SharedPreferences.getInstance();
    if (paperMm != null) {
      this.paperMm = paperMm;
      await prefs.setInt(_prefPaper, paperMm);
    }
    if (autoStart != null) {
      this.autoStart = autoStart;
      await prefs.setBool(_prefAuto, autoStart);
    }
    if (port != null && port != this.port) {
      this.port = port;
      await prefs.setInt(_prefPort, port);
      if (running) {
        await stop();
        await start();
      }
    }
    notifyListeners();
  }

  void _onClient(Socket socket) {
    _clients.add(socket);
    activeConnections++;
    notifyListeners();
    final source = socket.remoteAddress.address;
    final pending = BytesBuilder(copy: false);
    late final EscPosParser parser;
    parser = EscPosParser(
      onCut: (elements) {
        final raw = pending.takeBytes();
        _addReceipt(Receipt(elements, source, raw));
      },
      respond: (bytes) {
        try {
          socket.add(bytes);
        } catch (_) {}
      },
    );
    socket.listen(
      (data) {
        pending.add(data);
        parser.add(data);
      },
      onDone: () {
        parser.flush();
        _close(socket);
      },
      onError: (_) => _close(socket),
      cancelOnError: true,
    );
  }

  void _onStatusClient(Socket socket) {
    void reply() {
      try {
        socket.add(longStatusOk);
      } catch (_) {}
    }

    reply();
    socket.listen((_) => reply(), onDone: socket.destroy, onError: (_) => socket.destroy(), cancelOnError: true);
  }

  void _close(Socket s) {
    if (!_clients.remove(s)) return;
    activeConnections--;
    s.destroy();
    notifyListeners();
  }

  void _addReceipt(Receipt r) {
    if (r.elements.isEmpty) return;
    receipts.insert(0, r);
    if (receipts.length > 200) receipts.removeLast();
    _received.add(r);
    notifyListeners();
    unawaited(_saveRaw(r));
  }

  /// Folder with the raw bytes of recent receipts, for debugging printer drivers.
  static Future<Directory> rawDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}printer_raw').create();

  static String rawName(Receipt r) =>
      'receipt_${r.time.toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}_${r.source}_${r.raw.length}.bin';

  Future<void> _saveRaw(Receipt r) async {
    try {
      final dir = await rawDir();
      await File('${dir.path}${Platform.pathSeparator}${rawName(r)}').writeAsBytes(r.raw);
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      for (final (i, f) in files.indexed) {
        if (i >= _keepReceipts || f.lastModifiedSync().isBefore(cutoff)) f.deleteSync();
      }
    } catch (_) {}
  }

  void clear() {
    receipts.clear();
    notifyListeners();
  }

  /// This machine's IPs to enter in the POS printer settings.
  static Future<List<String>> localIps() async {
    final nics = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final n in nics)
        if (!n.name.toLowerCase().contains('vethernet') && !n.name.toLowerCase().contains('loopback'))
          for (final a in n.addresses)
            if (!a.isLoopback) a.address,
    ];
  }

  /// Sends a sample receipt to ourselves to check the emulator works.
  Future<void> sendSample() async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    s.add(sampleReceipt());
    await s.flush();
    await s.close();
  }

  @override
  void dispose() {
    stop();
    _received.close();
    super.dispose();
  }
}

List<int> sampleReceipt() {
  List<int> t(String s) => s.codeUnits;
  const esc = 0x1B, gs = 0x1D, lf = 0x0A;
  final qr = 'https://example.com/receipt/T-1024'.codeUnits;
  final qrLen = qr.length + 3;
  return [
    esc,
    0x40,
    esc,
    0x61,
    1,
    gs,
    0x21,
    0x11,
    ...t('SAMPLE STORE'),
    lf,
    gs,
    0x21,
    0x00,
    ...t('1 Main St, Springfield'),
    lf,
    ...t('Tel 555-0101'),
    lf,
    lf,
    esc,
    0x61,
    0,
    ...t('Ticket #1024        31/10/2026 22:40'),
    lf,
    ...t('Cashier: Rina          Station 1'),
    lf,
    ...t('-' * 48),
    lf,
    ...t('Bug fix (works on my machine)       1    150,000'),
    lf,
    ...t('Rubber duck consultation            1    450,000'),
    lf,
    ...t('Coffee (debugging fuel)             4     90,000'),
    lf,
    ...t('-' * 48),
    lf,
    esc,
    0x45,
    1,
    ...t('TOTAL                                  690,000'),
    lf,
    esc,
    0x45,
    0,
    ...t('VISA **** 4242                         690,000'),
    lf,
    lf,
    esc,
    0x61,
    1,
    gs,
    0x28,
    0x6B,
    3,
    0,
    49,
    67,
    6,
    gs,
    0x28,
    0x6B,
    qrLen & 0xFF,
    qrLen >> 8,
    49,
    80,
    48,
    ...qr,
    gs,
    0x28,
    0x6B,
    3,
    0,
    49,
    81,
    48,
    lf,
    ...t('Thank you! No bugs were harmed'),
    lf,
    ...t('in the printing of this receipt.'),
    lf,
    esc,
    0x64,
    3,
    esc,
    0x70,
    0,
    25,
    250,
    gs,
    0x56,
    66,
    0,
  ];
}
