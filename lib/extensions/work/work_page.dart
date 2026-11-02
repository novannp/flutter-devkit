import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/history.dart';
import 'atlassian.dart';
import 'git_repo.dart';
import 'work_service.dart';
import 'work_settings_dialog.dart';
import '../../core/compact_dropdown.dart';

class WorkPage extends StatefulWidget {
  const WorkPage({super.key});

  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  final work = WorkService.instance;
  var _tab = 0;
  List<WorkRepo> _repos = const [];

  @override
  void initState() {
    super.initState();
    work.load();
    _loadRepos();
  }

  Future<void> _loadRepos() async {
    final repos = await scanWorkRepos();
    if (mounted) setState(() => _repos = repos);
  }

  Future<void> _settings() async {
    final saved = await showDialog<bool>(context: context, builder: (_) => const WorkSettingsDialog());
    if (saved == true) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: work,
      builder: (context, _) {
        final c = work.config;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Work', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 20),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, icon: Icon(Icons.task_alt, size: 18), label: Text('My tickets')),
                      ButtonSegment(value: 1, icon: Icon(Icons.merge_type, size: 18), label: Text('Pull requests')),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Rescan repos',
                    onPressed: _loadRepos,
                    icon: const Icon(Icons.folder_copy_outlined),
                  ),
                  IconButton(
                    tooltip: 'Jira & Bitbucket connection',
                    onPressed: _settings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: !work.loaded
                    ? const Center(child: CircularProgressIndicator())
                    : _tab == 0
                    ? (c.hasJira
                          ? _TicketsView(repos: _repos, onReposChanged: () => setState(() {}))
                          : _Connect(what: 'Jira', onConnect: _settings))
                    : (c.hasBitbucket
                          ? _PrsView(repos: _repos, onReposChanged: () => setState(() {}))
                          : _Connect(what: 'Bitbucket', onConnect: _settings)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Connect extends StatelessWidget {
  const _Connect({required this.what, required this.onConnect});

  final String what;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.link, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 10),
        Text(
          what == 'Jira'
              ? 'See your tickets, start a branch and send test evidence without opening the browser.'
              : 'Review, check out and approve pull requests from DevKit.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: onConnect, icon: const Icon(Icons.link), label: Text('Connect $what')),
      ],
    ),
  );
}

void _toast(BuildContext context, String msg, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), width: 520, behavior: SnackBarBehavior.floating, action: action));
}

Future<bool> _confirmDirty(BuildContext context, WorkRepo repo) async {
  if (!repo.dirty) return true;
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${repo.name} has uncommitted changes'),
          content: Text(
            'You are on ${repo.branch}. The changes come along to the other branch, '
            'or git refuses if they conflict. Commit or stash first if unsure.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Switch anyway')),
          ],
        ),
      ) ??
      false;
}

// ---------------------------------------------------------------- Tickets

class _TicketsView extends StatefulWidget {
  const _TicketsView({required this.repos, required this.onReposChanged});

  final List<WorkRepo> repos;
  final VoidCallback onReposChanged;

  @override
  State<_TicketsView> createState() => _TicketsViewState();
}

class _TicketsViewState extends State<_TicketsView> {
  final work = WorkService.instance;
  List<JiraIssue> _issues = const [];
  String? _error;
  var _loading = false;
  String? _selected;
  String _query = '';
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final issues = await work.jira.myIssues(text: _query);
      if (!mounted) return;
      setState(() {
        _issues = issues;
        _selected ??= issues.firstOrNull?.key;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = [
      ('In progress', StatusGroup.inProgress),
      ('To do', StatusGroup.todo),
      ('Done (last 14 days)', StatusGroup.done),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search Jira or type a key (POS-123)…',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) {
                        _query = v;
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(const Duration(milliseconds: 500), _refresh);
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _refresh,
                    icon: _loading
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Card(
                  color: scheme.errorContainer,
                  child: ListTile(dense: true, leading: const Icon(Icons.error_outline), title: Text(_error!)),
                ),
              Expanded(
                child: _issues.isEmpty && !_loading && _error == null
                    ? Center(
                        child: Text(
                          _query.isEmpty ? 'Nothing assigned to you. Enjoy it.' : 'No tickets match.',
                          style: TextStyle(color: scheme.outline),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final (label, g) in groups)
                            if (_issues.where((i) => i.group == g).toList() case final list when list.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                                child: Text(
                                  '$label · ${list.length}',
                                  style: TextStyle(color: scheme.outline, fontWeight: FontWeight.w600, fontSize: 12),
                                ),
                              ),
                              for (final i in list)
                                _IssueTile(
                                  issue: i,
                                  selected: i.key == _selected,
                                  onBranch: widget.repos.any((r) => r.ticket == i.key),
                                  onTap: () => setState(() => _selected = i.key),
                                ),
                            ],
                        ],
                      ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 24),
        Expanded(
          child: _selected == null
              ? Center(
                  child: Text('Pick a ticket', style: TextStyle(color: scheme.outline)),
                )
              : _IssueDetail(
                  key: ValueKey(_selected),
                  issueKey: _selected!,
                  repos: widget.repos,
                  onChanged: () {
                    widget.onReposChanged();
                    _refresh();
                  },
                ),
        ),
      ],
    );
  }
}

IconData _typeIcon(String type) {
  final t = type.toLowerCase();
  if (t.contains('bug')) return Icons.bug_report;
  if (t.contains('story')) return Icons.bookmark;
  if (t.contains('epic')) return Icons.bolt;
  if (t.contains('sub')) return Icons.subdirectory_arrow_right;
  return Icons.check_box_outlined;
}

Color _typeColor(String type) {
  final t = type.toLowerCase();
  if (t.contains('bug')) return Colors.red.shade400;
  if (t.contains('story')) return Colors.green.shade500;
  if (t.contains('epic')) return Colors.purple.shade300;
  return Colors.blue.shade400;
}

Color _groupColor(StatusGroup g) => switch (g) {
  StatusGroup.todo => Colors.blueGrey,
  StatusGroup.inProgress => Colors.blue,
  StatusGroup.done => Colors.green,
};

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status, this.group);

  final String status;
  final StatusGroup group;

  @override
  Widget build(BuildContext context) {
    final c = _groupColor(group);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue, required this.selected, required this.onBranch, required this.onTap});

  final JiraIssue issue;
  final bool selected;
  final bool onBranch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: selected ? scheme.secondaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(issue.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(_typeIcon(issue.type), size: 14, color: _typeColor(issue.type)),
                  const SizedBox(width: 4),
                  Text(issue.key, style: TextStyle(fontSize: 12, color: scheme.outline)),
                  if (onBranch) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Checked out in a local repo',
                      child: Icon(Icons.call_split, size: 14, color: Colors.green.shade400),
                    ),
                  ],
                  const Spacer(),
                  _StatusChip(issue.status, issue.group),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IssueDetail extends StatefulWidget {
  const _IssueDetail({super.key, required this.issueKey, required this.repos, required this.onChanged});

  final String issueKey;
  final List<WorkRepo> repos;
  final VoidCallback onChanged;

  @override
  State<_IssueDetail> createState() => _IssueDetailState();
}

class _IssueDetailState extends State<_IssueDetail> {
  final work = WorkService.instance;
  JiraIssue? _issue;
  List<JiraTransition> _transitions = const [];
  String? _error;
  var _busy = false;
  final _comment = TextEditingController();

  JiraClient get jira => work.jira;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([jira.issue(widget.issueKey), jira.transitions(widget.issueKey)]);
      if (!mounted) return;
      setState(() {
        _issue = results[0] as JiraIssue;
        _transitions = results[1] as List<JiraTransition>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _busyRun(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) _toast(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _transition(JiraTransition t) => _busyRun(() async {
    await jira.transition(widget.issueKey, t.id);
    work.forget(widget.issueKey);
    await _load();
    widget.onChanged();
  });

  Future<void> _sendComment() => _busyRun(() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    await jira.comment(widget.issueKey, text);
    _comment.clear();
    await _load();
  });

  Future<void> _startWork() async {
    final issue = _issue!;
    final r = await showDialog<_StartChoice>(
      context: context,
      builder: (_) => _StartWorkDialog(issue: issue, repos: widget.repos, base: work.config.baseBranch),
    );
    if (r == null || !mounted || !await _confirmDirty(context, r.repo)) return;
    await _busyRun(() async {
      final res = await r.repo.startBranch(r.branch, r.base);
      if (!res.ok) throw Exception('git: ${res.output}');
      History.activity('work', 'Started ${issue.key} on ${r.repo.name}', {'branch': r.branch});
      String? moved;
      if (r.moveToProgress && issue.group == StatusGroup.todo) {
        moved = await jira.moveTo(issue.key, ['In Progress', 'In Development', 'Doing', 'Start Progress']);
      }
      if (r.openCode) await openInVsCode(r.repo.path);
      work.forget(issue.key);
      await _load();
      widget.onChanged();
      if (mounted) {
        _toast(context, 'On ${r.branch} in ${r.repo.name}${moved != null ? ' · ticket moved to $moved' : ''}');
      }
    });
  }

  Future<void> _createPr(WorkRepo repo) async {
    final issue = _issue!;
    if (!work.config.hasBitbucket) return _toast(context, 'Connect Bitbucket first (gear icon)');
    if (repo.slug == null) return _toast(context, '${repo.name} has no bitbucket.org remote');
    final draft = await showDialog<(String, String, String)>(
      context: context,
      builder: (_) => _PrDialog(
        title: '${issue.key} ${issue.summary}',
        description: '[${issue.key}](${issue.url}) ${issue.summary}\n\n## Changes\n- \n\n## How to test\n- ',
        source: repo.branch!,
        dest: work.config.baseBranch,
      ),
    );
    if (draft == null) return;
    await _busyRun(() async {
      if (repo.dirty) _toast(context, 'Uncommitted changes are not pushed, only commits are');
      final push = await repo.push();
      if (!push.ok) throw Exception('git push: ${push.output}');
      final pr = await work.bitbucket.createPr(
        repo.slug!,
        source: repo.branch!,
        dest: draft.$3,
        title: draft.$1,
        description: draft.$2,
      );
      History.activity('work', 'PR #${pr.id} for ${issue.key}', {'url': pr.url});
      final moved = await jira.moveTo(issue.key, ['Code Review', 'In Review', 'Review']);
      await _load();
      widget.onChanged();
      if (mounted) {
        _toast(
          context,
          'PR #${pr.id} created${moved != null ? ' · ticket moved to $moved' : ''}',
          action: SnackBarAction(label: 'Open', onPressed: () => openUrl(pr.url)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: scheme.error)));
    }
    final issue = _issue;
    if (issue == null) return const Center(child: CircularProgressIndicator());
    final onBranch = widget.repos.where((r) => r.ticket == issue.key).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Row(
          children: [
            Icon(_typeIcon(issue.type), size: 16, color: _typeColor(issue.type)),
            const SizedBox(width: 6),
            SelectableText(issue.key, style: TextStyle(color: scheme.outline)),
            if (issue.priority != null) ...[
              const SizedBox(width: 10),
              Text('· ${issue.priority}', style: TextStyle(color: scheme.outline, fontSize: 12)),
            ],
            const Spacer(),
            if (_busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(
              tooltip: 'Copy key',
              onPressed: () => Clipboard.setData(ClipboardData(text: issue.key)),
              icon: const Icon(Icons.copy, size: 18),
            ),
            IconButton(
              tooltip: 'Open in Jira',
              onPressed: () => openUrl(issue.url),
              icon: const Icon(Icons.open_in_new, size: 18),
            ),
          ],
        ),
        SelectableText(issue.summary, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PopupMenuButton<JiraTransition>(
              tooltip: 'Change status',
              enabled: !_busy && _transitions.isNotEmpty,
              onSelected: _transition,
              itemBuilder: (_) => [
                for (final t in _transitions)
                  PopupMenuItem(height: 30, value: t, child: Text(t.name == t.to ? t.to : '${t.name} → ${t.to}')),
              ],
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                decoration: BoxDecoration(
                  color: _groupColor(issue.group).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      issue.status,
                      style: TextStyle(fontWeight: FontWeight.w600, color: _groupColor(issue.group)),
                    ),
                    Icon(Icons.arrow_drop_down, color: _groupColor(issue.group)),
                  ],
                ),
              ),
            ),
            if (onBranch.isEmpty)
              FilledButton.icon(
                onPressed: _busy || widget.repos.isEmpty ? null : _startWork,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start work'),
              ),
            for (final r in onBranch) ...[
              OutlinedButton.icon(
                onPressed: () => openInVsCode(r.path),
                icon: const Icon(Icons.code, size: 18),
                label: Text('Open ${r.name}'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _createPr(r),
                icon: const Icon(Icons.merge_type, size: 18),
                label: const Text('Push & create PR'),
              ),
            ],
            if (onBranch.isNotEmpty)
              TextButton(onPressed: _busy ? null : _startWork, child: const Text('Start in another repo')),
          ],
        ),
        if (widget.repos.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Add your repo folder in Settings → Project folders to start branches from here.',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ),
        for (final r in onBranch)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${r.name}: on ${r.branch}${r.dirty ? ' · uncommitted changes' : ''}',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ),
        const SizedBox(height: 20),
        Text('Description', style: text.titleSmall),
        const SizedBox(height: 6),
        SelectableText(
          issue.description.isEmpty ? 'No description.' : issue.description,
          style: TextStyle(color: issue.description.isEmpty ? scheme.outline : null, height: 1.4),
        ),
        const SizedBox(height: 20),
        Text('Comments · ${issue.comments.length}', style: text.titleSmall),
        const SizedBox(height: 6),
        for (final c in issue.comments.reversed.take(15))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${c.author}${c.created != null ? ' · ${_ago(c.created!)}' : ''}',
                    style: TextStyle(fontSize: 12, color: scheme.outline, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(c.body, style: const TextStyle(height: 1.35)),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _comment,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: 'Add a comment…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Send',
              onPressed: _busy ? null : _sendComment,
              icon: const Icon(Icons.send),
            ),
          ),
        ),
      ],
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.day}/${t.month}/${t.year}';
}

class _StartChoice {
  const _StartChoice(this.repo, this.branch, this.base, this.moveToProgress, this.openCode);

  final WorkRepo repo;
  final String branch, base;
  final bool moveToProgress, openCode;
}

class _StartWorkDialog extends StatefulWidget {
  const _StartWorkDialog({required this.issue, required this.repos, required this.base});

  final JiraIssue issue;
  final List<WorkRepo> repos;
  final String base;

  @override
  State<_StartWorkDialog> createState() => _StartWorkDialogState();
}

class _StartWorkDialogState extends State<_StartWorkDialog> {
  late WorkRepo _repo = widget.repos.first;
  late final _branch = TextEditingController(text: branchNameFor(widget.issue));
  late final _base = TextEditingController(text: widget.base);
  var _move = true;
  var _code = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Start ${widget.issue.key}'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CompactDropdown<WorkRepo>(
            initialValue: _repo,
            decoration: const InputDecoration(labelText: 'Repo', border: OutlineInputBorder(), isDense: true),
            items: [
              for (final r in widget.repos)
                DropdownMenuItem(value: r, child: Text('${r.name}  ·  ${r.branch}${r.dirty ? '  ·  changes' : ''}')),
            ],
            onChanged: (r) => setState(() => _repo = r!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _branch,
            decoration: const InputDecoration(labelText: 'Branch', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _base,
            decoration: const InputDecoration(
              labelText: 'From (origin/…)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          if (widget.issue.group == StatusGroup.todo)
            CheckboxListTile(
              value: _move,
              onChanged: (v) => setState(() => _move = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('Move ticket to In Progress'),
            ),
          CheckboxListTile(
            value: _code,
            onChanged: (v) => setState(() => _code = v!),
            contentPadding: EdgeInsets.zero,
            title: const Text('Open in VS Code'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, _StartChoice(_repo, _branch.text.trim(), _base.text.trim(), _move, _code)),
        child: const Text('Create branch'),
      ),
    ],
  );
}

class _PrDialog extends StatefulWidget {
  const _PrDialog({required this.title, required this.description, required this.source, required this.dest});

  final String title, description, source, dest;

  @override
  State<_PrDialog> createState() => _PrDialogState();
}

class _PrDialogState extends State<_PrDialog> {
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  late final _dest = TextEditingController(text: widget.dest);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create pull request'),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${widget.source}  →', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 8),
          TextField(
            controller: _dest,
            decoration: const InputDecoration(labelText: 'Into', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            minLines: 6,
            maxLines: 12,
            decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          Text(
            'Pushes the branch first. Default reviewers are added.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(context, (_title.text.trim(), _desc.text, _dest.text.trim())),
        child: const Text('Push & create'),
      ),
    ],
  );
}

// ---------------------------------------------------------------- Pull requests

enum _PrFilter { review, mine, all }

class _PrsView extends StatefulWidget {
  const _PrsView({required this.repos, required this.onReposChanged});

  final List<WorkRepo> repos;
  final VoidCallback onReposChanged;

  @override
  State<_PrsView> createState() => _PrsViewState();
}

class _PrsViewState extends State<_PrsView> {
  final work = WorkService.instance;
  List<PullRequest> _prs = const [];
  final _errors = <String>[];
  var _loading = false;
  var _filter = _PrFilter.review;
  final _busy = <String>{};

  List<String> get _slugs => {for (final r in widget.repos) ?r.slug}.toList();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(_PrsView old) {
    super.didUpdateWidget(old);
    if (old.repos != widget.repos) _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _errors.clear();
    });
    final all = <PullRequest>[];
    await Future.wait(
      _slugs.map((s) => work.bitbucket.openPrs(s).then(all.addAll, onError: (Object e) => _errors.add('$s: $e'))),
    );
    all.sort((a, b) => (b.updated ?? DateTime(0)).compareTo(a.updated ?? DateTime(0)));
    if (mounted) {
      setState(() {
        _prs = all;
        _loading = false;
      });
    }
  }

  Future<void> _act(PullRequest pr, Future<void> Function() job) async {
    final id = '${pr.repo}#${pr.id}';
    setState(() => _busy.add(id));
    try {
      await job();
    } catch (e) {
      if (mounted) _toast(context, '$e');
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  Future<void> _checkout(PullRequest pr) async {
    final repo = widget.repos.where((r) => r.slug == pr.repo).firstOrNull;
    if (repo == null || !await _confirmDirty(context, repo)) return;
    await _act(pr, () async {
      final r = await repo.checkoutRemote(pr.source);
      if (!r.ok) throw Exception('git: ${r.output}');
      widget.onReposChanged();
      if (mounted) {
        _toast(
          context,
          '${repo.name} is on ${pr.source}. Run it from a device workspace (F5).',
          action: SnackBarAction(label: 'VS Code', onPressed: () => openInVsCode(repo.path)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _prs.where(
      (p) => switch (_filter) {
        _PrFilter.review => p.reviewer && !p.mine,
        _PrFilter.mine => p.mine,
        _PrFilter.all => true,
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final (f, label) in [
              (_PrFilter.review, 'To review · ${_prs.where((p) => p.reviewer && !p.mine).length}'),
              (_PrFilter.mine, 'Mine · ${_prs.where((p) => p.mine).length}'),
              (_PrFilter.all, 'All open · ${_prs.length}'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              ),
            const Spacer(),
            Text(
              _slugs.isEmpty ? 'No Bitbucket repos in your project folders' : _slugs.join(', '),
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        for (final e in _errors)
          Card(
            color: scheme.errorContainer,
            child: ListTile(dense: true, leading: const Icon(Icons.error_outline), title: Text(e)),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty && !_loading
              ? Center(
                  child: Text('Nothing here.', style: TextStyle(color: scheme.outline)),
                )
              : ListView(
                  children: [
                    for (final pr in shown)
                      _PrTile(
                        pr: pr,
                        busy: _busy.contains('${pr.repo}#${pr.id}'),
                        checkedOut: widget.repos.any((r) => r.slug == pr.repo && r.branch == pr.source),
                        onCheckout: () => _checkout(pr),
                        onApprove: () => _act(pr, () async {
                          await work.bitbucket.approve(pr, undo: pr.approvedByMe);
                          await _refresh();
                        }),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PrTile extends StatelessWidget {
  const _PrTile({
    required this.pr,
    required this.busy,
    required this.checkedOut,
    required this.onCheckout,
    required this.onApprove,
  });

  final PullRequest pr;
  final bool busy, checkedOut;
  final VoidCallback onCheckout, onApprove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final key = ticketKeyOf(pr.source) ?? ticketKeyOf(pr.title);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pr.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                    [
                      '${pr.repo} #${pr.id}',
                      '${pr.source} → ${pr.dest}',
                      pr.author,
                      if (pr.updated != null) _ago(pr.updated!),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
            if (pr.approvals > 0)
              Tooltip(
                message: '${pr.approvals} approval(s)',
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: Colors.green),
                    Text(' ${pr.approvals}  ', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            if (pr.comments > 0)
              Row(
                children: [
                  Icon(Icons.chat_bubble_outline, size: 15, color: scheme.outline),
                  Text(' ${pr.comments}  ', style: TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
            if (key != null && WorkService.instance.config.hasJira)
              TextButton(onPressed: () => openUrl(WorkService.instance.jira.browseUrl(key)), child: Text(key)),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              IconButton(
                tooltip: checkedOut ? 'Checked out — pull latest' : 'Check out locally to test',
                onPressed: onCheckout,
                icon: Icon(Icons.download_for_offline_outlined, color: checkedOut ? Colors.green : null),
              ),
              if (!pr.mine)
                IconButton(
                  tooltip: pr.approvedByMe ? 'Remove approval' : 'Approve',
                  onPressed: onApprove,
                  icon: Icon(
                    pr.approvedByMe ? Icons.thumb_up : Icons.thumb_up_outlined,
                    color: pr.approvedByMe ? Colors.green : null,
                  ),
                ),
            ],
            IconButton(
              tooltip: 'Open in Bitbucket',
              onPressed: () => openUrl(pr.url),
              icon: const Icon(Icons.open_in_new, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
