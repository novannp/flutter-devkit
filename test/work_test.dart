import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:devkit/core/secrets.dart';
import 'package:devkit/extensions/work/atlassian.dart';
import 'package:devkit/extensions/work/git_repo.dart';

void main() {
  test('ticket key from branch names', () {
    expect(ticketKeyOf('feature/POS-1234-receipt-logo'), 'POS-1234');
    expect(ticketKeyOf('bugfix/RV2-9'), 'RV2-9');
    expect(ticketKeyOf('develop'), isNull);
  });

  test('branch name from issue', () {
    final issue = JiraIssue(
      key: 'POS-12',
      summary: 'Receipt: logo is cut off on 58mm paper and other printers too',
      status: 'To Do',
      group: StatusGroup.todo,
      type: 'Bug',
      url: '',
    );
    expect(branchNameFor(issue), 'bugfix/POS-12-receipt-logo-is-cut-off-on-58mm-paper');
  });

  test('ADF round trip keeps text and bold labels', () {
    final adf = toAdf('*Device:* Tab A\n\n*App:*\n- My App 1.2');
    final para = (adf['content'] as List).first as Map;
    expect((para['content'] as List).first, {
      'type': 'text',
      'text': 'Device:',
      'marks': [
        {'type': 'strong'},
      ],
    });
    expect(adfToText(adf), 'Device: Tab A\nApp:\n- My App 1.2');
  });

  test('DPAPI encrypts and decrypts', () {
    final enc = dpapi('secret-token'.codeUnits, encrypt: true)!;
    expect(String.fromCharCodes(enc).contains('secret-token'), isFalse);
    expect(String.fromCharCodes(dpapi(enc, encrypt: false)!), 'secret-token');
  }, skip: !Platform.isWindows);
}
