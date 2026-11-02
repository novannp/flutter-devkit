import 'dart:io';

import 'package:devkit/modules/editor/source_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('parseStatus reads renames, untracked files and spaces', () {
    final changes = parseStatus('M  a b.dart\u0000R  new.dart\u0000old.dart\u0000?? lib/x.dart\u0000 D gone.dart\u0000');
    expect(changes.map((c) => c.path), ['a b.dart', 'new.dart', 'lib/x.dart', 'gone.dart']);
    expect(changes[0].staged, isTrue);
    expect(changes[0].unstaged, isFalse);
    expect(changes[1].from, 'old.dart');
    expect(changes[2].untracked, isTrue);
    expect(changes[2].staged, isFalse);
    expect(changes[3].unstaged, isTrue);
  });

  test('parseMarks tells added, modified and deleted lines apart', () {
    const diff = '''
diff --git a/a b/a
@@ -2 +2 @@ one
-old
+new
@@ -5,0 +6,2 @@
+x
+y
@@ -9,2 +11,3 @@
-a
-b
+c
+d
+e
@@ -20,3 +22,0 @@
-gone
''';
    expect(parseMarks(diff), {
      1: GitMark.modified,
      5: GitMark.added,
      6: GitMark.added,
      10: GitMark.modified,
      11: GitMark.modified,
      12: GitMark.added,
      21: GitMark.deleted,
    });
  });

  test('parseDiff numbers lines in the new file', () {
    final lines = parseDiff('diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n keep\n-old\n+new\n tail\n');
    expect(lines.map((l) => l.kind), [
      DiffKind.header,
      DiffKind.header,
      DiffKind.header,
      DiffKind.hunk,
      DiffKind.context,
      DiffKind.removed,
      DiffKind.added,
      DiffKind.context,
    ]);
    expect(lines[4].line, 0);
    expect(lines[5].line, isNull);
    expect(lines[6].line, 1);
    expect(lines[7].line, 2);
  });

  test('stages, diffs, commits, branches and discards in a real repo', () async {
    final dir = await Directory.systemTemp.createTemp('devkit_git');
    addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
    Future<void> git(List<String> args) async {
      final r = await Process.run('git', args, workingDirectory: dir.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await git(['init', '-b', 'main']);
    await git(['config', 'user.email', 'test@example.com']);
    await git(['config', 'user.name', 'Test']);
    await git(['config', 'core.autocrlf', 'false']);
    final file = File(p.join(dir.path, 'a file.txt'));
    await file.writeAsString('one\ntwo\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'first']);

    final sc = SourceControl();
    addTearDown(sc.dispose);
    await sc.open(dir.path);
    expect(sc.isRepo, isTrue);
    expect(sc.branch, 'main');
    expect(sc.changes, isEmpty);

    await file.writeAsString('one\nTWO\nthree\n');
    final extra = File(p.join(dir.path, 'new.txt'));
    await extra.writeAsString('fresh\n');
    await sc.refresh();
    expect(sc.unstaged.map((c) => c.path), containsAll(['a file.txt', 'new.txt']));
    expect(await sc.marksOf(file.path), {1: GitMark.modified, 2: GitMark.added});

    final tracked = sc.unstaged.firstWhere((c) => c.path == 'a file.txt');
    final diff = await sc.diffOf(tracked, staged: false);
    expect(diff.where((l) => l.kind == DiffKind.added).map((l) => l.text), ['+TWO', '+three']);
    expect((await sc.diffOf(sc.unstaged.firstWhere((c) => c.untracked), staged: false)).single.text, '+fresh');

    expect(await sc.stage([tracked]), isTrue);
    expect(sc.staged.single.path, 'a file.txt');
    expect(await sc.unstage(sc.staged), isTrue);
    expect(sc.staged, isEmpty);
    expect(await sc.stage(sc.unstaged.where((c) => c.path == 'a file.txt').toList()), isTrue);

    // Without a shell these reach git as they are.
    const message = 'fix & "quote" | 100% ^ done';
    expect(await sc.commit(message), isTrue);
    final log = await Process.run('git', ['log', '-1', '--format=%s'], workingDirectory: dir.path);
    expect((log.stdout as String).trim(), message);
    expect(await sc.marksOf(file.path), isEmpty);

    expect(await sc.switchTo('feature/x', create: true), isTrue);
    expect(sc.branch, 'feature/x');
    expect(await sc.branches(), containsAll(['main', 'feature/x']));

    await file.writeAsString('thrown away\n');
    await sc.refresh();
    expect(await sc.discard(sc.changes.firstWhere((c) => c.path == 'a file.txt')), isTrue);
    expect(await file.readAsString(), 'one\nTWO\nthree\n');
    expect(await sc.discard(sc.changes.firstWhere((c) => c.untracked)), isTrue);
    expect(extra.existsSync(), isFalse);
    expect(sc.changes, isEmpty);

    expect(await sc.commit('nothing to commit'), isFalse);
    expect(sc.error, isNotNull);
  });

  test('a folder outside any repo reports that, without errors', () async {
    final dir = await Directory.systemTemp.createTemp('devkit_nogit');
    addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
    final sc = SourceControl();
    addTearDown(sc.dispose);
    await sc.open(dir.path);
    expect(sc.isRepo, isFalse);
    expect(await sc.marksOf(p.join(dir.path, 'a.dart')), isEmpty);
  });
}
