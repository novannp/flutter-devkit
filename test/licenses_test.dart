import 'dart:io';

import 'package:slipway/core/licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every license the app claims to carry is there, and in the bundle', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final (_, asset) in bundledLicenses) {
      expect(File(asset).existsSync(), isTrue, reason: asset);
    }
    expect(pubspec, contains('- LICENSE'));
    expect(pubspec, contains('- THIRD_PARTY_NOTICES.md'));
    expect(pubspec, contains('- assets/licenses/'));
  });

  test('adb carries its notices, and the LGPL source is offered at the versions shipped', () {
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    final release = File('.github/workflows/release.yml').readAsStringSync();
    for (final name in ['windows', 'macos']) {
      final file = 'assets/licenses/android-platform-tools-NOTICE-$name.txt';
      expect(File(file).existsSync(), isTrue, reason: file);
      expect(notices, contains(file));
    }
    for (final (name, version) in [('ffmpeg', '7.1.1'), ('libusb', '1.0.29')]) {
      expect(notices, contains(version), reason: name);
      expect(release, contains('assets/$name-$version'), reason: name);
    }
  });

  test('every program credited in the app is in the notices too', () {
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    for (final c in [...shippedCredits, ...installedCredits]) {
      expect(notices, contains(c.name), reason: c.name);
      if (c.asset != null) expect(File(c.asset!).existsSync(), isTrue, reason: c.asset);
    }
    expect(notices, contains('Leo Farias'));
  });

  test('no product name or logo borrows from the Flutter or Dart marks', () {
    expect(Directory('assets/fonts').existsSync(), isFalse);
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      expect(file.readAsStringSync(), isNot(contains('Icons.flutter_dash')), reason: file.path);
    }
  });

  test('every library next to scrcpy is accounted for', () {
    final notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync().toLowerCase();
    for (final name in ['scrcpy', 'adb', 'avcodec', 'avformat', 'avutil', 'swresample', 'sdl2', 'libusb']) {
      expect(notices, contains(name));
    }
    const known = ['adb', 'scrcpy', 'avcodec', 'avformat', 'avutil', 'swresample', 'sdl2', 'libusb', 'version', 'icon'];
    for (final file in Directory('windows/third_party/scrcpy').listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last.toLowerCase();
      expect(known.any(name.startsWith), isTrue, reason: '$name is new: does it need a notice?');
    }
  });

  test('the licenses page gets them', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8Decode(message!);
      return ByteData.sublistView(File(key).readAsBytesSync());
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', null));
    registerBundledLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    expect(entries.any((e) => e.packages.contains('Slipway')), isTrue);
    expect(entries.any((e) => e.packages.contains('FFmpeg, libusb')), isTrue);
  });
}

String utf8Decode(ByteData data) => String.fromCharCodes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
