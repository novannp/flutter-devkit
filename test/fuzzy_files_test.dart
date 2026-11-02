import 'package:devkit/modules/editor/fuzzy_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final root = p.join('C:', 'app');
  String file(String relative) => p.joinAll([root, ...relative.split('/')]);
  final files = [
    file('lib/features/checkout/online_payment.dart'),
    file('lib/features/checkout/online_payment_page.dart'),
    file('lib/features/checkout/payment_online_test_helper.dart'),
    file('lib/core/onboarding_page.dart'),
    file('lib/devices/view/devices_page.dart'),
    file('lib/devices/view/multi_screen_page.dart'),
    file('lib/core/OnlinePaymentService.dart'),
    file('test/online_payment_test.dart'),
    file('README.md'),
  ];
  List<String> names(String q) => rankFiles(files, root, q).map((m) => m.name).toList();

  test('a space stands in for an underscore', () {
    expect(names('online payment').first, 'online_payment.dart');
    expect(names('online payment'), containsAll(['online_payment_page.dart', 'OnlinePaymentService.dart', 'online_payment_test.dart']));
    expect(names('online payment'), isNot(contains('README.md')));
  });

  test('other spellings reach the same file', () {
    for (final q in ['online_payment', 'online-payment', 'onlinepayment', 'ONLINE PAYMENT', 'online.payment']) {
      expect(names(q).first, 'online_payment.dart', reason: q);
    }
  });

  test('words can come in any order, and abbreviate', () {
    expect(names('payment online'), contains('online_payment.dart'));
    expect(names('onpay'), contains('online_payment.dart'));
    expect(names('ops').first, 'OnlinePaymentService.dart');
  });

  test('a word can match the folder', () {
    expect(names('devices multi'), ['multi_screen_page.dart']);
    expect(names('checkout page'), contains('online_payment_page.dart'));
  });

  test('a word with no match anywhere rules the file out', () {
    expect(names('online zebra'), isEmpty);
    expect(names('   '), isEmpty);
  });

  test('the exact file name beats longer ones, and hits are the matched letters', () {
    final m = rankFiles(files, root, 'onboarding page').first;
    expect(m.name, 'onboarding_page.dart');
    expect((m.nameHits.toList()..sort()).map((i) => m.name[i]).join(), 'onboardingpage');
    expect(m.folderHits, isEmpty);
    final inFolder = matchFile('devices multi', file('lib/devices/view/multi_screen_page.dart'), root)!;
    expect(inFolder.folderHits.isNotEmpty, isTrue);
  });

  test('splitLineSuffix reads a line number', () {
    expect(splitLineSuffix('online payment:42'), ('online payment', 41));
    expect(splitLineSuffix('main.dart:3:7'), ('main.dart', 2));
    expect(splitLineSuffix('main.dart'), ('main.dart', null));
  });

  test('stays quick on a large project', () {
    final many = [for (var i = 0; i < 20000; i++) file('lib/some/deep/folder_$i/generated_widget_file_$i.dart')];
    final sw = Stopwatch()..start();
    rankFiles(many, root, 'widget file 19');
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });
}
