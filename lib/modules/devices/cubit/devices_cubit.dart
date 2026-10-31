import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/device.dart';
import '../services/adb_service.dart';
import '../services/demo_devices.dart';
import '../services/device_adb.dart';
import '../services/device_store.dart';
import '../services/mdns_service.dart';
import '../services/network_scanner.dart';

class DevicesState extends Equatable {
  const DevicesState({
    this.devices = const [],
    this.query = '',
    this.scanning = false,
    this.scanProgress = 0,
    this.demo = false,
    this.adbAvailable = true,
    this.scrcpyAvailable = true,
  });

  final List<Device> devices;
  final String query;
  final bool scanning;
  final double scanProgress;
  final bool demo;
  final bool adbAvailable;
  final bool scrcpyAvailable;

  List<Device> get filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return devices;
    return devices
        .where((d) => [
              d.name,
              d.serial,
              d.ip,
              d.model,
              d.env,
              for (final e in d.apps.entries) ...[appName(e.key), e.value],
            ].any((v) => v?.toLowerCase().contains(q) ?? false))
        .toList();
  }

  int get onlineCount => devices.where((d) => d.online).length;
  int get adbCount => devices.where((d) => d.adb == AdbState.connected).length;

  DevicesState copyWith({
    List<Device>? devices,
    String? query,
    bool? scanning,
    double? scanProgress,
    bool? demo,
    bool? adbAvailable,
    bool? scrcpyAvailable,
  }) =>
      DevicesState(
        devices: devices ?? this.devices,
        query: query ?? this.query,
        scanning: scanning ?? this.scanning,
        scanProgress: scanProgress ?? this.scanProgress,
        demo: demo ?? this.demo,
        adbAvailable: adbAvailable ?? this.adbAvailable,
        scrcpyAvailable: scrcpyAvailable ?? this.scrcpyAvailable,
      );

  @override
  List<Object?> get props =>
      [devices, query, scanning, scanProgress, demo, adbAvailable, scrcpyAvailable];
}

class DevicesCubit extends Cubit<DevicesState> {
  DevicesCubit({
    required this.adb,
    required this.mdns,
    required this.scanner,
    required this.store,
  }) : super(DevicesState(
          adbAvailable: adb.available,
          scrcpyAvailable: adb.tools.scrcpy != null,
        ));

  final AdbService adb;
  final MdnsService mdns;
  final NetworkScanner scanner;
  final DeviceStore store;

  final _devices = <String, Device>{};
  final _mdnsNames = <String, String>{};
  Timer? _adbPoll;

  Future<void> init() async {
    for (final d in await store.load()) {
      _devices[d.id] = d;
    }
    _emit();
    try {
      await mdns.start(onFound: _onMdnsFound, onLost: _onMdnsLost);
    } catch (_) {
      // mDNS failing (e.g. blocked by firewall) must not stop the other sources.
    }
    await refreshAdb();
    _adbPoll = Timer.periodic(const Duration(seconds: 10), (_) => refreshAdb());
  }

  void search(String query) => emit(state.copyWith(query: query));

  void toggleDemo() {
    emit(state.copyWith(demo: !state.demo));
    _emit();
  }

  void _onMdnsFound(String serviceName, Device device) {
    _mdnsNames[serviceName] = device.id;
    _upsert(device);
  }

  void _onMdnsLost(String serviceName) {
    final id = _mdnsNames.remove(serviceName);
    final d = _devices[id];
    if (d == null) return;
    final sources = {...d.sources}..remove(DeviceSource.mdns);
    _devices[d.id] = d.copyWith(sources: sources, online: sources.isNotEmpty);
    _emit();
  }

  void _upsert(Device incoming) {
    final existing = _devices.values
            .where((d) => incoming.serial != null && d.serial == incoming.serial)
            .firstOrNull ??
        _devices.values
            .where((d) => incoming.ip != null && d.ip == incoming.ip && d.serial == null)
            .firstOrNull;
    var merged = existing?.merge(incoming) ?? incoming;
    if (existing != null) _devices.remove(existing.id);
    if (merged.ip != null) {
      for (final d in _devices.values.where((d) => d.ip == merged.ip).toList()) {
        if (d.serial == null) {
          // An older IP-only entry turns out to be the same device.
          _devices.remove(d.id);
          merged = d.merge(merged);
        } else {
          // The IP has moved to another device (DHCP).
          _devices[d.id] = d.copyWith(online: false, adb: AdbState.offline);
        }
      }
    }
    _devices[merged.id] = merged;
    _emit();
    store.save(_devices.values);
  }

  // Our app list only needs fetching once per device per session; the ADB poll runs every 10s.
  final _appsFetched = <String>{};

  Future<Map<String, String>> _ourApps(String target) async {
    try {
      return await DeviceAdb(adb, target).ourApps();
    } catch (_) {
      return const {};
    }
  }

  final _wirelessTried = <String, DateTime>{};

  /// Serials/IPs the user disconnected on purpose; don't auto-connect until a manual Connect.
  final _manualOff = <String>{};

  /// Wireless debugging targets seen via mDNS that fail to connect (not yet paired with this laptop).
  final _unpaired = <String>{};

  /// Android 11+ wireless debugging uses a random port, so it's discovered via adb mDNS and then connected.
  /// Returns ids of devices that are visible but need pairing, so they stay in the list.
  Future<Set<String>> _discoverWireless(List<AdbEntry> entries) async {
    final connected = entries.where((e) => e.state == AdbState.connected).map((e) => e.target).toSet();
    final needPair = <String>{};
    for (final s in (await adb.mdnsServices()).where((s) => s.isConnect)) {
      if (connected.contains(s.target)) {
        _unpaired.remove(s.target);
        continue;
      }
      if (_manualOff.contains(s.serial) || _manualOff.contains(s.ip)) continue;
      final last = _wirelessTried[s.target];
      if (last == null || DateTime.now().difference(last) >= const Duration(seconds: 30)) {
        _wirelessTried[s.target] = DateTime.now();
        if (await adb.connect(s.target)) {
          _unpaired.remove(s.target);
          _upsert(Device(
            id: Device.keyOf(serial: s.serial, ip: s.ip),
            serial: s.serial,
            ip: s.ip,
            adbPort: s.port,
            online: true,
            lastSeen: DateTime.now(),
            sources: const {DeviceSource.scan},
          ));
          continue;
        }
        _unpaired.add(s.target);
      }
      if (!_unpaired.contains(s.target)) continue;
      final device = Device(
        id: Device.keyOf(serial: s.serial, ip: s.ip),
        serial: s.serial,
        ip: s.ip,
        adbPort: s.port,
        adb: AdbState.unpaired,
        online: true,
        lastSeen: DateTime.now(),
        sources: const {DeviceSource.scan},
      );
      _upsert(device);
      needPair.add(_devices.values.where((d) => d.serial == s.serial && s.serial != null).firstOrNull?.id ?? device.id);
    }
    return needPair;
  }

  /// Called after pairing so the device shows up right away without waiting for the poll.
  Future<void> refreshNow() async {
    _wirelessTried.clear();
    await refreshAdb();
  }

  Future<void> refreshAdb() async {
    if (!adb.available) return;
    final needPair = await _discoverWireless(await adb.devices());
    final entries = await adb.devices();
    final seen = <String>{...needPair};
    for (final e in entries) {
      final match = _devices.values.where((d) => d.adbTarget == e.target || (!e.isNetwork && d.serial == e.target)).firstOrNull;
      if (match != null) {
        seen.add(match.id);
        final apps = e.state == AdbState.connected && _appsFetched.add(match.id) ? await _ourApps(e.target) : null;
        _devices[match.id] = match.copyWith(adb: e.state, online: true, apps: apps == null ? null : {...match.apps, ...apps});
        continue;
      }
      if (e.state != AdbState.connected) continue;
      final serial = e.isNetwork ? await adb.getprop(e.target, 'ro.serialno') : e.target;
      final device = Device(
        id: Device.keyOf(serial: serial, ip: e.ip),
        serial: serial,
        ip: e.ip,
        adbPort: e.port,
        model: e.model,
        apps: await _ourApps(e.target),
        adb: e.state,
        online: true,
        lastSeen: DateTime.now(),
        sources: {e.isNetwork ? DeviceSource.scan : DeviceSource.usb},
      );
      _appsFetched.add(device.id);
      _upsert(device);
      seen.add(device.id);
    }
    for (final d in _devices.values.toList()) {
      if (seen.contains(d.id)) continue;
      final viaMdns = d.sources.contains(DeviceSource.mdns);
      if (d.adb != AdbState.unknown || d.online != viaMdns) {
        _devices[d.id] = d.copyWith(adb: AdbState.unknown, online: viaMdns);
      }
    }
    _emit();
  }

  Future<String> scanNetwork() async {
    if (state.scanning) return 'Scan already running';
    if (state.demo) return '(demo) scan skipped';
    emit(state.copyWith(scanning: true, scanProgress: 0));
    var found = 0;
    try {
      await for (final ip in scanner.scan(
        5555,
        onProgress: (done, total) => emit(state.copyWith(scanProgress: done / total)),
      )) {
        found++;
        final target = '$ip:5555';
        await adb.connect(target);
        final serial = await adb.getprop(target, 'ro.serialno');
        final model = await adb.getprop(target, 'ro.product.model');
        _upsert(Device(
          id: Device.keyOf(serial: serial, ip: ip),
          serial: serial,
          ip: ip,
          model: model,
          apps: await _ourApps(target),
          online: true,
          lastSeen: DateTime.now(),
          sources: const {DeviceSource.scan},
        ));
      }
    } finally {
      emit(state.copyWith(scanning: false, scanProgress: 1));
    }
    await refreshNow();
    final wireless = (await adb.mdnsServices()).where((s) => s.isConnect).length;
    final unpaired = state.devices.where((d) => d.adb == AdbState.unpaired).length;
    final subnets = (await scanner.localAddresses())
        .map((a) => '${a.address.substring(0, a.address.lastIndexOf('.'))}.x')
        .toSet();
    if (subnets.isEmpty) return 'No local network found — connect to Wi-Fi/LAN first';
    return 'Scanned ${subnets.join(', ')}: $found on port 5555 · $wireless with wireless debugging'
        '${unpaired > 0 ? ' · $unpaired need pairing' : ''}';
  }

  Future<String> connect(Device d) async {
    if (state.demo) return '(demo) connect ${d.displayName}';
    final target = d.adbTarget;
    if (target == null) return 'IP unknown';
    _manualOff.removeAll([d.serial, d.ip]);
    await adb.connect(target);
    // The wireless debugging port may have changed; rediscover via mDNS.
    await refreshNow();
    final now = _devices.values.where((x) => x.serial == d.serial && d.serial != null).firstOrNull ?? _devices[d.id];
    if (now?.adb == AdbState.unauthorized) return 'Allow USB debugging on ${d.displayName}';
    return now?.adb == AdbState.connected ? 'Connected to ${d.displayName}' : 'Failed to connect to $target';
  }

  Future<String> connectTarget(String target) async {
    if (state.demo) return '(demo) connect $target';
    final ip = target.split(':').first;
    _manualOff.remove(ip);
    if (!await adb.connect(target)) {
      return 'Failed to connect to $target — pair it first if it uses Wireless debugging';
    }
    await refreshNow();
    final d = _devices.values.where((x) => x.ip == ip).firstOrNull;
    if (d?.adb == AdbState.unauthorized) return 'Allow USB debugging on the device';
    return 'Connected to ${d?.displayName ?? target}';
  }

  Future<String> disconnect(Device d) async {
    if (state.demo) return '(demo) disconnect ${d.displayName}';
    final target = d.adbTarget;
    if (target == null || d.ip == null) return '${d.displayName} is on USB, unplug the cable to disconnect';
    _manualOff.addAll([d.serial, d.ip].nonNulls);
    await adb.disconnect(target);
    await refreshAdb();
    return '${d.displayName} disconnected';
  }

  Future<String> disconnectAll() async {
    if (state.demo) return '(demo) disconnect all';
    final targets = _devices.values.where((d) => d.ip != null && d.adb != AdbState.unknown).toList();
    for (final d in targets) {
      _manualOff.addAll([d.serial, d.ip].nonNulls);
      await adb.disconnect(d.adbTarget!);
    }
    await refreshAdb();
    return '${targets.length} device(s) disconnected';
  }

  Future<String> connectAll() async {
    if (state.demo) return '(demo) connect all';
    _manualOff.clear();
    final targets = _devices.values.where((d) => d.ip != null && d.adb != AdbState.connected).toList();
    await Future.wait(targets.map((d) => adb.connect(d.adbTarget!)));
    await refreshNow();
    return '${state.adbCount} device(s) connected';
  }

  Future<String> remote(Device d) async {
    if (state.demo) return '(demo) open screen ${d.displayName}';
    final target = d.adbTarget;
    if (target == null) return 'IP unknown';
    if (d.adb != AdbState.connected && d.ip != null) await adb.connect(target);
    return await adb.remote(target, title: d.displayName) ?? 'Opening screen of ${d.displayName}…';
  }

  void rename(Device d, String name) {
    if (state.demo) return;
    final trimmed = name.trim();
    _devices[d.id] = d.copyWith(name: trimmed, clearName: trimmed.isEmpty);
    _emit();
    store.save(_devices.values);
  }

  void forget(Device d) {
    if (state.demo) return;
    _devices.remove(d.id);
    _emit();
    store.save(_devices.values);
  }

  void _emit() {
    final list = state.demo ? demoDevices : (_devices.values.toList()..sort(_compare));
    emit(state.copyWith(devices: list));
  }

  static int _compare(Device a, Device b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  }

  @override
  Future<void> close() async {
    _adbPoll?.cancel();
    await mdns.stop();
    return super.close();
  }
}
