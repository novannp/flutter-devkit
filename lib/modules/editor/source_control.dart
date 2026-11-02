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

enum DiffKind { header, hunk, added, removed, context }

class DiffLine {
  const DiffLine(this.kind, this.text, this.line);

  final DiffKind kind;
  final String text;

  /// 0-based line in the new file; null when the line isn't in it.
  final int? line;
}

List<DiffLine> parseDiff(String diff) {
  final out = <DiffLine>[];
  var line = 0;
  var inHunk = false;
  for (final text in const LineSplitter().convert(diff)) {
    final m = _hunk.firstMatch(text);
    if (m != null) {
      inHunk = true;
      line = int.parse(m[2]!) - 1;
      out.add(DiffLine(DiffKind.hunk, text, line));
    } else if (!inHunk) {
      out.add(DiffLine(DiffKind.header, text, null));
    } else if (text.startsWith('+')) {
      out.add(DiffLine(DiffKind.added, text, line++));
    } else if (text.startsWith('-')) {
      out.add(DiffLine(DiffKind.removed, text, null));
    } else if (text.startsWith(r'\')) {
      out.add(DiffLine(DiffKind.header, text, null));
    } else {
      out.add(DiffLine(DiffKind.context, text, line++));
    }
  }
  return out;
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
        top = p.normalize(t.text.trim());
      }
      final s = await _git(['status', '--porcelain=v1', '-z', '--untracked-files=all']);
      if (!s.ok) return;
      changes = parseStatus(s.text);
      final head = await _git(['branch', '--show-current']);
      branch = head.text.trim().isEmpty ? '(detached)' : head.text.trim();
      final counts = await _git(['rev-list', '--left-right', '--count', '@{upstream}...HEAD']);
      hasUpstream = counts.ok;
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

  Future<bool> commit(String message) => _run([
    ['commit', '-m', message],
  ]);

  Future<bool> push() => _run([
    hasUpstream ? ['push'] : ['push', '-u', 'origin', 'HEAD'],
  ]);

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

  Future<List<DiffLine>> diffOf(GitChange c, {required bool staged}) async {
    if (c.untracked) {
      final text = await File(absolute(c.path)).readAsString().catchError((_) => '');
      return [for (final (i, l) in const LineSplitter().convert(text).indexed) DiffLine(DiffKind.added, '+$l', i)];
    }
    final r = await _git(['diff', '--no-color', '--no-ext-diff', if (staged) '--cached', '--', c.path]);
    return parseDiff(r.text);
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
