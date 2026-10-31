import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/files.dart';
import '../../services/device_adb.dart';

class _RemoteFile {
  const _RemoteFile(this.name, {required this.isDir, required this.size, required this.modified});

  final String name;
  final bool isDir;
  final int size;
  final String modified;
}

class FilesTab extends StatefulWidget {
  const FilesTab({super.key, required this.dev, required this.dir, required this.refresh});

  final DeviceAdb dev;
  final ValueNotifier<String> dir;
  final ValueNotifier<int> refresh;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  List<_RemoteFile>? _files;
  String? _error;

  String get _dir => widget.dir.value;

  @override
  void initState() {
    super.initState();
    widget.dir.addListener(_load);
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.dir.removeListener(_load);
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  String _quote(String path) => "'${path.replaceAll("'", r"'\''")}'";

  Future<void> _load() async {
    setState(() => _files = null);
    // Trailing slash so symlinks like /sdcard list their contents.
    final r = await widget.dev.shell('ls -la ${_quote('$_dir/')}');
    if (!mounted) return;
    // toybox format: perms links owner group size date time name
    final re = RegExp(r'^([dl-])\S+\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\S+ \S+)\s+(.+)$');
    final files = <_RemoteFile>[];
    for (final line in r.stdout.split('\n')) {
      final m = re.firstMatch(line.trim());
      if (m == null) continue;
      final name = m[4]!.split(' -> ').first;
      if (name == '.' || name == '..') continue;
      files.add(_RemoteFile(name, isDir: m[1] != '-', size: int.parse(m[2]!), modified: m[3]!));
    }
    files.sort((a, b) => a.isDir != b.isDir ? (a.isDir ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    setState(() {
      _files = files;
      _error = r.ok ? null : r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim();
    });
  }

  void _open(String path) => widget.dir.value = path;

  void _up() {
    if (_dir == '/') return;
    final parent = _dir.substring(0, _dir.lastIndexOf('/'));
    _open(parent.isEmpty ? '/' : parent);
  }

  String _join(String name) => _dir == '/' ? '/$name' : '$_dir/$name';

  void _toast(String text, {SnackBarAction? action}) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text), action: action, behavior: SnackBarBehavior.floating, width: 520));

  Future<void> _pull(_RemoteFile f) async {
    final dir = await outputDir();
    final local = '${dir.path}${Platform.pathSeparator}${f.name}';
    final r = await widget.dev.pull(_join(f.name), local);
    if (!mounted) return;
    r.ok
        ? _toast('Saved to $local',
            action: SnackBarAction(label: 'Open folder', onPressed: () => revealInExplorer(local)))
        : _toast('Pull failed: ${r.stderr.trim()}');
  }

  Future<void> _delete(_RemoteFile f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${f.name}?'),
        content: Text(_join(f.name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.dev.shell('rm -rf ${_quote(_join(f.name))}');
    _load();
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final scheme = Theme.of(context).colorScheme;
    const shortcuts = {'Download': '/sdcard/Download', 'DCIM': '/sdcard/DCIM', 'sdcard': '/sdcard', 'tmp': '/data/local/tmp'};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(tooltip: 'Up', onPressed: _up, icon: const Icon(Icons.arrow_upward)),
              Expanded(child: SelectableText(_dir, style: const TextStyle(fontFamily: 'Consolas'))),
              for (final s in shortcuts.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ActionChip(label: Text(s.key), onPressed: () => _open(s.value)),
                ),
              IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Drag files onto this window to upload to this folder.',
              style: TextStyle(color: scheme.outline, fontSize: 12)),
        ),
        const Divider(),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: TextStyle(color: scheme.error))),
        Expanded(
          child: files == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (_, i) {
                    final f = files[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(f.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                          color: f.isDir ? Colors.amber.shade700 : null),
                      title: Text(f.name),
                      subtitle: Text(f.isDir ? f.modified : '${_size(f.size)} · ${f.modified}'),
                      onTap: f.isDir ? () => _open(_join(f.name)) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!f.isDir)
                            IconButton(
                              tooltip: 'Download to PC',
                              icon: const Icon(Icons.download),
                              onPressed: () => _pull(f),
                            ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(f),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
