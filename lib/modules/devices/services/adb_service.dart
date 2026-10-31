import 'dart:async';
import 'dart:io';

import '../../../core/tools.dart';
import 'adb_mdns_browser.dart';
import '../models/device.dart';

class AdbEntry {
  const AdbEntry(this.target, this.state, this.model);

  final String target;
  final AdbState state;
  final String? model;

  bool get isNetwork => RegExp(r'^\d+\.\d+\.\d+\.\d+:\d+$').hasMatch(target);
  String? get ip => isNetwork ? target.split(':').first : null;
  int get port => isNetwork ? int.parse(target.split(':').last) : 5555;
}

class AdbMdnsService {
  const AdbMdnsService(this.name, this.type, this.ip, this.port);

  final String name;
  final String type;
  final String ip;
  final int port;

  String get target => '$ip:$port';
  bool get isConnect => type.startsWith('_adb-tls-connect');
  bool get isPairing => type.startsWith('_adb-tls-pairing');

  /// Instance name has the format `adb-<serial>-<random>`.
  String? get serial => RegExp(r'^adb-(.+)-\w+$').firstMatch(name)?[1];
}

class AdbService {
  AdbService(this.tools);

  final Tools tools;
  final _browser = AdbMdnsBrowser();

  bool get available => tools.adb != null;

  // Openscreen mDNS backend makes `adb mdns services` work on Windows (only applies when adb starts the server).
  Future<ProcessOutput> _adb(List<String> args, {Duration? timeout}) => Tools.run(
    tools.adb!,
    args,
    timeout: timeout ?? const Duration(seconds: 8),
    environment: const {'ADB_MDNS_OPENSCREEN': '1'},
  );

  Future<List<AdbEntry>> devices() async {
    if (!available) return [];
    final r = await _adb(['devices', '-l']);
    final entries = <AdbEntry>[];
    for (final line in r.stdout.split('\n').skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final state = switch (parts[1]) {
        'device' => AdbState.connected,
        'unauthorized' => AdbState.unauthorized,
        _ => AdbState.offline,
      };
      final model = parts
          .firstWhere((p) => p.startsWith('model:'), orElse: () => '')
          .replaceFirst('model:', '')
          .replaceAll('_', ' ');
      entries.add(AdbEntry(parts[0], state, model.isEmpty ? null : model));
    }
    // One phone often shows up several times (5555 + Wireless-debugging port + an mDNS name).
    // Keep one transport per IP, preferring a connected :5555, so the device list doesn't flicker.
    final best = <String, AdbEntry>{};
    int rank(AdbEntry e) => (e.state == AdbState.connected ? 2 : 0) + (e.port == 5555 ? 1 : 0);
    for (final e in entries.where((e) => e.isNetwork)) {
      final cur = best[e.ip!];
      if (cur == null || rank(e) > rank(cur)) best[e.ip!] = e;
    }
    final hasNetwork = best.values.any((e) => e.state == AdbState.connected);
    return [
      for (final e in entries)
        if (!e.isNetwork && !(hasNetwork && e.target.contains('._adb-tls-connect.')))
          e
        else if (e.isNetwork && identical(best[e.ip!], e))
          e,
    ];
  }

  /// Android 11+ wireless debugging (random port): `adb mdns services` merged with our own mDNS browse,
  /// since adb's mDNS is often empty on Windows.
  Future<List<AdbMdnsService>> mdnsServices() async {
    if (!available) return [];
    unawaited(_browser.start());
    final r = await _adb(['mdns', 'services'], timeout: const Duration(seconds: 5));
    final re = RegExp(r'^(\S+)\s+(_adb[\w-]*\._tcp)\.?\s+(\d+\.\d+\.\d+\.\d+):(\d+)');
    final all = [
      ..._browser.services,
      for (final line in r.stdout.split('\n'))
        if (re.firstMatch(line.trim()) case final m?) AdbMdnsService(m[1]!, m[2]!, m[3]!, int.parse(m[4]!)),
    ];
    return {for (final s in all) '${s.isConnect}|${s.target}': s}.values.toList();
  }

  Future<ProcessOutput> pair(String target, String code) =>
      _adb(['pair', target, code], timeout: const Duration(seconds: 20));

  /// Restarts adbd on the device listening on [port], so `adb connect ip:port` works without pairing (until reboot).
  Future<bool> tcpip(String target, {int port = 5555}) async {
    if (!available) return false;
    final r = await _adb(['-s', target, 'tcpip', '$port'], timeout: const Duration(seconds: 10));
    return '${r.stdout}${r.stderr}'.contains('restarting');
  }

  Future<bool> disconnect(String target) async {
    if (!available) return false;
    final r = await _adb(['disconnect', target]);
    return r.stdout.contains('disconnected');
  }

  Future<bool> connect(String target) async {
    if (!available) return false;
    final r = await _adb(['connect', target], timeout: const Duration(seconds: 5));
    return r.stdout.contains('connected to');
  }

  Future<String?> getprop(String target, String prop) async {
    if (!available) return null;
    final r = await _adb(['-s', target, 'shell', 'getprop', prop]);
    final v = r.stdout.trim();
    return r.ok && v.isNotEmpty ? v : null;
  }

  Future<String?> remote(String target, {required String title, List<String> options = const []}) async {
    final scrcpy = tools.scrcpy;
    if (scrcpy == null) return 'scrcpy not found in PATH';
    // Force scrcpy to use the same adb so the adb servers don't keep restarting each other.
    await Process.start(
      scrcpy,
      ['-s', target, '--window-title', title, ...options],
      environment: {if (tools.adb != null) 'ADB': tools.adb!},
      mode: ProcessStartMode.detached,
    );
    return null;
  }
}
