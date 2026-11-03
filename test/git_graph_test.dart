import 'dart:io';

import 'package:devkit/modules/editor/git_graph.dart';
import 'package:devkit/modules/editor/source_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

GraphCommit _c(String hash, [List<String> parents = const []]) => GraphCommit(hash, parents, const [], 'a', 'now', hash);

Future<void> _git(String dir, List<String> args) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  expect(r.exitCode, 0, reason: '${args.join(' ')}: ${r.stderr}');
}

Future<void> _commit(String dir, String name) async {
  File(p.join(dir, name)).writeAsStringSync(name);
  await _git(dir, ['add', '.']);
  await _git(dir, ['commit', '-m', 'add $name']);
}

void main() {
  group('parsing', () {
    test('reads every field, and a message with odd characters', () {
      const log = 'abc123456\x1fp1 p2\x1fHEAD -> main, origin/main, tag: v1\x1fAna\x1f2 days ago\x1ffix: a, b | c\n'
          'def\x1f\x1f\x1fBo\x1fnow\x1ffirst\n\n';
      final commits = parseGraphLog(log);
      expect(commits.length, 2);
      expect(commits.first.parents, ['p1', 'p2']);
      expect(commits.first.refs, ['HEAD -> main', 'origin/main', 'tag: v1']);
      expect(commits.first.subject, 'fix: a, b | c');
      expect(commits.first.short, 'abc1234');
      expect(commits.first.branches(const ['main']), ['main']);
      expect(commits.last.parents, isEmpty);
    });

    test('anything else is skipped', () {
      expect(parseGraphLog('not a log\n\n'), isEmpty);
      expect(parseGraphLog(''), isEmpty);
    });
  });

  group('layout', () {
    test('a straight history stays in one lane', () {
      final rows = layoutGraph([_c('c', ['b']), _c('b', ['a']), _c('a')]);
      expect(rows.map((r) => r.column), [0, 0, 0]);
      expect(rows.first.above, isEmpty);
      expect(rows.first.below, [(0, true)]);
      expect(rows.last.below, isEmpty);
    });

    test('a branch and its merge take a second lane and give it back', () {
      // m merges b into a; both come from root.
      final rows = layoutGraph([_c('m', ['a', 'b']), _c('a', ['r']), _c('b', ['r']), _c('r'), ]);
      expect(rows[0].column, 0);
      expect(rows[0].below, [(0, true), (1, true)]);
      expect(rows[1].column, 0);
      expect(rows[1].above, [(0, true), (1, false)]);
      expect(rows[2].column, 1);
      expect(rows[2].below, [(0, true)], reason: 'it joins the lane already waiting for the root');
      expect(rows[3].column, 0);
      expect(rows[3].above, [(0, true)]);
      expect(rows[3].below, isEmpty);
      expect(rows.map((r) => r.width).reduce((a, b) => a > b ? a : b), 2);
    });

    test('two branch tips side by side', () {
      final rows = layoutGraph([_c('x', ['r']), _c('y', ['r']), _c('r')]);
      expect(rows[0].column, 0);
      expect(rows[1].column, 1);
      expect(rows[1].above, [(0, false)]);
      expect(rows[1].below, [(0, true)], reason: 'it joins the lane already waiting for r');
      expect(rows[2].column, 0);
    });

    test('history cut off by the limit, with parents never seen', () {
      final rows = layoutGraph([_c('c', ['gone1', 'gone2'])]);
      expect(rows.single.below.length, 2);
      expect(layoutGraph(const []), isEmpty);
    });
  });

  group('in a real repository', () {
    late Directory dir;
    late String work, remote;
    late SourceControl sc;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('graph');
      work = p.join(dir.path, 'work');
      remote = p.join(dir.path, 'remote.git');
      Directory(work).createSync();
      Directory(remote).createSync();
      await _git(remote, ['init', '--bare', '-b', 'main']);
      await _git(work, ['init', '-b', 'main']);
      await _git(work, ['config', 'user.email', 'test@example.com']);
      await _git(work, ['config', 'user.name', 'Test']);
      await _commit(work, 'a');
      sc = SourceControl();
      await sc.open(work);
    });

    tearDown(() {
      sc.dispose();
      dir.deleteSync(recursive: true);
    });

    test('the graph sees every branch', () async {
      await _git(work, ['switch', '-c', 'feature']);
      await _commit(work, 'b');
      await _git(work, ['switch', 'main']);
      await _commit(work, 'c');
      final commits = parseGraphLog(await sc.graphLog());
      expect(commits.length, 3);
      expect(commits.expand((c) => c.refs), containsAll(['HEAD -> main', 'feature']));
      final rows = layoutGraph(commits);
      expect(rows.map((r) => r.column).toSet().length, 2);
    });

    test('no remote: nothing to sync with', () async {
      await sc.refresh();
      expect((sc.hasRemote, sc.hasUpstream), (false, false));
      expect(sc.branchAction, BranchAction.none);
    });

    test('a local branch publishes, then syncs', () async {
      await _git(work, ['remote', 'add', 'origin', remote]);
      await sc.refresh();
      expect(sc.branchAction, BranchAction.publish);

      expect(await sc.sync(), isTrue, reason: sc.error);
      expect(sc.hasUpstream, isTrue);
      expect(sc.branchAction, BranchAction.sync);
      expect((sc.ahead, sc.behind), (0, 0));

      await _commit(work, 'b');
      await sc.refresh();
      expect(sc.ahead, 1);
      expect(await sc.sync(), isTrue, reason: sc.error);
      expect(sc.ahead, 0);
      final pushed = await Process.run('git', ['log', '-1', '--format=%s', 'main'], workingDirectory: remote);
      expect((pushed.stdout as String).trim(), 'add b');
    });

    test('a sync brings in what the remote has', () async {
      await _git(work, ['remote', 'add', 'origin', remote]);
      await sc.refresh();
      await sc.sync();
      final other = p.join(dir.path, 'other');
      await _git(dir.path, ['clone', remote, other]);
      await _git(other, ['config', 'user.email', 'o@example.com']);
      await _git(other, ['config', 'user.name', 'Other']);
      await _commit(other, 'theirs');
      await _git(other, ['push']);

      expect(await sc.sync(), isTrue, reason: sc.error);
      expect(File(p.join(work, 'theirs')).existsSync(), isTrue);
    });

    test('a push that fails says why', () async {
      await _git(work, ['remote', 'add', 'origin', p.join(dir.path, 'nowhere.git')]);
      await sc.refresh();
      expect(await sc.sync(), isFalse);
      expect(sc.error, isNotEmpty);
    });
  });

  testWidgets('the view lists commits with their branches', (tester) async {
    final dir = Directory.systemTemp.createTempSync('graphview');
    addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
    await tester.runAsync(() async {
      await _git(dir.path, ['init', '-b', 'main']);
      await _git(dir.path, ['config', 'user.email', 'test@example.com']);
      await _git(dir.path, ['config', 'user.name', 'Test']);
      await _commit(dir.path, 'a');
    });
    final sc = SourceControl();
    addTearDown(sc.dispose);
    await tester.runAsync(() => sc.open(dir.path));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GitGraphView(git: sc))));
    // Each git command takes a few turns of the real clock and of the test's.
    for (var i = 0; i < 300 && find.text('add a').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('add a'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  });
}
