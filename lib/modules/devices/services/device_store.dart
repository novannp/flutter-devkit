import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

// TODO: move to Firestore so device names are shared across all dev laptops.
class DeviceStore {
  static const _key = 'known_devices';

  Future<List<Device>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> save(Iterable<Device> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }
}
