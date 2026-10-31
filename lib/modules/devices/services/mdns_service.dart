import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import '../models/device.dart';

/// TXT record contract broadcast by each of our apps: app (package), version, serial, model, env, adb_port.
class MdnsService {
  static const serviceType = '_ravodev._tcp';

  BonsoirDiscovery? _discovery;
  StreamSubscription? _sub;

  Future<void> start({
    required void Function(String serviceName, Device device) onFound,
    required void Function(String serviceName) onLost,
  }) async {
    final discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
    await discovery.initialize();
    _sub = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          discovery.serviceResolver.resolveService(service);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          final ip = service.hostAddresses
              .where((a) => !a.contains(':'))
              .firstOrNull;
          if (ip == null) return;
          final attr = service.attributes;
          onFound(
            service.name,
            Device(
              id: Device.keyOf(serial: attr['serial'], ip: ip),
              serial: attr['serial'],
              ip: ip,
              adbPort: int.tryParse(attr['adb_port'] ?? '') ?? 5555,
              model: attr['model'],
              apps: {if (attr['app'] != null) attr['app']!: attr['version'] ?? '?'},
              env: attr['env'],
              online: true,
              lastSeen: DateTime.now(),
              sources: const {DeviceSource.mdns},
            ),
          );
        case BonsoirDiscoveryServiceLostEvent(:final service):
          onLost(service.name);
        default:
      }
    });
    await discovery.start();
    _discovery = discovery;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _discovery?.stop();
  }
}
