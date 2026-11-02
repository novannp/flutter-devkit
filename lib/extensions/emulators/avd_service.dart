import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/tools.dart';

class Avd {
  Avd({required this.name, required this.dir, required this.config});

  final String name;
  final Directory dir;
  final Map<String, String> config;

  /// adb serial (emulator-5554) while running.
  String? serial;

  String get displayName => config['avd.ini.displayname'] ?? name;
  String? get api => RegExp(r'android-(\d+)').firstMatch(config['image.sysdir.1'] ?? '')?[1];
  String? get abi => config['abi.type'];
  String? get variant =>
      (config['image.sysdir.1'] ?? '').split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).elementAtOrNull(2);
  int? get ramMb => int.tryParse(config['hw.ramSize']?.replaceAll(RegExp(r'[^\d]'), '') ?? '');
  int? get width => int.tryParse(config['hw.lcd.width'] ?? '');
  int? get height => int.tryParse(config['hw.lcd.height'] ?? '');
  int? get density => int.tryParse(config['hw.lcd.density'] ?? '');
  bool get running => serial != null;

  int get diskBytes {
    var total = 0;
    try {
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        total += f.lengthSync();
      }
    } catch (_) {}
    return total;
  }
}

class SystemImage {
  const SystemImage(this.api, this.variant, this.abi, this.relPath);

  final String api;
  final String variant;
  final String abi;

  /// e.g. `system-images\android-29\google_apis\x86_64\`
  final String relPath;

  String get label => 'Android API $api · ${variant.replaceAll('_', ' ')} · $abi';
}

/// AVD files are managed directly (no avdmanager/Java needed); the emulator binary does the rest.
String? androidSdkInFlutterSettings(String json) {
  try {
    final value = (jsonDecode(json) as Map)['android-sdk'];
    return value is String && value.isNotEmpty ? value : null;
  } on FormatException {
    return null;
  }
}

class AvdService {
  AvdService(this.tools);

  final Tools tools;
  static final _sep = Platform.pathSeparator;

  /// The folder chosen in Settings, for an SDK nothing else can find.
  static final customSdk = ValueNotifier<String?>(null);
  static const _prefCustomSdk = 'android_sdk_path';

  static Future<void> loadCustomSdk() async {
    customSdk.value = (await SharedPreferences.getInstance()).getString(_prefCustomSdk);
  }

  static Future<void> setCustomSdk(String? path) async {
    customSdk.value = path;
    final prefs = await SharedPreferences.getInstance();
    path == null ? await prefs.remove(_prefCustomSdk) : await prefs.setString(_prefCustomSdk, path);
  }

  /// What `flutter config --android-sdk` saved. Read from its file, since running flutter takes seconds.
  static String? _sdkFromFlutterConfig() {
    final env = Platform.environment;
    final file = Platform.isWindows
        ? File('${env['APPDATA']}$_sep.flutter_settings')
        : File('${env['HOME']}/.config/flutter/settings');
    try {
      return file.existsSync() ? androidSdkInFlutterSettings(file.readAsStringSync()) : null;
    } on FileSystemException {
      return null;
    }
  }

  static final _emulatorName = Platform.isWindows ? 'emulator.exe' : 'emulator';

  String? get sdkRoot {
    final env = Platform.environment;
    final candidates = [
      customSdk.value,
      env['ANDROID_HOME'],
      env['ANDROID_SDK_ROOT'],
      _sdkFromFlutterConfig(),
      if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}${_sep}Android${_sep}Sdk',
      if (Platform.isMacOS) '${env['HOME']}/Library/Android/sdk',
      // Fall back to the SDK that owns the adb we use.
      if (tools.adb != null) File(tools.adb!).parent.parent.path,
    ];
    return candidates.nonNulls.where((p) => File('$p${_sep}emulator$_sep$_emulatorName').existsSync()).firstOrNull;
  }

  String? get emulatorExe => sdkRoot == null ? null : '$sdkRoot${_sep}emulator$_sep$_emulatorName';

  Directory get avdHome {
    final env = Platform.environment;
    if (env['ANDROID_AVD_HOME'] case final p?) return Directory(p);
    final user = env['ANDROID_USER_HOME'] ?? '${env['USERPROFILE'] ?? env['HOME']}$_sep.android';
    return Directory('$user${_sep}avd');
  }

  static Map<String, String> parseIni(String text) => {
    for (final line in text.split('\n'))
      if (line.contains('=') && !line.trimLeft().startsWith('#'))
        line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
  };

  static String writeIni(Map<String, String> m) => '${m.entries.map((e) => '${e.key}=${e.value}').join('\n')}\n';

  Future<List<Avd>> list() async {
    final home = avdHome;
    if (!home.existsSync()) return [];
    final avds = <Avd>[];
    for (final ini in home.listSync().whereType<File>().where((f) => f.path.endsWith('.ini'))) {
      final name = ini.uri.pathSegments.last.replaceAll('.ini', '');
      final meta = parseIni(await ini.readAsString());
      final dir = Directory(meta['path'] ?? '${home.path}$_sep$name.avd');
      final cfg = File('${dir.path}${_sep}config.ini');
      if (!cfg.existsSync()) continue;
      avds.add(Avd(name: name, dir: dir, config: parseIni(await cfg.readAsString())));
    }
    await _attachRunning(avds);
    avds.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return avds;
  }

  Future<void> _attachRunning(List<Avd> avds) async {
    final adb = tools.adb;
    if (adb == null) return;
    final r = await Tools.run(adb, ['devices']);
    final serials = RegExp(r'^(emulator-\d+)\s+\w+', multiLine: true).allMatches(r.stdout).map((m) => m[1]!);
    for (final serial in serials) {
      final name = (await Tools.run(adb, ['-s', serial, 'emu', 'avd', 'name'])).stdout.split('\n').first.trim();
      avds.where((a) => a.name == name).firstOrNull?.serial = serial;
    }
  }

  Future<String?> start(Avd avd, {bool coldBoot = false, bool wipeData = false, bool noWindow = false}) async {
    final exe = emulatorExe;
    if (exe == null) return 'Android emulator not found — install it via Android Studio SDK Manager';
    await Process.start(exe, [
      '-avd',
      avd.name,
      if (coldBoot || wipeData) '-no-snapshot-load',
      if (wipeData) '-wipe-data',
      if (noWindow) '-no-window',
    ], mode: ProcessStartMode.detached);
    return null;
  }

  Future<void> stop(Avd avd) async {
    final adb = tools.adb;
    if (adb == null || avd.serial == null) return;
    await Tools.run(adb, ['-s', avd.serial!, 'emu', 'kill']);
  }

  /// Offline wipe: drop user data and snapshots; the emulator recreates them from the system image.
  Future<void> wipe(Avd avd) async {
    for (final e in avd.dir.listSync()) {
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final isData =
          n.startsWith('userdata-qemu') || n.startsWith('cache.img') || n == 'snapshots' || n.endsWith('.lock');
      if (isData) await e.delete(recursive: true);
    }
  }

  Future<void> delete(Avd avd) async {
    if (avd.dir.existsSync()) await avd.dir.delete(recursive: true);
    final ini = File('${avdHome.path}$_sep${avd.name}.ini');
    if (ini.existsSync()) await ini.delete();
  }

  Future<void> updateConfig(Avd avd, Map<String, String> changes) async {
    final cfg = File('${avd.dir.path}${_sep}config.ini');
    final m = parseIni(await cfg.readAsString())..addAll(changes);
    await cfg.writeAsString(writeIni(m));
  }

  List<SystemImage> systemImages() {
    final root = sdkRoot;
    if (root == null) return [];
    final base = Directory('$root${_sep}system-images');
    if (!base.existsSync()) return [];
    final out = <SystemImage>[];
    for (final apiDir in base.listSync().whereType<Directory>()) {
      final api = apiDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      for (final variantDir in apiDir.listSync().whereType<Directory>()) {
        final variant = variantDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        for (final abiDir in variantDir.listSync().whereType<Directory>()) {
          final abi = abiDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (!File('${abiDir.path}${_sep}system.img').existsSync()) continue;
          out.add(
            SystemImage(
              api.replaceAll('android-', ''),
              variant,
              abi,
              'system-images$_sep$api$_sep$variant$_sep$abi$_sep',
            ),
          );
        }
      }
    }
    out.sort((a, b) => (int.tryParse(b.api) ?? 0).compareTo(int.tryParse(a.api) ?? 0));
    return out;
  }

  Future<void> create({
    required String name,
    required String displayName,
    required SystemImage image,
    required int width,
    required int height,
    required int density,
    required int ramMb,
    required int diskGb,
  }) async {
    final home = avdHome..createSync(recursive: true);
    final dir = Directory('${home.path}$_sep$name.avd')..createSync();
    await File('${home.path}$_sep$name.ini').writeAsString(
      writeIni({
        'avd.ini.encoding': 'UTF-8',
        'path': dir.path,
        'path.rel': 'avd$_sep$name.avd',
        'target': 'android-${image.api}',
      }),
    );
    await File('${dir.path}${_sep}config.ini').writeAsString(
      writeIni({
        'AvdId': name,
        'avd.ini.displayname': displayName,
        'avd.ini.encoding': 'UTF-8',
        'abi.type': image.abi,
        'hw.cpu.arch': image.abi.startsWith('arm') ? 'arm64' : 'x86_64',
        'image.sysdir.1': image.relPath,
        'tag.id': image.variant,
        'hw.lcd.width': '$width',
        'hw.lcd.height': '$height',
        'hw.lcd.density': '$density',
        'hw.ramSize': '$ramMb',
        'disk.dataPartition.size': '${diskGb}G',
        'hw.keyboard': 'yes',
        'hw.gpu.enabled': 'yes',
        'hw.gpu.mode': 'auto',
        'hw.mainKeys': 'no',
        'hw.audioInput': 'yes',
        'showDeviceFrame': 'no',
        'fastboot.forceColdBoot': 'no',
        'PlayStore.enabled': image.variant.contains('playstore') ? 'true' : 'false',
      }),
    );
  }
}
