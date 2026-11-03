import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class GitChange {
  const GitChange(this.path, this.index, this.worktree, {this.from});

  /// Relative to the repo root, with forward slashes.
  final String path;
  final String index, worktree;
  final String? from;

  bool get untracked => index == '?';
  bool get staged => index != ' ' && index != '?';
  bool get unstaged => worktree != ' ';
}

class BlameLine {
  const BlameLine(this.hash, this.author, this.time, this.summary);

  final String hash, author, summary;
  final DateTime time;

  /// Git uses an all-zero hash for lines that only exist in the working copy.
  bool get committed => hash.replaceAll('0', '').isNotEmpty;

  String describe(DateTime now) => committed ? '$author, ${ageOf(time, now)} • $summary' : 'Not committed yet';
}

String ageOf(DateTime time, DateTime now) {
  final d = now.difference(time);
  String ago(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
  if (d.inDays >= 365) return ago(d.inDays ~/ 365, 'year');
  if (d.inDays >= 30) return ago(d.inDays ~/ 30, 'month');
  if (d.inDays >= 7) return ago(d.inDays ~/ 7, 'week');
  if (d.inDays >= 1) return ago(d.inDays, 'day');
  if (d.inHours >= 1) return ago(d.inHours, 'hour');
  if (d.inMinutes >= 1) return ago(d.inMinutes, 'minute');
  return 'just now';
}

/// Parses `git blame --line-porcelain`, into who last touched each line, from 0.
Map<int, BlameLine> parseBlame(String output) {
  final result = <int, BlameLine>{};
  final header = RegExp(r'^([0-9a-f]{40}) \d+ (\d+)');
  String? hash, author, summary;
  int? line;
  var time = 0;
  for (final raw in const LineSplitter().convert(output)) {
    if (raw.startsWith('\t')) {
      if (hash != null && line != null) {
        result[line - 1] = BlameLine(hash, author ?? '', DateTime.fromMillisecondsSinceEpoch(time * 1000), summary ?? '');
      }
      continue;
    }
    final m = header.firstMatch(raw);
    if (m != null) {
      hash = m[1];
      line = int.parse(m[2]!);
    } else if (raw.startsWith('author ')) {
      author = raw.substring(7);
    } else if (raw.startsWith('author-time ')) {
      time = int.tryParse(raw.substring(12)) ?? 0;
    } else if (raw.startsWith('summary ')) {
      summary = raw.substring(8);
    }
  }
  return result;
}

/// Parses `git status --porcelain=v1 -z`: no quoting, and a rename's old path follows as its own field.
List<GitChange> parseStatus(String output) {
  final fields = output.split('\u0000');
  final changes = <GitChange>[];
  for (var i = 0; i < fields.length; i++) {
    final f = fields[i];
    if (f.length < 4) continue;
    final index = f[0];
    final renamed = index == 'R' || index == 'C';
    changes.add(GitChange(f.substring(3), index, f[1], from: renamed ? fields.elementAtOrNull(++i) : null));
  }
  return changes;
}

enum GitMark { added, modified, deleted }

class CommitFile {
  const CommitFile(this.status, this.path, [this.from]);

  /// A letter, as git gives it: A, M, D or R.
  final String status;
  final String path;

  /// Where a renamed file came from.
  final String? from;
}

/// `git show --name-status`: `M<tab>path`, or `R100<tab>old<tab>new`.
List<CommitFile> parseCommitFiles(String output) => [
  for (final line in const LineSplitter().convert(output))
    if (line.split('\t') case [final status, final path, ...final rest] when status.isNotEmpty)
      rest.isEmpty ? CommitFile(status.substring(0, 1), path) : CommitFile(status.substring(0, 1), rest.first, path),
];

/// What the branch can do with a remote: a branch only here is published, one with a remote is synced.
enum BranchAction { none, publish, sync }

/// Fields for the git graph, split by a character that can't be typed into any of them.
const graphLogFormat = '%H%x1f%P%x1f%D%x1f%an%x1f%ar%x1f%s';

final _hunk = RegExp(r'^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

/// Gutter marks, by 0-based line, from a `git diff -U0`.
Map<int, GitMark> parseMarks(String diff) {
  final marks = <int, GitMark>{};
  for (final line in const LineSplitter().convert(diff)) {
    final m = _hunk.firstMatch(line);
    if (m == null) continue;
    final removed = int.parse(m[1] ?? '1');
    final start = int.parse(m[2]!);
    final added = int.parse(m[3] ?? '1');
    if (added == 0) {
      // With nothing added, git numbers the line above the gap.
      marks[start < 1 ? 0 : start - 1] = GitMark.deleted;
    } else {
      for (var i = 0; i < added; i++) {
        marks[start - 1 + i] = i < removed ? GitMark.modified : GitMark.added;
      }
    }
  }
  return marks;
}

/// One row of a side by side diff. A null number means that side has no such line.
class DiffRow {
  const DiffRow(this.beforeLine, this.before, this.afterLine, this.after);

  final int? beforeLine, afterLine;
  final String before, after;

  bool get changed => beforeLine == null || afterLine == null || before != after;
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Lines up a unified diff into rows, with a changed block's old and new lines next to each other.
/// Numbers are 0-based.
List<DiffRow> parseSideBySide(String diff) {
  final rows = <DiffRow>[];
  final removed = <(int, String)>[], added = <(int, String)>[];
  void flush() {
    for (var i = 0; i < removed.length || i < added.length; i++) {
      final old = i < removed.length ? removed[i] : null;
      final now = i < added.length ? added[i] : null;
      rows.add(DiffRow(old?.$1, old?.$2 ?? '', now?.$1, now?.$2 ?? ''));
    }
    removed.clear();
    added.clear();
  }

  var before = 0, after = 0;
  var inHunk = false;
  for (final line in const LineSplitter().convert(diff)) {
    final m = _hunkHeader.firstMatch(line);
    if (m != null) {
      flush();
      inHunk = true;
      before = int.parse(m[1]!) - 1;
      after = int.parse(m[2]!) - 1;
    } else if (!inHunk || line.startsWith(r'\')) {
      continue;
    } else if (line.startsWith('-')) {
      removed.add((before++, line.substring(1)));
    } else if (line.startsWith('+')) {
      added.add((after++, line.substring(1)));
    } else {
      flush();
      final text = line.isEmpty ? '' : line.substring(1);
      rows.add(DiffRow(before++, text, after++, text));
    }
  }
  flush();
  return rows;
}

class GitOutput {
  const GitOutput(this.ok, this.text);

  final bool ok;
  final String text;
}

/// One repo's state for the editor. Git runs without a shell, so a commit message can hold `&` or quotes.
class SourceControl extends ChangeNotifier {
  String? top;
  String? branch;
  int ahead = 0, behind = 0;
  bool hasUpstream = false;
  bool hasRemote = false;

  BranchAction get branchAction {
    if (hasUpstream) return BranchAction.sync;
    return hasRemote && branch != '(detached)' ? BranchAction.publish : BranchAction.none;
  }
  List<GitChange> changes = const [];
  bool busy = false;
  String? error;

  var _folder = '';
  var _refreshing = false;
  var _refreshAgain = false;
  var _disposed = false;

  bool get isRepo => top != null;
  List<GitChange> get staged => changes.where((c) => c.staged).toList();
  List<GitChange> get unstaged => changes.where((c) => c.unstaged).toList();

  String absolute(String relative) => p.normalize(p.join(top ?? _folder, relative));

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<GitOutput> _git(List<String> args) async {
    if (_disposed) return const GitOutput(false, '');
    try {
      final r = await Process.run(
        'git',
        args,
        workingDirectory: top ?? _folder,
        // Without this a missing credential waits forever on a prompt nobody can see.
        environment: const {'GIT_TERMINAL_PROMPT': '0'},
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      final out = r.stdout as String;
      return GitOutput(r.exitCode == 0, r.exitCode == 0 ? out : '$out${r.stderr}'.trim());
    } on ProcessException catch (e) {
      return GitOutput(false, 'git not found: ${e.message}');
    }
  }

  Future<void> open(String folder) async {
    _folder = folder;
    top = null;
    branch = null;
    changes = const [];
    error = null;
    await refresh();
  }

  // Git answers with the real path, but files open under the folder's: a symlink, a junction or a short Windows name.
  Future<String> _inFolderForm(String real) async {
    final up = await _git(['rev-parse', '--show-cdup']);
    if (!up.ok) return real;
    final local = p.normalize(p.join(_folder, up.text.trim()));
    try {
      final same = p.equals(await Directory(local).resolveSymbolicLinks(), await Directory(real).resolveSymbolicLinks());
      return same ? local : real;
    } on FileSystemException {
      return real;
    }
  }

  Future<void> refresh() async {
    if (_folder.isEmpty) return;
    // The running pass may have read the repo before this change, so it gets one more look.
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      if (top == null) {
        final t = await _git(['rev-parse', '--show-toplevel']);
        if (!t.ok) return;
        top = await _inFolderForm(p.normalize(t.text.trim()));
      }
      final s = await _git(['status', '--porcelain=v1', '-z', '--untracked-files=all']);
      if (!s.ok) return;
      changes = parseStatus(s.text);
      final head = await _git(['branch', '--show-current']);
      branch = head.text.trim().isEmpty ? '(detached)' : head.text.trim();
      final counts = await _git(['rev-list', '--left-right', '--count', '@{upstream}...HEAD']);
      hasUpstream = counts.ok;
      hasRemote = (await _git(['remote'])).text.trim().isNotEmpty;
      final parts = counts.ok ? counts.text.trim().split(RegExp(r'\s+')) : const <String>[];
      behind = int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 0;
      ahead = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0;
    } finally {
      _refreshing = false;
      _changed();
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  Future<bool> _run(List<List<String>> commands) async {
    busy = true;
    error = null;
    _changed();
    var ok = true;
    for (final args in commands) {
      final r = await _git(args);
      if (!r.ok) {
        ok = false;
        error = r.text;
        break;
      }
    }
    busy = false;
    await refresh();
    return ok;
  }

  Future<bool> stage(List<GitChange> items) => _run([
    ['add', '-A', '--', ...items.map((c) => c.path)],
  ]);

  Future<bool> unstage(List<GitChange> items) => _run([
    ['restore', '--staged', '--', for (final c in items) ...[c.path, ?c.from]],
  ]);

  /// Throws away the working copy's edits, or the file itself when git has never seen it.
  Future<bool> discard(GitChange c) async {
    if (!c.untracked) {
      return _run([
        ['restore', '--staged', '--worktree', '--', c.path],
      ]);
    }
    try {
      await File(absolute(c.path)).delete();
    } on FileSystemException catch (e) {
      error = '${c.path}: ${e.message}';
    }
    await refresh();
    return error == null;
  }

  /// Puts the repo back at the last commit. Through the stash, so a slip can still be recovered.
  Future<bool> discardAll() => _run([
    ['stash', 'push', '--include-untracked', '-m', 'Slipway: before Discard All Changes'],
  ]);

  Future<bool> commit(String message) => _run([
    ['commit', '-m', message],
  ]);

  Future<bool> push() => _run([
    hasUpstream ? ['push'] : ['push', '-u', 'origin', 'HEAD'],
  ]);

  /// Publishes a branch that's only here. One with a remote gets what's new there, then sends what's new here.
  Future<bool> sync() async {
    if (!hasUpstream) return push();
    if (!await _run([
      ['fetch'],
    ])) {
      return false;
    }
    return _run([
      if (behind > 0) ['pull', '--ff-only'],
      if (ahead > 0) ['push'],
    ]);
  }

  /// What a commit changed, against its first parent.
  Future<List<CommitFile>> commitFiles(String hash) async {
    final r = await _git(['show', '--format=', '--name-status', '-M', '-m', '--first-parent', hash]);
    return r.ok ? parseCommitFiles(r.text) : const [];
  }

  Future<String> commitMessage(String hash) async {
    final r = await _git(['log', '-1', '--format=%B', hash]);
    return r.ok ? r.text.trim() : '';
  }

  Future<List<DiffRow>> commitDiff(String hash, CommitFile file) async {
    final r = await _git(['show', '--format=', '--no-color', '--no-ext-diff', '-U1000000', '-m', '--first-parent', '-M', hash, '--', ?file.from, file.path]);
    return r.ok ? parseSideBySide(r.text) : const [];
  }

  /// The newest commits of every branch, newest first.
  Future<String> graphLog({int limit = 500}) async {
    final r = await _git(['log', '--all', '--date-order', '-n', '$limit', '--format=$graphLogFormat']);
    return r.ok ? r.text : '';
  }

  Future<bool> pull() => _run([
    ['pull', '--ff-only'],
  ]);

  Future<List<String>> branches() async {
    final r = await _git(['branch', '--format=%(refname:short)']);
    return r.ok ? const LineSplitter().convert(r.text).where((s) => s.trim().isNotEmpty).toList() : const [];
  }

  Future<bool> switchTo(String name, {bool create = false}) => _run([
    ['switch', if (create) '-c', name],
  ]);

  /// The whole file on both sides: as much context as any file could have.
  Future<List<DiffRow>> sideBySideOf(GitChange c, {required bool staged}) async {
    if (c.untracked) {
      final text = await File(absolute(c.path)).readAsString().catchError((_) => '');
      return [for (final (i, l) in const LineSplitter().convert(text).indexed) DiffRow(null, '', i, l)];
    }
    final r = await _git(['diff', '-U1000000', '--no-color', '--no-ext-diff', if (staged) '--cached', '--', c.path]);
    return parseSideBySide(r.text);
  }

  /// Who last touched each line of a saved file; empty when git doesn't track it.
  Future<Map<int, BlameLine>> blameOf(String path) async {
    if (top == null || !p.isWithin(top!, path)) return const {};
    final r = await _git(['blame', '--line-porcelain', '--', path]);
    return r.ok ? parseBlame(r.text) : const {};
  }

  /// How a saved file differs from HEAD, for the gutter.
  Future<Map<int, GitMark>> marksOf(String path) async {
    if (top == null || !p.isWithin(top!, path)) return const {};
    final r = await _git(['diff', '-U0', '--no-color', '--no-ext-diff', 'HEAD', '--', path]);
    return r.ok ? parseMarks(r.text) : const {};
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
