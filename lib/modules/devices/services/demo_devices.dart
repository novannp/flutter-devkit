import '../../../core/apps.dart';
import '../models/device.dart';

final demoDevices = List.generate(28, (i) {
  final n = i + 1;
  final isSunbay = n % 7 == 0;
  final online = n % 9 != 0;
  final model = isSunbay ? 'Sunbay P2' : (n.isEven ? 'Sunmi T2s' : 'Sunmi D3 Mini');
  return Device(
    id: 'DEMO$n',
    serial: isSunbay ? null : 'T2S${(48210 + n * 37)}',
    name: isSunbay ? 'Sunbay-${n ~/ 7}' : 'T2-${n.toString().padLeft(2, '0')}',
    ip: '192.168.1.${20 + n}',
    model: model,
    apps: isSunbay
        ? const {}
        : {
            knownApps[0].package: n % 5 == 0 ? '3.0.19' : '3.0.20',
            if (n % 3 == 0) knownApps[1].package: '2.4.1',
            if (n % 4 == 1) knownApps[n % knownApps.length].package: '1.${n % 6}.0',
          },
    env: isSunbay ? null : (n % 4 == 0 ? 'prod' : 'qa'),
    adb: !online
        ? AdbState.offline
        : isSunbay
        ? AdbState.unknown
        : (n % 6 == 0 ? AdbState.unauthorized : AdbState.connected),
    online: online,
    lastSeen: DateTime.now().subtract(Duration(minutes: online ? 0 : n * 13)),
    sources: {isSunbay ? DeviceSource.scan : DeviceSource.mdns},
  );
});
