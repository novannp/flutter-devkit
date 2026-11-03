import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/files.dart';

const _hidden = {'.git', '.dart_tool', '.idea', '.gradle'};

class _Row {
  const _Row(this.entity, this.depth);

  final FileSystemEntity entity;
  final int depth;

  bool get isDir => entity is Directory;
}

/// Lazy explorer: a folder is only read when it's expanded, so huge repos stay cheap.
class FileTree extends StatefulWidget {
  const FileTree({super.key, required this.root, required this.onOpen, required this.errorsIn, required this.isOpen});

  final String root;
  final ValueChanged<String> onOpen;
  final int Function(String path) errorsIn;
  final bool Function(String path) isOpen;

  @override
  State<FileTree> createState() => FileTreeState();
}

class FileTreeState extends State<FileTree> {
  final _expanded = <String>{};
  final _children = <String, List<FileSystemEntity>>{};
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _expanded.add(widget.root);
    final lib = p.join(widget.root, 'lib');
    if (Directory(lib).existsSync()) _expanded.add(lib);
    refresh();
  }

  @override
  void didUpdateWidget(FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) {
      _expanded
        ..clear()
        ..add(widget.root);
      refresh();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    _children.clear();
    for (final dir in _expanded.toList()) {
      await _read(dir);
    }
    if (mounted) setState(() {});
  }

  Future<void> _read(String dir) async {
    try {
      final items = await Directory(dir).list(followLinks: false).toList();
      items.removeWhere((e) => _hidden.contains(p.basename(e.path)));
      items.sort((a, b) {
        final da = a is Directory, db = b is Directory;
        if (da != db) return da ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
      _children[dir] = items;
    } on FileSystemException {
      _children[dir] = const [];
    }
  }

  Future<void> _toggle(String dir) async {
    if (_expanded.remove(dir)) {
      setState(() {});
      return;
    }
    _expanded.add(dir);
    await _read(dir);
    if (mounted) setState(() {});
  }

  List<_Row> _flatten(String dir, int depth) => [
    for (final e in _children[dir] ?? const <FileSystemEntity>[]) ...[
      _Row(e, depth),
      if (e is Directory && _expanded.contains(e.path)) ..._flatten(e.path, depth + 1),
    ],
  ];

  Future<String?> _askName(String title, {String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
    ctrl.dispose();
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on FileSystemException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e.message), width: 460, behavior: SnackBarBehavior.floating),
        );
      }
    }
    await refresh();
  }

  Future<void> _newFile(String dir) async {
    final name = await _askName('New file');
    if (name == null) return;
    final path = p.join(dir, name);
    await _guard(() async {
      if (File(path).existsSync()) throw const FileSystemException('That file already exists');
      await File(path).create(recursive: true);
      _expanded.add(dir);
    });
    if (File(path).existsSync()) widget.onOpen(path);
  }

  Future<void> _newFolder(String dir) async {
    final name = await _askName('New folder');
    if (name == null) return;
    await _guard(() async {
      await Directory(p.join(dir, name)).create(recursive: true);
      _expanded.add(dir);
    });
  }

  Future<void> _rename(FileSystemEntity e) async {
    final name = await _askName('Rename', initial: p.basename(e.path));
    if (name == null || name == p.basename(e.path)) return;
    await _guard(() async {
      final target = p.join(p.dirname(e.path), name);
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        throw const FileSystemException('That name is already taken');
      }
      await e.rename(target);
    });
  }

  Future<void> _delete(FileSystemEntity e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${p.basename(e.path)}?'),
        content: Text(
          e is Directory ? 'The folder and everything in it are deleted permanently.' : 'The file is deleted permanently.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _guard(() => e.delete(recursive: true));
  }

  Future<void> _menu(Offset at, FileSystemEntity? e) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final dir = e == null ? widget.root : (e is Directory ? e.path : p.dirname(e.path));
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(height: 30, value: 'file', child: Text('New file')),
        const PopupMenuItem(height: 30, value: 'folder', child: Text('New folder')),
        if (e != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(height: 30, value: 'rename', child: Text('Rename')),
          const PopupMenuItem(height: 30, value: 'delete', child: Text('Delete')),
          const PopupMenuDivider(),
          const PopupMenuItem(height: 30, value: 'copy', child: Text('Copy path')),
          const PopupMenuItem(height: 30, value: 'reveal', child: Text('Reveal in Explorer')),
        ],
      ],
    );
    switch (choice) {
      case 'file':
        await _newFile(dir);
      case 'folder':
        await _newFolder(dir);
      case 'rename':
        await _rename(e!);
      case 'delete':
        await _delete(e!);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e!.path));
      case 'reveal':
        await revealInExplorer(e!.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _flatten(widget.root, 0);
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Text(
                  'Files',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'New file',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _newFile(widget.root),
                  icon: const Icon(Icons.note_add_outlined),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapDown: (d) => _menu(d.globalPosition, null),
              child: ListView.builder(
                controller: _scroll,
                itemCount: rows.length,
                itemExtent: 30,
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final path = r.entity.path;
                  final errors = r.isDir ? 0 : widget.errorsIn(path);
                  final open = !r.isDir && widget.isOpen(path);
                  return GestureDetector(
                    onSecondaryTapDown: (d) => _menu(d.globalPosition, r.entity),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => r.isDir ? _toggle(path) : widget.onOpen(path),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: open ? scheme.primary.withValues(alpha: .14) : null,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        padding: EdgeInsets.only(left: r.depth * 12.0, right: 8),
                        child: Row(
                          children: [
                            // Files leave the chevron's space empty so names line up with their folder's.
                            if (r.isDir)
                              Icon(_expanded.contains(path) ? Icons.expand_more : Icons.chevron_right, size: 16, color: scheme.outline)
                            else
                              const SizedBox(width: 16),
                            const SizedBox(width: 2),
                            () {
                              final (icon, color) = r.isDir ? _folderIcon(path, _expanded.contains(path)) : fileIconOf(path);
                              return Icon(icon, size: 18, color: color ?? scheme.outline);
                            }(),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                p.basename(path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13.5, color: errors > 0 ? scheme.error : null),
                              ),
                            ),
                            if (errors > 0) Text('$errors', style: TextStyle(fontSize: 11, color: scheme.error)),
                          ],
                        ),
                      ),
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

const _folderColor = Color(0xFFE8A93A);

(IconData, Color?) _folderIcon(String path, bool open) => (
  switch (p.basename(path)) {
    'lib' || 'src' => open ? Icons.snippet_folder : Icons.snippet_folder_outlined,
    'test' || 'integration_test' => Icons.science_outlined,
    'assets' || 'images' => Icons.perm_media_outlined,
    'build' || '.dart_tool' || '.fvm' => Icons.folder_off_outlined,
    _ => open ? Icons.folder_open : Icons.folder,
  },
  _folderColor,
);

// Material has no Dart mark; tool/make_icon_font.py builds this one.
const _dartIcon = IconData(0xE000, fontFamily: 'DevKitIcons');

(IconData, Color?) fileIconOf(String path) {
  final name = p.basename(path).toLowerCase();
  return switch (name) {
    'pubspec.yaml' => (Icons.inventory_2_outlined, const Color(0xFF42A5F5)),
    'pubspec.lock' => (Icons.lock_outline, const Color(0xFF90A4AE)),
    '.gitignore' || '.gitattributes' => (Icons.call_split, const Color(0xFFF4511E)),
    'analysis_options.yaml' => (Icons.rule, const Color(0xFF42A5F5)),
    'readme.md' => (Icons.menu_book_outlined, const Color(0xFF42A5F5)),
    _ => switch (p.extension(name)) {
      '.dart' => (_dartIcon, const Color(0xFF40C4FF)),
      '.yaml' || '.yml' || '.toml' || '.ini' || '.properties' => (Icons.settings_outlined, const Color(0xFFAB47BC)),
      '.json' || '.arb' => (Icons.data_object, const Color(0xFFFBC02D)),
      '.md' => (Icons.article_outlined, const Color(0xFF42A5F5)),
      '.png' || '.jpg' || '.jpeg' || '.webp' || '.svg' || '.ico' || '.gif' => (Icons.image_outlined, const Color(0xFF26A69A)),
      '.kt' || '.kts' || '.java' || '.gradle' => (Icons.android, const Color(0xFF66BB6A)),
      '.swift' || '.plist' => (Icons.apple, const Color(0xFFEF6C00)),
      '.cpp' || '.cc' || '.c' || '.h' || '.cmake' => (Icons.memory, const Color(0xFF5C6BC0)),
      '.xml' || '.html' => (Icons.code_off, const Color(0xFFEF6C00)),
      '.js' || '.ts' || '.css' => (Icons.javascript, const Color(0xFFFBC02D)),
      '.sh' || '.bat' || '.ps1' => (Icons.terminal, const Color(0xFF8BC34A)),
      '.exe' || '.dll' || '.so' => (Icons.widgets_outlined, null),
      _ => (Icons.insert_drive_file_outlined, null),
    },
  };
}
