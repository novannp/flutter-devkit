import '../../../core/equatable.dart';

enum AdbState { unknown, connected, unauthorized, unpaired, offline }

enum DeviceSource { mdns, scan, usb }

class Device extends Equatable {
  const Device({
    required this.id,
    this.serial,
    this.name,
    this.ip,
    this.adbPort = 5555,
    this.model,
    this.apps = const {},
    this.env,
    this.adb = AdbState.unknown,
    this.online = false,
    this.lastSeen,
    this.sources = const {},
  });

  final String id;
  final String? serial;
  final String? name;
  final String? ip;
  final int adbPort;
  final String? model;

  /// package → versionName, from our apps that are installed/broadcasting.
  final Map<String, String> apps;
  final String? env;
  final AdbState adb;
  final bool online;
  final DateTime? lastSeen;
  final Set<DeviceSource> sources;

  String get displayName => name ?? model ?? ip ?? id;

  String? get adbTarget => ip != null ? '$ip:$adbPort' : serial;

  static String keyOf({String? serial, String? ip}) => serial ?? ip!;

  /// Non-null fields from [other] override this device's.
  Device merge(Device other) => Device(
    id: keyOf(serial: other.serial ?? serial, ip: other.ip ?? ip),
    serial: other.serial ?? serial,
    name: other.name ?? name,
    ip: other.ip ?? ip,
    adbPort: other.ip != null ? other.adbPort : adbPort,
    model: other.model ?? model,
    apps: {...apps, ...other.apps},
    env: other.env ?? env,
    adb: other.adb != AdbState.unknown ? other.adb : adb,
    online: other.online || online,
    lastSeen: other.lastSeen ?? lastSeen,
    sources: {...sources, ...other.sources},
  );

  Device copyWith({
    String? name,
    Map<String, String>? apps,
    AdbState? adb,
    bool? online,
    Set<DeviceSource>? sources,
    bool clearName = false,
  }) => Device(
    id: id,
    serial: serial,
    name: clearName ? null : (name ?? this.name),
    ip: ip,
    adbPort: adbPort,
    model: model,
    apps: apps ?? this.apps,
    env: env,
    adb: adb ?? this.adb,
    online: online ?? this.online,
    lastSeen: lastSeen,
    sources: sources ?? this.sources,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'serial': serial,
    'name': name,
    'ip': ip,
    'adbPort': adbPort,
    'model': model,
    'apps': apps,
    'env': env,
    'lastSeen': lastSeen?.toIso8601String(),
  };

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    id: json['id'] as String,
    serial: json['serial'] as String?,
    name: json['name'] as String?,
    ip: json['ip'] as String?,
    adbPort: json['adbPort'] as int? ?? 5555,
    model: json['model'] as String?,
    apps: Map<String, String>.from(json['apps'] as Map? ?? {}),
    env: json['env'] as String?,
    lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? ''),
  );

  @override
  List<Object?> get props => [id, serial, name, ip, adbPort, model, apps, env, adb, online, lastSeen, sources];
}
