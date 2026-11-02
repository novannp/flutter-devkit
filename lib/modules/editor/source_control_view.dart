import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'source_control.dart';

Color _statusColor(String status) => switch (status) {
  'A' || '?' => const Color(0xFF22C55E),
  'D' => const Color(0xFFEF4444),
  'U' => const Color(0xFFA855F7),
  _ => const Color(0xFFF59E0B),
};

class SourceControlView extends StatefulWidget {
  const SourceControlView({super.key, required this.git, required this.onBeforeCommit, required this.onDiff});

  final SourceControl git;
  final Future<void> Function() onBeforeCommit;
  final void Function(GitChange change, bool staged) onDiff;

  @override
  State<SourceControlView> createState() => _SourceControlViewState();
}

class _SourceControlViewState extends State<SourceControlView> {
  final _message = TextEditingController();

  SourceControl get _git => widget.git;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final text = _message.text.trim();
    if (text.isEmpty) return;
    await widget.onBeforeCommit();
    if (await _git.commit(text) && mounted) _message.clear();
  }

  Future<void> _discard(GitChange c) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c.untracked ? 'Delete ${p.basename(c.path)}?' : 'Discard changes in ${p.basename(c.path)}?'),
        content: Text(c.untracked ? 'Git has never seen this file, so it can\'t be restored.' : 'Your edits to this file will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(c.untracked ? 'Delete' : 'Discard')),
        ],
      ),
    );
    if (sure == true) await _git.discard(c);
  }

  Future<void> _pickBranch(BuildContext button) async {
    final branches = await _git.branches();
    if (!button.mounted) return;
    final box = button.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final picked = await showMenu<String>(
      context: button,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + box.size.width, at.dy),
      items: [
        for (final b in branches) CheckedPopupMenuItem(value: b, checked: b == _git.branch, child: Text(b)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '', child: Text('New branch…')),
      ],
    );
    if (picked == null) return;
    picked.isEmpty ? await _newBranch() : await _git.switchTo(picked);
  }

  Future<void> _newBranch() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New branch'),
        content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Create')),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.trim().isNotEmpty) await _git.switchTo(name.trim(), create: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _git,
      builder: (_, _) {
        if (!_git.isRepo) {
          return Center(child: Text('Not a git repository', style: TextStyle(color: scheme.outline, fontSize: 13)));
        }
        final staged = _git.staged, unstaged = _git.unstaged;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _branchBar(scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: TextField(
                controller: _message,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(isDense: true, hintText: 'Commit message', border: OutlineInputBorder()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ListenableBuilder(
                listenable: _message,
                builder: (_, _) => FilledButton(
                  onPressed: _git.busy || staged.isEmpty || _message.text.trim().isEmpty ? null : _commit,
                  child: Text(staged.isEmpty ? 'Stage files to commit' : 'Commit ${staged.length} file(s)'),
                ),
              ),
            ),
            if (_git.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: SelectableText(_git.error!, maxLines: 5, style: TextStyle(fontSize: 12, color: scheme.error)),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                children: [
                  if (staged.isNotEmpty) ...[
                    _heading('Staged', staged.length, scheme, Icons.remove, 'Unstage all', () => _git.unstage(staged)),
                    for (final c in staged) _row(c, true, scheme),
                  ],
                  _heading('Changes', unstaged.length, scheme, Icons.add, 'Stage all', unstaged.isEmpty ? null : () => _git.stage(unstaged)),
                  for (final c in unstaged) _row(c, false, scheme),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _branchBar(ColorScheme scheme) => SizedBox(
    height: 34,
    child: Row(
      children: [
        Expanded(
          child: Builder(
            builder: (button) => InkWell(
              onTap: () => _pickBranch(button),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Icon(Icons.call_split, size: 15, color: scheme.outline),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _git.branch ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (_git.ahead > 0 || _git.behind > 0)
                      Text('  ↑${_git.ahead} ↓${_git.behind}', style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Pull',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: _git.busy || !_git.hasUpstream ? null : _git.pull,
          icon: const Icon(Icons.download),
        ),
        IconButton(
          tooltip: _git.hasUpstream ? 'Push' : 'Push and track on origin',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: _git.busy ? null : _git.push,
          icon: const Icon(Icons.upload),
        ),
        IconButton(
          tooltip: 'Refresh',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          onPressed: _git.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );

  Widget _heading(String title, int count, ColorScheme scheme, IconData icon, String tip, VoidCallback? onPressed) => Padding(
    padding: const EdgeInsets.only(left: 8, top: 4),
    child: Row(
      children: [
        Expanded(
          child: Text('$title ($count)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.outline)),
        ),
        IconButton(tooltip: tip, iconSize: 15, visualDensity: VisualDensity.compact, onPressed: _git.busy ? null : onPressed, icon: Icon(icon)),
      ],
    ),
  );

  Widget _row(GitChange c, bool staged, ColorScheme scheme) {
    final status = staged ? c.index : c.worktree;
    return InkWell(
      onTap: () => widget.onDiff(c, staged),
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: Text(
                status == '?' ? 'U' : status,
                style: TextStyle(fontFamily: 'Consolas', fontSize: 12.5, fontWeight: FontWeight.w700, color: _statusColor(status)),
              ),
            ),
            Expanded(
              child: Tooltip(
                message: c.path,
                child: Text(p.posix.basename(c.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ),
            ),
            if (!staged)
              IconButton(
                tooltip: c.untracked ? 'Delete file' : 'Discard changes',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                onPressed: _git.busy ? null : () => _discard(c),
                icon: const Icon(Icons.undo),
              ),
            IconButton(
              tooltip: staged ? 'Unstage' : 'Stage',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              onPressed: _git.busy ? null : () => staged ? _git.unstage([c]) : _git.stage([c]),
              icon: Icon(staged ? Icons.remove : Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.title, required this.lines, required this.onLine});

  final String title;
  final List<DiffLine> lines;
  final ValueChanged<int> onLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (lines.isEmpty) {
      return Center(
        child: Text(title.isEmpty ? 'Pick a changed file in Source Control.' : 'No differences in $title.', style: TextStyle(color: scheme.outline)),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        itemCount: lines.length,
        itemExtent: 19,
        itemBuilder: (_, i) {
          final l = lines[i];
          final (bg, fg) = switch (l.kind) {
            DiffKind.added => (const Color(0x2622C55E), scheme.onSurface),
            DiffKind.removed => (const Color(0x26EF4444), scheme.onSurface),
            DiffKind.hunk => (scheme.primary.withValues(alpha: .08), scheme.primary),
            DiffKind.header => (null, scheme.outline),
            DiffKind.context => (null, scheme.onSurface),
          };
          final text = Container(
            color: bg,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Text(l.text, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: TextStyle(fontFamily: 'Consolas', fontSize: 12.5, color: fg)),
          );
          final line = l.line;
          return line == null ? text : InkWell(onTap: () => onLine(line), child: text);
        },
      ),
    );
  }
}
