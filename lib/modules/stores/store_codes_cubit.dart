import 'dart:convert';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/store_code.dart';

// TODO: move to Firestore along with device names so the whole team sees the same data.
class StoreCodesCubit extends Cubit<List<StoreCode>> {
  StoreCodesCubit() : super(const []);

  static const _key = 'store_codes';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) emit(_decode(raw));
  }

  List<StoreCode> _decode(String raw) =>
      (jsonDecode(raw) as List).map((e) => StoreCode.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> _save(List<StoreCode> codes) async {
    codes.sort((a, b) => a.storeName.toLowerCase().compareTo(b.storeName.toLowerCase()));
    emit(List.unmodifiable(codes));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(codes.map((c) => c.toJson()).toList()));
  }

  Future<void> upsert(StoreCode code) =>
      _save([...state.where((c) => c.id != code.id), code]);

  Future<void> remove(StoreCode code) => _save(state.where((c) => c.id != code.id).toList());

  StoreCode? byActivationCode(String code) =>
      state.where((c) => c.activationCode == code || c.supportCode == code).firstOrNull;

  Future<void> exportTo(String path) =>
      File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(state.map((c) => c.toJson()).toList()));

  /// Merges by id; data from the file overwrites local entries.
  Future<int> importFrom(String path) async {
    final incoming = _decode(await File(path).readAsString());
    final ids = incoming.map((c) => c.id).toSet();
    await _save([...state.where((c) => !ids.contains(c.id)), ...incoming]);
    return incoming.length;
  }
}
