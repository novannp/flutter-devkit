import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/local_builds.dart';
import 'atlassian.dart';
import 'git_repo.dart';
import 'work_service.dart';

/// The Jira ticket of the branch the project is on, shown in the device workspace top bar.
class TicketChip extends StatefulWidget {
  const TicketChip({
    super.key,
    required this.project,
    required this.active,
    required this.onSendScreenshot,
    required this.onSendBugReport,
  });

  final FlutterProject? project;
  final ValueNotifier<JiraIssue?> active;
  final VoidCallback onSendScreenshot;
  final VoidCallback onSendBugReport;

  @override
  State<TicketChip> createState() => _TicketChipState();
}

class _TicketChipState extends State<TicketChip> {
  Timer? _poll;
  String? _branch;

  @override
  void initState() {
    super.initState();
    _check();
    // Branches change outside HotRestart (VS Code, terminal), so look again now and then.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _check());
  }

  @override
  void didUpdateWidget(TicketChip old) {
    super.didUpdateWidget(old);
    if (old.project?.path != widget.project?.path) _check();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final work = WorkService.instance;
    await work.load();
    final p = widget.project;
    if (p == null || !work.config.hasJira) return _set(null, null);
    final repo = WorkRepo(p);
    await repo.refresh();
    final key = repo.ticket;
    if (key == null) return _set(repo.branch, null);
    _set(repo.branch, await work.cachedIssue(key));
  }

  void _set(String? branch, JiraIssue? issue) {
    if (!mounted) return;
    if (widget.active.value?.key != issue?.key || widget.active.value?.status != issue?.status) {
      widget.active.value = issue;
    }
    if (branch != _branch) setState(() => _branch = branch);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.active,
    builder: (context, issue, _) {
      if (issue == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final color = switch (issue.group) {
        StatusGroup.todo => Colors.blueGrey,
        StatusGroup.inProgress => Colors.blue,
        StatusGroup.done => Colors.green,
      };
      return PopupMenuButton<VoidCallback>(
        tooltip: '${issue.key} ${issue.summary}\n${issue.status} · branch $_branch',
        onSelected: (f) => f(),
        itemBuilder: (_) => [
          PopupMenuItem(height: 30, 
            value: () => openUrl(issue.url),
            child: const ListTile(leading: Icon(Icons.open_in_new), title: Text('Open in Jira')),
          ),
          PopupMenuItem(height: 30, 
            value: () => Clipboard.setData(ClipboardData(text: issue.key)),
            child: const ListTile(leading: Icon(Icons.copy), title: Text('Copy key')),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(height: 30, 
            value: widget.onSendScreenshot,
            child: ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined),
              title: Text('Send screenshot to ${issue.key}'),
            ),
          ),
          PopupMenuItem(height: 30, 
            value: widget.onSendBugReport,
            child: ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: Text('Send bug report to ${issue.key}'),
              subtitle: const Text('Screenshot, logs and device info as a comment'),
            ),
          ),
        ],
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.task_alt, size: 14, color: color),
              const SizedBox(width: 5),
              Text(issue.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  issue.summary,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
