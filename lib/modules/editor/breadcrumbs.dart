import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import 'editor_workspace.dart';
import 'file_tree.dart' show fileIconOf;

/// A folder's contents for browsing: folders first, each part by name, without git's own folder.
List<FileSystemEntity> folderEntries(String folder) {
  final List<FileSystemEntity> all;
  try {
    all = Directory(folder).listSync().where((e) => p.basename(e.path) != '.git').toList();
  } on FileSystemException {
    return const [];
  }
  int byName(FileSystemEntity a, FileSystemEntity b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
  return [...all.whereType<Directory>().toList()..sort(byName), ...all.whereType<File>().toList()..sort(byName)];
}

(IconData, Color) _symbolIcon(int kind) => switch (kind) {
  5 || 11 || 23 => (Icons.data_object, const Color(0xFFEE9D28)),
  6 || 9 || 12 => (Icons.functions, const Color(0xFFB180D7)),
  7 || 8 => (Icons.label_outline, const Color(0xFF75BEFF)),
  10 || 22 => (Icons.format_list_bulleted, const Color(0xFFEE9D28)),
  13 || 14 => (Icons.short_text, const Color(0xFF75BEFF)),
  _ => (Icons.category_outlined, const Color(0xFF90A4AE)),
};

/// The code editor notifies its controller while it's being built, and this bar sits above it in the tree.
class RebuildAfterFrame extends StatefulWidget {
  const RebuildAfterFrame({super.key, required this.listenable, required this.builder});

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<RebuildAfterFrame> createState() => RebuildAfterFrameState();
}

class RebuildAfterFrameState extends State<RebuildAfterFrame> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(RebuildAfterFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget.listenable.removeListener(_changed);
    widget.listenable.addListener(_changed);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      if (mounted) setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// VS Code's strip above the code: folders, the file, then the symbols around the caret.
class BreadcrumbBar extends StatelessWidget {
  const BreadcrumbBar({super.key, required this.root, required this.doc, required this.onReveal, required this.onOpenFile});

  final String root;
  final EditorDocument doc;
  final void Function(int line, int column) onReveal;
  final ValueChanged<String> onOpenFile;

  /// What's in a folder, as a menu. Picking a folder goes on into it, from the same spot.
  Future<void> _browse(BuildContext button, String folder) async {
    final entries = folderEntries(folder);
    if (!button.mounted) return;
    final box = button.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final scheme = Theme.of(button).colorScheme;
    final picked = await showMenu<FileSystemEntity>(
      context: button,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + box.size.width, at.dy),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 420, maxHeight: 420),
      menuPadding: const EdgeInsets.symmetric(vertical: 3),
      items: [
        if (entries.isEmpty)
          PopupMenuItem(enabled: false, height: 28, child: Text('Empty folder', style: TextStyle(fontSize: 13, color: scheme.outline))),
        for (final e in entries)
          PopupMenuItem(
            value: e,
            height: 26,
            child: Row(
              children: [
                if (e is Directory)
                  const Icon(Icons.folder, size: 15, color: Color(0xFFE8A93A))
                else
                  Icon(fileIconOf(e.path).$1, size: 15, color: fileIconOf(e.path).$2 ?? scheme.outline),
                const SizedBox(width: 8),
                Flexible(child: Text(p.basename(e.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                if (e is Directory) Icon(Icons.chevron_right, size: 14, color: scheme.outline),
              ],
            ),
          ),
      ],
    );
    if (picked is Directory) {
      if (button.mounted) await _browse(button, picked.path);
    } else if (picked != null) {
      onOpenFile(picked.path);
    }
  }

  Future<void> _pick(BuildContext button, List<DocSymbol> siblings) async {
    final box = button.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final picked = await showMenu<DocSymbol>(
      context: button,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + box.size.width, at.dy),
      items: [
        for (final s in siblings)
          PopupMenuItem(
            value: s,
            height: 30,
            child: Row(
              children: [
                Icon(_symbolIcon(s.kind).$1, size: 15, color: _symbolIcon(s.kind).$2),
                const SizedBox(width: 8),
                Text(s.name, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onReveal(picked.line, picked.column);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);
    final chevron = Icon(Icons.chevron_right, size: 15, color: scheme.outline);
    // Outside the project a relative path is all "..", so the end of the real one says more.
    final inside = p.isWithin(root, doc.path);
    final parts = inside ? p.split(p.relative(doc.path, from: root)) : p.split(doc.path).reversed.take(4).toList().reversed.toList();
    final base = inside ? root : p.joinAll(p.split(doc.path).reversed.skip(4).toList().reversed);
    return Material(
      color: scheme.surface,
      child: Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: RebuildAfterFrame(
        listenable: Listenable.merge([doc, doc.controller]),
        builder: (_) {
          final sel = doc.controller.selection;
          final chain = symbolChainAt(doc.symbols, sel.extentIndex, sel.extentOffset);
          var siblings = doc.symbols;
          final (fileIcon, fileColor) = fileIconOf(doc.path);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // The innermost symbol matters most, so a long path gives way on the left.
            reverse: true,
            child: Row(
              children: [
                if (!inside) ...[Text('…', style: style), chevron],
                for (final (i, part) in parts.indexed) ...[
                  if (i > 0) chevron,
                  Builder(
                    builder: (button) => InkWell(
                      borderRadius: BorderRadius.circular(4),
                      // A folder lists itself; the file lists the folder it's in.
                      onTap: () => _browse(button, p.joinAll([base, ...parts.take(i == parts.length - 1 ? i : i + 1)])),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Row(
                          children: [
                            if (i == parts.length - 1) ...[Icon(fileIcon, size: 14, color: fileColor ?? scheme.outline), const SizedBox(width: 4)],
                            Text(part, style: style),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                for (final s in chain) ...[
                  chevron,
                  Builder(
                    builder: (button) {
                      final around = siblings;
                      siblings = s.children;
                      final (icon, color) = _symbolIcon(s.kind);
                      return InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => _pick(button, around),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Row(
                            children: [
                              Icon(icon, size: 14, color: color),
                              const SizedBox(width: 4),
                              Text(s.name, style: style),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          );
        },
      ),
      ),
    );
  }
}
