import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipway/core/theme.dart';

void main() {
  test('the version in the app and installer is the one in pubspec.yaml, and not yet 1.0', () {
    final version = RegExp(r'^version: *([0-9.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())![1]!;
    expect(appVersion, version);
    expect(File('windows/installer/setup.iss').readAsStringSync(), contains('#define AppVersion "$version"'));
    expect(version, startsWith('0.'));
  });
}
