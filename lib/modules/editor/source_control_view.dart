import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'source_control.dart';
import '../../core/mono_font.dart';

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
        for (final b in branches) CheckedPopupMenuItem(height: 30, value: b, checked: b == _git.branch, child: Text(b)),
        const PopupMenuDivider(),
        const PopupMenuItem(height: 30, value: '', child: Text('New branch…')),
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
                  _heading('Changes', unstaged.length, scheme, Icons.add, 'Stage all', unstaged.isEmpty ? null : () => _git.stage(unstaged), extra: IconButton(
                    tooltip: 'Discard all changes',
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    onPressed: _git.busy || _git.changes.isEmpty ? null : () => confirmDiscardAll(context, _git),
                    icon: const Icon(Icons.undo),
                  )),
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
    height: 28,
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

  Widget _heading(String title, int count, ColorScheme scheme, IconData icon, String tip, VoidCallback? onPressed, {Widget? extra}) => Padding(
    padding: const EdgeInsets.only(left: 8, top: 4),
    child: Row(
      children: [
        Expanded(
          child: Text('$title ($count)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.outline)),
        ),
        ?extra,
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
                style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, fontWeight: FontWeight.w700, color: _statusColor(status)),
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

Future<void> confirmDiscardAll(BuildContext context, SourceControl git) async {
  final count = git.changes.length;
  if (count == 0) return;
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Discard all $count ${count == 1 ? 'change' : 'changes'}?'),
      content: const SizedBox(
        width: 420,
        child: Text('Staged and unstaged edits are undone, and new files are removed. A copy stays in git stash, so `git stash pop` brings it all back.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard All')),
      ],
    ),
  );
  if (sure == true) await git.discardAll();
}

/// Before and after next to each other, in one scroll so their lines stay level.
class SideBySideDiff extends StatefulWidget {
  const SideBySideDiff({super.key, required this.git, required this.change, required this.staged, required this.onLine});

  final SourceControl git;
  final GitChange change;
  final bool staged;

  /// Goes to a line of the current file.
  final ValueChanged<int> onLine;

  @override
  State<SideBySideDiff> createState() => _SideBySideDiffState();
}

class _SideBySideDiffState extends State<SideBySideDiff> {
  List<DiffRow>? _rows;
  var _onlyChanges = false;

  @override
  void initState() {
    super.initState();
    widget.git.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.git.removeListener(_load);
    super.dispose();
  }

  // Saves and git operations change the file, and the diff should say so.
  Future<void> _load() async {
    final rows = await widget.git.sideBySideOf(widget.change, staged: widget.staged);
    if (!mounted) return;
    final old = _rows;
    final same = old != null && old.length == rows.length && [for (var i = 0; i < rows.length; i++) old[i].before == rows[i].before && old[i].after == rows[i].after].every((x) => x);
    if (!same) setState(() => _rows = rows);
  }

  Widget _side(ColorScheme scheme, int? number, String text, Color? tint, {VoidCallback? onTap}) {
    final content = Container(
      color: number == null ? scheme.onSurface.withValues(alpha: .04) : tint,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              number == null ? '' : '${number + 1}',
              textAlign: TextAlign.right,
              style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12, color: scheme.outline),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: scheme.onSurface)),
          ),
        ],
      ),
    );
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = _rows;
    if (all == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    final rows = _onlyChanges ? all.where((r) => r.changed).toList() : all;
    Widget heading(String text) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 28,
            color: scheme.surfaceContainerLow,
            child: Row(
              children: [
                heading(widget.staged ? 'Before (HEAD)' : (widget.change.staged ? 'Before (staged)' : 'Before (HEAD)')),
                heading(widget.staged ? 'After (staged)' : 'After (working copy)'),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: _onlyChanges ? scheme.primary : scheme.onSurfaceVariant, textStyle: const TextStyle(fontSize: 12)),
                  onPressed: () => setState(() => _onlyChanges = !_onlyChanges),
                  child: const Text('Changes only'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text('No differences', style: TextStyle(color: scheme.outline)))
                : SelectionArea(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final r = rows[i];
                        final after = r.afterLine;
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _side(scheme, r.beforeLine, r.before, r.changed ? const Color(0x26EF4444) : null)),
                              VerticalDivider(width: 1, color: scheme.outlineVariant),
                              Expanded(
                                child: _side(
                                  scheme,
                                  after,
                                  r.after,
                                  r.changed ? const Color(0x2622C55E) : null,
                                  onTap: after == null ? null : () => widget.onLine(after),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
