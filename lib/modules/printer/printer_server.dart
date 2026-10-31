import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'escpos.dart';

class Receipt {
  Receipt(this.elements, this.source, this.raw) : time = DateTime.now();

  final List<ReceiptElement> elements;
  final String source;
  final Uint8List raw;
  final DateTime time;

  String get text => elements.map((e) => switch (e) {
        TextLine() => e.plain,
        QrElement() => '[QR] ${e.data}',
        BarcodeElement() => '[BARCODE] ${e.data}',
        RasterImage() => '[IMAGE ${e.width}×${e.height}]',
        FeedElement() => '\n' * (e.lines - 1),
        EventElement() => '[${e.label}]',
      }).join('\n');

  String get title =>
      elements.whereType<TextLine>().map((l) => l.plain.trim()).firstWhere((t) => t.isNotEmpty, orElse: () => '(no text)');
}

/// Fake network printer: accepts raw ESC/POS over TCP (default 9100) like a LAN thermal printer.
class PrinterServer extends ChangeNotifier {
  static const _prefPort = 'printer_port';
  static const _prefAuto = 'printer_autostart';
  static const _prefPaper = 'printer_paper_mm';

  ServerSocket? _server;
  final receipts = <Receipt>[];
  final _clients = <Socket>{};
  int port = 9100;
  int paperMm = 80;
  bool autoStart = true;
  String? error;
  int activeConnections = 0;
  final _received = StreamController<Receipt>.broadcast();

  Stream<Receipt> get onReceipt => _received.stream;
  bool get running => _server != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    port = prefs.getInt(_prefPort) ?? 9100;
    paperMm = prefs.getInt(_prefPaper) ?? 80;
    autoStart = prefs.getBool(_prefAuto) ?? true;
    if (autoStart) await start();
    notifyListeners();
  }

  Future<void> start() async {
    if (running) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      error = null;
      _server!.listen(_onClient);
    } on SocketException catch (e) {
      error = 'Port $port unavailable (${e.osError?.message ?? e.message}). It may be in use by another app.';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
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
  final qr = 'https://ravo.app/receipt/T-1024'.codeUnits;
  final qrLen = qr.length + 3;
  return [
    esc, 0x40,
    esc, 0x61, 1, gs, 0x21, 0x11, ...t('RAVO SALON'), lf,
    gs, 0x21, 0x00, ...t('1 Main St, Springfield'), lf,
    ...t('Tel 555-0101'), lf, lf,
    esc, 0x61, 0, ...t('Ticket #1024        31/10/2026 22:40'), lf,
    ...t('Cashier: Rina          Station 1'), lf,
    ...t('-' * 48), lf,
    ...t('Haircut + Wash                   1    150,000'), lf,
    ...t('Hair Coloring                    1    450,000'), lf,
    ...t('Shampoo 250ml                    2     90,000'), lf,
    ...t('-' * 48), lf,
    esc, 0x45, 1, ...t('TOTAL                                  690,000'), lf, esc, 0x45, 0,
    ...t('VISA **** 4242                         690,000'), lf, lf,
    esc, 0x61, 1,
    gs, 0x28, 0x6B, 3, 0, 49, 67, 6,
    gs, 0x28, 0x6B, qrLen & 0xFF, qrLen >> 8, 49, 80, 48, ...qr,
    gs, 0x28, 0x6B, 3, 0, 49, 81, 48,
    lf, ...t('Thank you!'), lf,
    esc, 0x64, 3,
    esc, 0x70, 0, 25, 250,
    gs, 0x56, 66, 0,
  ];
}
