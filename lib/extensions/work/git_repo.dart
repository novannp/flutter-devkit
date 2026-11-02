import 'dart:io';

import '../../core/local_builds.dart';
import 'atlassian.dart';

final _ticketRe = RegExp(r'([A-Z][A-Z0-9]+-\d+)');

String? ticketKeyOf(String? branch) => branch == null ? null : _ticketRe.firstMatch(branch)?[1];

String branchNameFor(JiraIssue issue) {
  final slug = issue.summary.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final short = slug.length > 40 ? slug.substring(0, 40).replaceAll(RegExp(r'-[^-]*$'), '') : slug;
  final prefix = issue.type.toLowerCase().contains('bug') ? 'bugfix' : 'feature';
  return '$prefix/${issue.key}${short.isEmpty ? '' : '-$short'}';
}

class GitResult {
  const GitResult(this.ok, this.output);

  final bool ok;
  final String output;
}

class WorkRepo {
  WorkRepo(this.project);

  final FlutterProject project;
  String? branch;
  String? slug;
  bool dirty = false;

  String get path => project.path;
  String get name => project.name;
  String? get ticket => ticketKeyOf(branch);

  Future<GitResult> git(List<String> args) async {
    try {
      final r = await Process.run('git', args, workingDirectory: path, runInShell: true);
      final out = '${r.stdout}${r.stderr}'.trim();
      return GitResult(r.exitCode == 0, out);
    } on ProcessException catch (e) {
      return GitResult(false, 'git not found: ${e.message}');
    }
  }

  Future<void> refresh() async {
    final b = await git(['rev-parse', '--abbrev-ref', 'HEAD']);
    branch = b.ok ? b.output : null;
    final s = await git(['status', '--porcelain', '--untracked-files=no']);
    dirty = s.ok && s.output.isNotEmpty;
    if (slug == null) {
      final r = await git(['remote', 'get-url', 'origin']);
      final m = RegExp(r'bitbucket\.org[:/][^/]+/([^/\s]+?)(?:\.git)?$').firstMatch(r.output);
      slug = r.ok ? m?.group(1) : null;
    }
  }

  Future<List<String>> branchesFor(String key) async {
    final r = await git(['branch', '--list', '*$key*', '--format=%(refname:short)']);
    return r.ok ? r.output.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList() : const [];
  }

  /// Checks out [name], creating it from origin/[base] when it doesn't exist yet.
  Future<GitResult> startBranch(String name, String base) async {
    final existing = await git(['rev-parse', '--verify', '--quiet', 'refs/heads/$name']);
    if (existing.ok) return _done(await git(['checkout', name]));
    final fetch = await git(['fetch', 'origin', base]);
    if (!fetch.ok) return fetch;
    return _done(await git(['checkout', '-b', name, 'origin/$base']));
  }

  /// Checks out a remote branch (e.g. a PR's source) and fast-forwards it.
  Future<GitResult> checkoutRemote(String name) async {
    final fetch = await git(['fetch', 'origin', name]);
    if (!fetch.ok) return fetch;
    final existing = await git(['rev-parse', '--verify', '--quiet', 'refs/heads/$name']);
    if (!existing.ok) return _done(await git(['checkout', '-b', name, '--track', 'origin/$name']));
    final co = await git(['checkout', name]);
    if (!co.ok) return co;
    return _done(await git(['merge', '--ff-only', 'origin/$name']));
  }

  Future<GitResult> push() => git(['push', '-u', 'origin', 'HEAD']);

  Future<GitResult> _done(GitResult r) async {
    await refresh();
    return r;
  }
}

/// App repos from the project folders, one per git checkout.
Future<List<WorkRepo>> scanWorkRepos() async {
  final repos = [for (final p in await scanFlutterProjects()) WorkRepo(p)];
  await Future.wait(repos.map((r) => r.refresh()));
  return repos.where((r) => r.branch != null).toList();
}
