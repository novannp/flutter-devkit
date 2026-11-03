import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// TXT record contract broadcast by apps that opt in: app (package), version, serial, model, env, adb_port.
class MdnsService {
  static const defaultServiceType = '_hotrestart._tcp';
  static const serviceTypeKey = 'mdns_service_type';

  static bool isValidType(String type) => RegExp(r'^_[a-z0-9-]+\._(tcp|udp)$').hasMatch(type);

  static Future<String> serviceType() async {
    final saved = (await SharedPreferences.getInstance()).getString(serviceTypeKey);
    return saved != null && isValidType(saved) ? saved : defaultServiceType;
  }

  BonsoirDiscovery? _discovery;
  StreamSubscription? _sub;

  Future<void> start({
    required void Function(String serviceName, Device device) onFound,
    required void Function(String serviceName) onLost,
  }) async {
    final discovery = BonsoirDiscovery(type: await serviceType(), printLogs: false);
    await discovery.initialize();
    _sub = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          discovery.serviceResolver.resolveService(service);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          final ip = service.hostAddresses.where((a) => !a.contains(':')).firstOrNull;
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
