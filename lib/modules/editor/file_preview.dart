import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/files.dart';
import '../../core/mono_font.dart';
import '../../core/native_bridge.dart';
import '../../extensions/work/work_service.dart' show openUrl;
import 'editor_workspace.dart';
import 'markdown_view.dart';
import 'preview_kind.dart';
import 'svg_view.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// CSV as spreadsheets write it: quotes can hold separators, line breaks and doubled quotes.
List<List<String>> parseDelimited(String text, String separator, {int maxRows = 5000}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length && rows.length < maxRows; i++) {
    final c = text[i];
    if (quoted) {
      if (c != '"') {
        cell.write(c);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = false;
      }
    } else if (c == '"' && cell.isEmpty) {
      quoted = true;
    } else if (c == separator) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = [];
    } else if (c != '\r') {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) rows.add([...row, cell.toString()]);
  return rows;
}

class ZipEntry {
  const ZipEntry(this.name, this.size);

  final String name;
  final int size;
}

/// Only reads the archive's table of contents, at its end, so a large APK opens at once.
Future<List<ZipEntry>?> readZipEntries(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    final tail = min(length, 22 + 65535);
    await file.setPosition(length - tail);
    final end = ByteData.sublistView(await file.read(tail));
    var at = end.lengthInBytes - 22;
    while (at >= 0 && end.getUint32(at, Endian.little) != 0x06054b50) {
      at--;
    }
    if (at < 0) return null;
    final count = end.getUint16(at + 10, Endian.little);
    final size = end.getUint32(at + 12, Endian.little);
    final offset = end.getUint32(at + 16, Endian.little);
    if (offset + size > length) return null;
    await file.setPosition(offset);
    final bytes = await file.read(size);
    final table = ByteData.sublistView(bytes);
    final entries = <ZipEntry>[];
    var cursor = 0;
    for (var i = 0; i < count && cursor + 46 <= table.lengthInBytes; i++) {
      if (table.getUint32(cursor, Endian.little) != 0x02014b50) break;
      final nameLength = table.getUint16(cursor + 28, Endian.little);
      final extra = table.getUint16(cursor + 30, Endian.little);
      final comment = table.getUint16(cursor + 32, Endian.little);
      if (cursor + 46 + nameLength > bytes.length) break;
      entries.add(ZipEntry(utf8.decode(bytes.sublist(cursor + 46, cursor + 46 + nameLength), allowMalformed: true), table.getUint32(cursor + 24, Endian.little)));
      cursor += 46 + nameLength + extra + comment;
    }
    return entries;
  } finally {
    await file.close();
  }
}

String hexDump(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 16) {
    final row = bytes.sublist(i, min(i + 16, bytes.length));
    final hex = [for (final b in row) b.toRadixString(16).padLeft(2, '0')].join(' ').padRight(47);
    final text = String.fromCharCodes([for (final b in row) b >= 32 && b < 127 ? b : 46]);
    out.writeln('${i.toRadixString(16).padLeft(8, '0')}  $hex  $text');
  }
  return out.toString();
}

/// What a tab shows instead of its code. Text kinds follow the unsaved text; binary ones follow the file.
class FilePreview extends StatelessWidget {
  const FilePreview({super.key, required this.doc});

  final EditorDocument doc;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([doc, doc.controller]),
    builder: (context, _) {
      final kind = doc.binary && !previewKindOf(doc.path).onlyPreview ? PreviewKind.binary : previewKindOf(doc.path);
      final stamp = ValueKey(doc.modified);
      return switch (kind) {
        PreviewKind.image => _ImagePreview(key: stamp, path: doc.path),
        PreviewKind.pdf => _PdfPreview(key: stamp, path: doc.path),
        PreviewKind.font => _FontPreview(key: stamp, path: doc.path),
        PreviewKind.archive => _ArchivePreview(key: stamp, path: doc.path),
        PreviewKind.binary => _BinaryPreview(key: stamp, path: doc.path),
        PreviewKind.svg => _SvgPreview(text: doc.controller.text),
        PreviewKind.markdown => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: MarkdownView(doc.controller.text, document: true, baseDir: p.dirname(doc.path)),
            ),
          ),
        ),
        PreviewKind.table => _TablePreview(rows: parseDelimited(doc.controller.text, p.extension(doc.path).toLowerCase() == '.tsv' ? '\t' : ',')),
        PreviewKind.json => _JsonPreview(text: doc.controller.text),
        PreviewKind.none => const SizedBox.shrink(),
      };
    },
  );
}

class _InfoBar extends StatelessWidget {
  const _InfoBar({required this.text, this.path, this.actions = const []});

  final String text;
  final String? path;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 12, right: 4),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
          ...actions,
          if (path case final path?) ...[
            IconButton(tooltip: 'Open with the default app', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => openUrl(path), icon: const Icon(Icons.open_in_new)),
            IconButton(tooltip: 'Show in folder', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => revealInExplorer(path), icon: const Icon(Icons.folder_open_outlined)),
          ],
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(message, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
    ),
  );
}

class _Checkerboard extends CustomPainter {
  const _Checkerboard(this.a, this.b);

  final Color a, b;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = a);
    final paint = Paint()..color = b;
    const cell = 10.0;
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = y.isEven ? 0 : 1; x * cell < size.width; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => old.a != a || old.b != b;
}

Widget _onCheckerboard(BuildContext context, Widget child) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return CustomPaint(
    painter: dark ? const _Checkerboard(Color(0xFF26282C), Color(0xFF303338)) : const _Checkerboard(Color(0xFFFFFFFF), Color(0xFFEDEEF0)),
    child: SizedBox.expand(
      child: InteractiveViewer(
        minScale: .1,
        maxScale: 32,
        child: Center(child: Padding(padding: const EdgeInsets.all(16), child: child)),
      ),
    ),
  );
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({super.key, required this.path});

  final String path;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  String? _size;
  var _failed = false;
  late final Future<Uint8List> _bytes = File(widget.path).readAsBytes();

  @override
  void initState() {
    super.initState();
    _describe();
  }

  Future<void> _describe() async {
    try {
      final bytes = await _bytes;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final text = '${frame.image.width} × ${frame.image.height}  •  ${formatBytes(bytes.length)}';
      frame.image.dispose();
      codec.dispose();
      if (mounted) setState(() => _size = text);
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const _Failed("This image couldn't be read. It may be damaged, or in a format Flutter can't decode.");
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoBar(text: _size ?? '', path: widget.path),
        Expanded(
          child: FutureBuilder(
            future: _bytes,
            builder: (context, snap) => snap.data == null
                ? const SizedBox.shrink()
                : _onCheckerboard(context, Image.memory(snap.data!, gaplessPlayback: true, errorBuilder: (_, _, _) => const _Failed("This image couldn't be read."))),
          ),
        ),
      ],
    );
  }
}

class _SvgPreview extends StatelessWidget {
  const _SvgPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final image = parseSvg(text);
    if (image == null) return const _Failed('This file has no <svg> to show.');
    final box = image.viewBox;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoBar(text: '${box.width.round()} × ${box.height.round()}  •  ${image.shapes.length} shapes  •  Text and filters are not drawn, and gradients show their first color'),
        Expanded(
          child: _onCheckerboard(
            context,
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640), child: SvgView(image)),
          ),
        ),
      ],
    );
  }
}

class _PdfPreview extends StatefulWidget {
  const _PdfPreview({super.key, required this.path});

  final String path;

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  // Drawn once at print-like size; zoom only scales the picture.
  static const _renderWidth = 1600;
  final _pages = <int, Uint8List>{};
  int? _count;
  var _aspect = 1.414;
  String? _error;
  var _zoom = 1.0;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int page) async {
    try {
      final result = await NativeBridge.renderPdf(widget.path, page, _renderWidth);
      if (!mounted) return;
      if (_count == null) {
        final codec = await ui.instantiateImageCodec(result.png);
        final frame = await codec.getNextFrame();
        _aspect = frame.image.height / max(1, frame.image.width);
        frame.image.dispose();
        codec.dispose();
      }
      if (!mounted) return;
      setState(() {
        _count = result.pages;
        _pages[page] = result.png;
      });
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error ??= e.message ?? "This PDF couldn't be opened.");
    } on MissingPluginException {
      if (mounted) setState(() => _error ??= "PDF preview isn't available here.");
    } on Exception {
      if (mounted) setState(() => _error ??= "This PDF couldn't be opened.");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final error?) return _Failed(error);
    final count = _count;
    if (count == null) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoBar(
          text: '$count ${count == 1 ? 'page' : 'pages'}  •  ${(_zoom * 100).round()}%',
          path: widget.path,
          actions: [
            IconButton(tooltip: 'Zoom out', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => setState(() => _zoom = max(.4, _zoom - .2)), icon: const Icon(Icons.remove)),
            IconButton(tooltip: 'Zoom in', iconSize: 15, visualDensity: VisualDensity.compact, onPressed: () => setState(() => _zoom = min(3, _zoom + .2)), icon: const Icon(Icons.add)),
          ],
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: LayoutBuilder(
              builder: (context, box) {
                final width = (min(box.maxWidth - 32, 860.0) * _zoom).clamp(120.0, 4000.0);
                return Scrollbar(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: max(box.maxWidth, width + 32),
                      height: box.maxHeight,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        itemCount: count,
                        itemExtent: width * _aspect + 12,
                        itemBuilder: (_, i) {
                          final png = _pages[i];
                          if (png == null) _load(i);
                          return Align(
                            alignment: Alignment.topCenter,
                            child: Container(
                              width: width,
                              height: width * _aspect,
                              color: Colors.white,
                              child: png == null ? null : Image.memory(png, fit: BoxFit.contain, gaplessPlayback: true),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _TablePreview extends StatelessWidget {
  const _TablePreview({required this.rows});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _Failed('This file is empty.');
    final scheme = Theme.of(context).colorScheme;
    final columns = rows.fold<int>(0, (most, r) => max(most, r.length));
    final widths = List<double>.generate(columns, (c) {
      var longest = 0;
      for (final r in rows.take(200)) {
        if (c < r.length) longest = max(longest, r[c].length);
      }
      return (longest * 7.5 + 20).clamp(60.0, 320.0);
    });
    final total = widths.fold<double>(0, (a, b) => a + b);
    Widget row(List<String> cells, {bool head = false}) => Row(
      children: [
        for (var c = 0; c < columns; c++)
          Container(
            width: widths[c],
            height: 26,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(border: Border(right: BorderSide(color: scheme.outlineVariant), bottom: BorderSide(color: scheme.outlineVariant))),
            child: Text(
              c < cells.length ? cells[c] : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: head ? FontWeight.w700 : null),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoBar(text: '${rows.length - 1} rows  •  $columns columns${rows.length >= 5000 ? '  •  Showing the first 5000 rows' : ''}'),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total,
              child: Column(
                children: [
                  ColoredBox(color: scheme.surfaceContainerLow, child: row(rows.first, head: true)),
                  Expanded(child: ListView.builder(itemCount: rows.length - 1, itemExtent: 26, itemBuilder: (_, i) => row(rows[i + 1]))),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _JsonPreview extends StatefulWidget {
  const _JsonPreview({required this.text});

  final String text;

  @override
  State<_JsonPreview> createState() => _JsonPreviewState();
}

class _JsonPreviewState extends State<_JsonPreview> {
  final _closed = <String>{};

  void _flatten(String path, String? key, Object? value, int depth, List<(String, String?, Object?, int)> out) {
    out.add((path, key, value, depth));
    if (_closed.contains(path)) return;
    if (value is Map) {
      for (final e in value.entries) {
        _flatten('$path/${e.key}', '${e.key}', e.value, depth + 1, out);
      }
    } else if (value is List) {
      for (final (i, v) in value.indexed) {
        _flatten('$path/$i', '$i', v, depth + 1, out);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Object? root;
    try {
      root = jsonDecode(widget.text);
    } on FormatException catch (e) {
      return _Failed('Not valid JSON: ${e.message}');
    }
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String?, Object?, int)>[];
    _flatten('', null, root, 0, rows);
    const mono = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 13);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      itemExtent: 22,
      itemBuilder: (_, i) {
        final (path, key, value, depth) = rows[i];
        final branch = value is Map || value is List;
        final summary = switch (value) {
          final Map m => '{ ${m.length} }',
          final List l => '[ ${l.length} ]',
          final String s => jsonEncode(s),
          _ => '$value',
        };
        return InkWell(
          onTap: branch ? () => setState(() => _closed.contains(path) ? _closed.remove(path) : _closed.add(path)) : null,
          child: Padding(
            padding: EdgeInsets.only(left: 8.0 + depth * 16),
            child: Row(
              children: [
                SizedBox(width: 16, child: branch ? Icon(_closed.contains(path) ? Icons.chevron_right : Icons.expand_more, size: 15, color: scheme.outline) : null),
                if (key != null) Text('$key: ', style: mono.copyWith(color: scheme.primary)),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(color: branch ? scheme.outline : null),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FontPreview extends StatefulWidget {
  const _FontPreview({super.key, required this.path});

  final String path;

  @override
  State<_FontPreview> createState() => _FontPreviewState();
}

class _FontPreviewState extends State<_FontPreview> {
  static var _loaded = 0;
  late final String _family = 'preview_font_${_loaded++}';
  var _ready = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await (FontLoader(_family)..addFont(File(widget.path).readAsBytes().then(ByteData.sublistView))).load();
      if (mounted) setState(() => _ready = true);
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const _Failed("This font couldn't be read.");
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoBar(text: p.basename(widget.path), path: widget.path),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (final size in const [48.0, 32.0, 22.0, 16.0, 12.0])
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text('The quick brown fox jumps over the lazy dog', style: TextStyle(fontFamily: _family, fontSize: size)),
                ),
              Text('ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 !?@#\$%&*()[]{}<>', style: TextStyle(fontFamily: _family, fontSize: 22)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArchivePreview extends StatelessWidget {
  const _ArchivePreview({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ZipEntry>?>(
    future: readZipEntries(path),
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      final entries = snap.data;
      if (entries == null) return const _Failed("This archive couldn't be read.");
      final scheme = Theme.of(context).colorScheme;
      final total = entries.fold<int>(0, (sum, e) => sum + e.size);
      final sorted = [...entries]..sort((a, b) => a.name.compareTo(b.name));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoBar(text: '${entries.length} files  •  ${formatBytes(total)} unpacked  •  ${formatBytes(File(path).lengthSync())} on disk', path: path),
          Expanded(
            child: ListView.builder(
              itemCount: sorted.length,
              itemExtent: 24,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(child: Text(sorted[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
                    Text(formatBytes(sorted[i].size), style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _BinaryPreview extends StatelessWidget {
  const _BinaryPreview({super.key, required this.path});

  final String path;
  static const _shown = 4096;

  Future<(int, Uint8List)> _read() async {
    final file = await File(path).open();
    try {
      return (await file.length(), await file.read(_shown));
    } finally {
      await file.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _read(),
    builder: (context, snap) {
      if (snap.hasError) return const _Failed("This file couldn't be read.");
      final data = snap.data;
      if (data == null) return const Center(child: CircularProgressIndicator());
      final (length, bytes) = data;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoBar(text: 'Binary file  •  ${formatBytes(length)}${length > _shown ? '  •  Showing the first ${formatBytes(_shown)}' : ''}', path: path),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(hexDump(bytes), style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, height: 1.4)),
            ),
          ),
        ],
      );
    },
  );
}
