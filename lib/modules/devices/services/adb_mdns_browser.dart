import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'adb_service.dart';

/// Native mDNS browse for Android wireless debugging services (connect + pairing).
class AdbMdnsBrowser {
  static const _types = ['_adb-tls-connect._tcp', '_adb-tls-pairing._tcp'];

  final _found = <String, AdbMdnsService>{};
  final _discoveries = <BonsoirDiscovery>[];
  Future<void>? _starting;

  List<AdbMdnsService> get services => _found.values.toList();

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    for (final type in _types) {
      try {
        final d = BonsoirDiscovery(type: type, printLogs: false);
        await d.initialize();
        d.eventStream!.listen((event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent(:final service):
              d.serviceResolver.resolveService(service);
            case BonsoirDiscoveryServiceResolvedEvent(:final service):
            case BonsoirDiscoveryServiceUpdatedEvent(:final service):
              final ip = service.hostAddresses.where((a) => !a.contains(':')).firstOrNull;
              if (ip == null) return;
              _found['$type|${service.name}'] = AdbMdnsService(service.name, type, ip, service.port);
            case BonsoirDiscoveryServiceLostEvent(:final service):
              _found.remove('$type|${service.name}');
            default:
          }
        });
        await d.start();
        _discoveries.add(d);
      } catch (_) {
        // Firewall/Bonjour issues shouldn't break adb's own discovery.
      }
    }
  }
}
