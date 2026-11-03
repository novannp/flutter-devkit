import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const bundledLicenses = [
  ('Flutter DevKit', 'LICENSE'),
  ('Third-party notices', 'THIRD_PARTY_NOTICES.md'),
  ('scrcpy, Android Debug Bridge', 'assets/licenses/Apache-2.0.txt'),
  ('FFmpeg, libusb', 'assets/licenses/LGPL-2.1.txt'),
];

/// Flutter lists the Dart packages by itself; the programs shipped beside them need adding.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, asset) in bundledLicenses) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(asset));
    }
  });
}
