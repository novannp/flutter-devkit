import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'core_deps.dart';

/// Result of the dialog: switch to a git ref, point at a local folder, or drop the local override.
sealed class DepChange {
  const DepChange();
}

class UseRef extends DepChange {
  const UseRef(this.ref);
  final String ref;
}

class UseLocal extends DepChange {
  const UseLocal(this.folder);
  final String folder;
}

class UseGit extends DepChange {
  const UseGit();
}

Future<DepChange?> showCoreDepDialog(BuildContext context, {required String project, required CoreDep dep}) =>
    showDialog<DepChange>(
      context: context,
      builder: (_) => _CoreDepDialog(project: project, dep: dep),
    );

class _CoreDepDialog extends StatefulWidget {
  const _CoreDepDialog({required this.project, required this.dep});

  final String project;
  final CoreDep dep;

  @override
  State<_CoreDepDialog> createState() => _CoreDepDialogState();
}

class _CoreDepDialogState extends State<_CoreDepDialog> {
  late var _mode = widget.dep.localPath != null ? 1 : 0;
  late final _ref = TextEditingController(text: widget.dep.ref ?? '');
  List<String>? _branches;
  List<String> _clones = const [];
  String? _folder;

  @override
  void initState() {
    super.initState();
    _folder = widget.dep.localPath;
    final url = widget.dep.url;
    if (url != null) {
      CoreDeps.branches(url).then((b) => mounted ? setState(() => _branches = b) : null);
    } else {
      _branches = const [];
    }
    CoreDeps.localClones(widget.dep.name).then((c) {
      if (!mounted) return;
      setState(() {
        _clones = c;
        _folder ??= c.firstOrNull;
      });
    });
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use folder');
    if (path != null) setState(() => _folder = path);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.outline, fontSize: 12.5);
    final d = widget.dep;
    final branches = _branches;

    return AlertDialog(
      title: Text(d.name),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Now: ${d.localPath != null ? 'local override → ${d.localPath}' : 'git ${d.ref ?? '(default branch)'}'}',
              style: muted,
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.call_split, size: 18), label: Text('Git branch')),
                ButtonSegment(value: 1, icon: Icon(Icons.folder_open, size: 18), label: Text('Local folder')),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(height: 16),
            if (_mode == 0) ...[
              Autocomplete<String>(
                initialValue: TextEditingValue(text: _ref.text),
                optionsBuilder: (v) {
                  final q = v.text.toLowerCase();
                  return (branches ?? const <String>[]).where((b) => b.toLowerCase().contains(q)).take(40);
                },
                onSelected: (v) => _ref.text = v,
                fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
                  controller: ctrl,
                  focusNode: focus,
                  onChanged: (v) => _ref.text = v,
                  decoration: InputDecoration(
                    labelText: 'Branch, tag or commit',
                    suffixIcon: branches == null
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                branches == null
                    ? 'Loading branches…'
                    : branches.isEmpty
                    ? 'Couldn\'t list remote branches (SSH key / URL) — type the name.'
                    : '${branches.length} branches on the remote. Updates `ref:` in pubspec.yaml.',
                style: muted,
              ),
            ] else ...[
              if (_clones.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in _clones)
                      ChoiceChip(
                        label: Text(c),
                        selected: _folder == c,
                        onSelected: (_) => setState(() => _folder = c),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text(_folder ?? 'No local clone found in your project folders', style: muted)),
                  TextButton.icon(
                    onPressed: _browse,
                    icon: const Icon(Icons.folder, size: 16),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Written to pubspec_overrides.yaml — pubspec.yaml stays untouched.', style: muted),
            ],
          ],
        ),
      ),
      actions: [
        if (d.localPath != null)
          TextButton(
            onPressed: () => Navigator.pop(context, const UseGit()),
            child: const Text('Remove local override'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _mode == 0
              ? () {
                  final ref = _ref.text.trim();
                  if (ref.isNotEmpty) Navigator.pop(context, UseRef(ref));
                }
              : _folder == null
              ? null
              : () => Navigator.pop(context, UseLocal(_folder!)),
          child: const Text('Apply & pub upgrade'),
        ),
      ],
    );
  }
}
