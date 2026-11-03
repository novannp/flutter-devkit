import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// The Android notices are too long for the licenses page, and ship as files beside these.
const bundledLicenses = [
  ('Slipway', 'LICENSE'),
  ('Third-party notices', 'THIRD_PARTY_NOTICES.md'),
  ('scrcpy, Android Debug Bridge', 'assets/licenses/Apache-2.0.txt'),
  ('FFmpeg, libusb', 'assets/licenses/LGPL-2.1.txt'),
  ('SDL2', 'assets/licenses/Zlib.txt'),
];

class Credit {
  const Credit(this.name, this.by, this.license, this.url, {this.asset});

  final String name, by, license, url;

  /// The license text inside the app, for what ships with it.
  final String? asset;
}

const shippedCredits = [
  Credit('scrcpy', 'Genymobile and Romain Vimont', 'Apache-2.0', 'https://github.com/Genymobile/scrcpy', asset: 'assets/licenses/Apache-2.0.txt'),
  Credit('Android Debug Bridge', 'The Android Open Source Project', 'Apache-2.0', 'https://android.googlesource.com/platform/packages/modules/adb', asset: 'assets/licenses/Apache-2.0.txt'),
  Credit('FFmpeg', 'The FFmpeg developers', 'LGPL-2.1-or-later', 'https://ffmpeg.org', asset: 'assets/licenses/LGPL-2.1.txt'),
  Credit('libusb', 'The libusb project', 'LGPL-2.1-or-later', 'https://github.com/libusb/libusb', asset: 'assets/licenses/LGPL-2.1.txt'),
  Credit('SDL2', 'Sam Lantinga', 'Zlib', 'https://github.com/libsdl-org/SDL', asset: 'assets/licenses/Zlib.txt'),
];

/// Not part of the app: it starts the copies you installed yourself.
const installedCredits = [
  Credit('Flutter SDK', 'The Flutter authors', 'BSD-3-Clause', 'https://github.com/flutter/flutter'),
  Credit('Dart SDK', 'The Dart project authors', 'BSD-3-Clause', 'https://github.com/dart-lang/sdk'),
  Credit('FVM', 'Leo Farias and contributors', 'MIT', 'https://github.com/btwld/fvm'),
  Credit('FlutterFire CLI', 'Invertase and contributors', 'Apache-2.0', 'https://github.com/invertase/flutterfire_cli'),
  Credit('Firebase CLI', 'Firebase and contributors', 'MIT', 'https://github.com/firebase/firebase-tools'),
  Credit('Claude Code', 'Anthropic', "Anthropic's terms", 'https://claude.com/claude-code'),
];

/// Flutter lists the Dart packages by itself; the programs shipped beside them need adding.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, asset) in bundledLicenses) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(asset));
    }
  });
}
