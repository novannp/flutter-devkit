import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class PaxInfo {
  const PaxInfo({this.model, this.serial, this.os, this.mac, required this.mode, this.message});

  final String? model;
  final String? serial;
  final String? os;
  final String? mac;
  final String mode;
  final String? message;
}

/// POSLink framing: STX cmd FS ver ETX LRC.
class PaxService {
  static const defaultPort = 10009;
  static const _stx = 0x02, _etx = 0x03, _fs = 0x1C, _ack = 0x06;

  static Uint8List _frame(List<String> fields) {
    final body = <int>[];
    for (var i = 0; i < fields.length; i++) {
      if (i > 0) body.add(_fs);
      body.addAll(ascii.encode(fields[i]));
    }
    body.add(_etx);
    final lrc = body.fold<int>(0, (a, b) => a ^ b);
    return Uint8List.fromList([_stx, ...body, lrc]);
  }

  // A00 Initialize only reads terminal info — safe to send to a live terminal.
  static final _initialize = _frame(['A00', '1.28']);

  static PaxInfo? _parse(List<int> bytes, String mode) {
    final start = bytes.indexOf(_stx);
    final end = bytes.lastIndexOf(_etx);
    if (start < 0 || end <= start) return null;
    final f = latin1.decode(bytes.sublist(start + 1, end)).split(String.fromCharCode(_fs));
    // [status, A01, version, code, message, serial, model, os, mac, ...]
    if (f.length < 5 || f[1] != 'A01') return null;
    String? at(int i) => i < f.length && f[i].trim().isNotEmpty ? f[i].trim() : null;
    return PaxInfo(serial: at(5), model: at(6), os: at(7), mac: at(8), mode: mode, message: at(4));
  }

  Future<PaxInfo?> identify(String ip, {int port = defaultPort}) async =>
      await _identifyTcp(ip, port) ?? await _identifyHttp(ip, port);

  Future<PaxInfo?> _identifyTcp(String ip, int port) async {
    Socket? s;
    try {
      s = await Socket.connect(ip, port, timeout: const Duration(seconds: 2));
      final buf = <int>[];
      final done = Completer<void>();
      s.listen(
        (d) {
          buf.addAll(d);
          if (buf.contains(_etx) && buf.length > buf.lastIndexOf(_etx) + 1 && !done.isCompleted) done.complete();
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (_) {},
      );
      s.add(_initialize);
      await done.future.timeout(const Duration(seconds: 4), onTimeout: () {});
      if (buf.isNotEmpty && buf.first != _ack && buf.first != _stx) return null;
      s.add([_ack]);
      return _parse(buf, 'TCP');
    } catch (_) {
      return null;
    } finally {
      s?.destroy();
    }
  }

  Future<PaxInfo?> _identifyHttp(String ip, int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.parse('http://$ip:$port/?${base64.encode(_initialize)}'));
      final res = await req.close().timeout(const Duration(seconds: 4));
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 4));
      return _parse(body, 'HTTP');
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
