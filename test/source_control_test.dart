import 'dart:io';

import 'package:devkit/core/theme.dart';
import 'package:devkit/modules/editor/source_control.dart';
import 'package:devkit/modules/editor/source_control_view.dart';
import 'package:flutter/material.dart';
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

  test('parseSideBySide lines up changed blocks and keeps both line numbers', () {
    final rows = parseSideBySide('diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,4 +1,4 @@\n keep\n-old1\n-old2\n+new1\n tail\n+added\n\\ No newline at end of file\n');
    expect([for (final r in rows) (r.beforeLine, r.before, r.afterLine, r.after)], [
      (0, 'keep', 0, 'keep'),
      (1, 'old1', 1, 'new1'),
      (2, 'old2', null, ''),
      (3, 'tail', 2, 'tail'),
      (null, '', 3, 'added'),
    ]);
    expect(rows.map((r) => r.changed), [false, true, true, false, true]);
    expect(parseSideBySide('Binary files a/x and b/x differ\n'), isEmpty);
  });

  test('blame says who last touched each line', () {
    const out = '''
1111111111111111111111111111111111111111 1 1 2
author Ana Silva
author-time 1000000
summary First line
filename a.dart
\tone
1111111111111111111111111111111111111111 2 2
author Ana Silva
author-time 1000000
summary First line
filename a.dart
\ttwo
0000000000000000000000000000000000000000 3 3 1
author Not Committed Yet
author-time 2000000
summary Version of a.dart from a.dart
filename a.dart
\tthree
''';
    final blame = parseBlame(out);
    expect(blame.keys, [0, 1, 2]);
    expect(blame[1]!.author, 'Ana Silva');
    expect(blame[1]!.summary, 'First line');
    expect(blame[1]!.committed, isTrue);
    expect(blame[2]!.committed, isFalse);
    expect(blame[2]!.describe(DateTime.now()), 'Not committed yet');
  });

  test('ages read the way people say them', () {
    final now = DateTime(2026, 6, 1);
    expect(ageOf(now.subtract(const Duration(seconds: 5)), now), 'just now');
    expect(ageOf(now.subtract(const Duration(minutes: 1)), now), '1 minute ago');
    expect(ageOf(now.subtract(const Duration(hours: 3)), now), '3 hours ago');
    expect(ageOf(now.subtract(const Duration(days: 8)), now), '1 week ago');
    expect(ageOf(now.subtract(const Duration(days: 70)), now), '2 months ago');
    expect(ageOf(now.subtract(const Duration(days: 800)), now), '2 years ago');
  });

  test('a repo opened through a link keeps its marks', () async {
    final base = await Directory.systemTemp.createTemp('devkit_link');
    addTearDown(() => base.delete(recursive: true).catchError((_) => base));
    final real = await Directory(p.join(base.path, 'real')).create();
    final link = await Link(p.join(base.path, 'link')).create(real.path);
    Future<void> git(List<String> args) => Process.run('git', args, workingDirectory: real.path);

    await git(['init', '-b', 'main']);
    await git(['config', 'user.email', 'test@example.com']);
    await git(['config', 'user.name', 'Test']);
    await git(['config', 'core.autocrlf', 'false']);
    final file = File(p.join(real.path, 'a.txt'));
    await file.writeAsString('one\ntwo\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'first']);
    await file.writeAsString('one\nTWO\n');

    final sc = SourceControl();
    addTearDown(sc.dispose);
    await sc.open(link.path);
    expect(sc.top, link.path);
    expect(await sc.marksOf(p.join(link.path, 'a.txt')), {1: GitMark.modified});
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
    final diff = await sc.sideBySideOf(tracked, staged: false);
    expect([for (final r in diff) (r.before, r.after)], [('one', 'one'), ('two', 'TWO'), ('', 'three')]);
    final fresh = (await sc.sideBySideOf(sc.unstaged.firstWhere((c) => c.untracked), staged: false)).single;
    expect((fresh.beforeLine, fresh.after), (null, 'fresh'));

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

    final blame = await sc.blameOf(file.path);
    expect(blame, hasLength(3));
    expect(blame[0]!.committed, isTrue);
    expect(await sc.blameOf(p.join(dir.path, 'never tracked.txt')), isEmpty);

    await file.writeAsString('thrown away\n');
    await sc.refresh();
    expect(await sc.discard(sc.changes.firstWhere((c) => c.path == 'a file.txt')), isTrue);
    expect(await file.readAsString(), 'one\nTWO\nthree\n');
    expect(await sc.discard(sc.changes.firstWhere((c) => c.untracked)), isTrue);
    expect(extra.existsSync(), isFalse);
    expect(sc.changes, isEmpty);

    await file.writeAsString('edited\n');
    final added = File(p.join(dir.path, 'new one.txt'))..writeAsStringSync('new');
    final stagedNew = File(p.join(dir.path, 'staged new.txt'))..writeAsStringSync('new');
    await sc.refresh();
    await sc.stage(sc.changes.where((c) => c.path == 'staged new.txt').toList());
    expect(sc.changes, hasLength(3));
    expect(await sc.discardAll(), isTrue);
    expect(sc.changes, isEmpty);
    expect(await file.readAsString(), 'one\nTWO\nthree\n');
    expect(added.existsSync() || stagedNew.existsSync(), isFalse);
    final pop = await Process.run('git', ['stash', 'pop'], workingDirectory: dir.path);
    expect(pop.exitCode, 0, reason: 'a slip can be undone');
    expect(added.existsSync(), isTrue);
    expect(await file.readAsString(), 'edited\n');
    await sc.discardAll();
    await Process.run('git', ['stash', 'drop'], workingDirectory: dir.path);

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

  group('diff colors', () {
    const base = TextStyle(fontSize: 12);
    final syntax = appThemes.first.syntax;
    Set<Color?> colors(InlineSpan span) {
      final found = <Color?>{};
      span.visitChildren((s) {
        if (s is TextSpan && (s.text ?? '').trim().isNotEmpty) found.add(s.style?.color);
        return true;
      });
      return found;
    }

    test('code keeps its syntax colors', () {
      final spans = highlightDiffSide(["const a = 'x';"], '.dart', syntax, base);
      expect(colors(spans.single), containsAll([syntax.string]));
      expect(spans.single.toPlainText(), "const a = 'x';");
    });

    test('a comment carries on past a row missing on this side', () {
      final spans = highlightDiffSide(['/* open', null, 'still comment */'], '.dart', syntax, base);
      expect(colors(spans[2]), {syntax.comment});
      expect(spans[1].toPlainText(), '');
    });

    test('an unknown file type stays plain', () {
      expect(highlightDiffSide(['class A'], '.nope', syntax, base).single.toPlainText(), 'class A');
    });
  });
}
