import 'dart:io';

import 'package:hotrestart/modules/console/console_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ptyArgument quotes only what needs it on Windows', () {
    expect(ptyArgument('--login'), '--login');
    expect(ptyArgument('"already quoted"'), '"already quoted"');
    expect(ptyArgument(r'C:\Program Files\Git\bin\bash.exe'), Platform.isWindows ? r'"C:\Program Files\Git\bin\bash.exe"' : r'C:\Program Files\Git\bin\bash.exe');
  });
}
