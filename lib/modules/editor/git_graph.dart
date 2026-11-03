import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/mono_font.dart';
import 'source_control.dart';

class GraphCommit {
  const GraphCommit(this.hash, this.parents, this.refs, this.author, this.when, this.subject);

  final String hash;
  final List<String> parents;
  final List<String> refs;
  final String author, when, subject;

  String get short => hash.length > 7 ? hash.substring(0, 7) : hash;

  /// The local branches here, which are what can be switched to.
  List<String> branches(List<String> local) => [for (final r in refs) if (local.contains(r.replaceFirst('HEAD -> ', ''))) r.replaceFirst('HEAD -> ', '')];
}

/// Reads `git log` with the fields of [graphLogFormat].
List<GraphCommit> parseGraphLog(String log) => [
  for (final line in log.split('\n'))
    if (line.split('\x1f') case [final hash, final parents, final refs, final author, final age, ...final subject] when hash.trim().isNotEmpty)
      GraphCommit(
        hash.trim(),
        parents.split(' ').where((p) => p.isNotEmpty).toList(),
        refs.split(', ').where((r) => r.isNotEmpty).toList(),
        author,
        age,
        subject.join('\x1f').trimRight(),
      ),
];

/// One row of the drawing. Lanes are columns; a null lane is free.
class GraphRow {
  const GraphRow(this.commit, this.column, this.above, this.below);

  final GraphCommit commit;
  final int column;

  /// The columns coming in at the top of the row, and those going out at the bottom.
  /// A column that ends at this commit, or starts from it, joins its dot.
  final List<(int, bool)> above, below;

  int get width => [column, ...above.map((e) => e.$1), ...below.map((e) => e.$1)].fold(0, (most, c) => c > most ? c : most) + 1;
}

/// Each lane waits for the commit it leads to. Parents always come after their children in date order.
List<GraphRow> layoutGraph(List<GraphCommit> commits) {
  final lanes = <String?>[];
  int free() {
    final at = lanes.indexOf(null);
    if (at >= 0) return at;
    lanes.add(null);
    return lanes.length - 1;
  }

  final rows = <GraphRow>[];
  for (final c in commits) {
    final above = [
      for (final (i, wanted) in lanes.indexed)
        if (wanted != null) (i, wanted == c.hash),
    ];
    final known = lanes.indexOf(c.hash);
    final column = known >= 0 ? known : free();
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] == c.hash) lanes[i] = null;
    }
    final joined = <int>{};
    for (final (i, parent) in c.parents.indexed) {
      var lane = lanes.indexOf(parent);
      if (lane < 0) {
        // The first parent carries the branch straight on.
        lane = i == 0 && lanes[column.clamp(0, lanes.length - 1)] == null ? column : free();
        lanes[lane] = parent;
      }
      joined.add(lane);
    }
    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
    }
    rows.add(GraphRow(c, column, above, [
      for (final (i, wanted) in lanes.indexed)
        if (wanted != null) (i, joined.contains(i)),
    ]));
  }
  return rows;
}

const _laneColors = [
  Color(0xFF10B981),
  Color(0xFF3B82F6),
  Color(0xFFF59E0B),
  Color(0xFFEC4899),
  Color(0xFF8B5CF6),
  Color(0xFF06B6D4),
  Color(0xFFEF4444),
  Color(0xFF84CC16),
];

const _laneWidth = 14.0, _rowHeight = 26.0;

class _RowPainter extends CustomPainter {
  const _RowPainter(this.row, this.background);

  final GraphRow row;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    double x(int column) => column * _laneWidth + _laneWidth / 2;
    final mid = size.height / 2;
    Paint line(int column) => Paint()
      ..color = _laneColors[column % _laneColors.length]
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final dot = Offset(x(row.column), mid);
    for (final (column, joins) in row.above) {
      final top = Offset(x(column), 0);
      if (joins) {
        canvas.drawPath(
          Path()
            ..moveTo(top.dx, top.dy)
            ..cubicTo(top.dx, mid * .6, dot.dx, mid * .4, dot.dx, dot.dy),
          line(column),
        );
      } else {
        canvas.drawLine(top, Offset(x(column), mid), line(column));
      }
    }
    for (final (column, joins) in row.below) {
      final bottom = Offset(x(column), size.height);
      if (joins) {
        canvas.drawPath(
          Path()
            ..moveTo(dot.dx, dot.dy)
            ..cubicTo(dot.dx, mid * 1.6, bottom.dx, mid * 1.4, bottom.dx, bottom.dy),
          line(column),
        );
      } else {
        canvas.drawLine(Offset(x(column), mid), bottom, line(column));
      }
    }
    canvas.drawCircle(dot, 4.5, Paint()..color = background);
    canvas.drawCircle(dot, 3.5, Paint()..color = _laneColors[row.column % _laneColors.length]);
  }

  @override
  bool shouldRepaint(_RowPainter old) => !identical(old.row, row) || old.background != background;
}

class GitGraphView extends StatefulWidget {
  const GitGraphView({super.key, required this.git});

  final SourceControl git;

  @override
  State<GitGraphView> createState() => _GitGraphViewState();
}

class _GitGraphViewState extends State<GitGraphView> {
  List<GraphRow>? _rows;
  var _local = const <String>[];
  var _log = '';
  String? _head;

  @override
  void initState() {
    super.initState();
    widget.git.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.git.removeListener(_load);
    super.dispose();
  }

  // Follows commits, pulls and branch switches, without redrawing when nothing moved.
  Future<void> _load() async {
    final log = await widget.git.graphLog();
    final local = await widget.git.branches();
    if (!mounted || (log == _log && widget.git.branch == _head && _rows != null)) return;
    setState(() {
      _log = log;
      _local = local;
      _head = widget.git.branch;
      _rows = layoutGraph(parseGraphLog(log));
    });
  }

  Future<void> _menu(Offset at, GraphCommit c) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(at);
    final picked = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(local.dx, local.dy, overlay.size.width - local.dx, overlay.size.height - local.dy),
      items: [
        for (final b in c.branches(_local))
          if (b != widget.git.branch) PopupMenuItem(height: 30, value: () => unawaited(widget.git.switchTo(b)), child: Text('Switch to $b', style: const TextStyle(fontSize: 13))),
        PopupMenuItem(height: 30, value: () => Clipboard.setData(ClipboardData(text: c.hash)), child: const Text('Copy commit hash', style: TextStyle(fontSize: 13))),
        PopupMenuItem(height: 30, value: () => Clipboard.setData(ClipboardData(text: c.subject)), child: const Text('Copy message', style: TextStyle(fontSize: 13))),
      ],
    );
    picked?.call();
  }

  Widget _ref(String ref, ColorScheme scheme) {
    final head = ref.startsWith('HEAD -> ') || ref == 'HEAD';
    final name = ref.replaceFirst('HEAD -> ', '').replaceFirst('tag: ', '');
    final tag = ref.startsWith('tag: ');
    final remote = !head && !tag && name.contains('/') && !_local.contains(name);
    final color = tag ? const Color(0xFFD97706) : (remote ? scheme.outline : scheme.primary);
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(4),
        border: head ? Border.all(color: color) : null,
      ),
      child: Text(name, maxLines: 1, style: TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    if (rows == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    if (rows.isEmpty) return Center(child: Text('No commits yet.', style: TextStyle(color: scheme.outline, fontSize: 13)));
    final graphWidth = (rows.fold<int>(0, (most, r) => r.width > most ? r.width : most) * _laneWidth).clamp(_laneWidth, 280.0) + 6;
    final small = TextStyle(fontSize: 11.5, color: scheme.outline);
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: _rowHeight,
      itemBuilder: (_, i) {
        final row = rows[i], c = row.commit;
        return GestureDetector(
          onSecondaryTapDown: (d) => unawaited(_menu(d.globalPosition, c)),
          child: InkWell(
            onTap: () {},
            child: Row(
              children: [
                ClipRect(
                  child: SizedBox(
                    width: graphWidth,
                    height: _rowHeight,
                    child: CustomPaint(painter: _RowPainter(row, scheme.surface)),
                  ),
                ),
                for (final r in c.refs.take(4)) Flexible(flex: 0, child: _ref(r, scheme)),
                Expanded(
                  child: Tooltip(
                    message: '${c.subject}\n${c.short}  •  ${c.author}  •  ${c.when}',
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(c.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(width: 120, child: Text(c.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
                SizedBox(width: 92, child: Text(c.when, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
                SizedBox(
                  width: 62,
                  child: Text(c.short, maxLines: 1, style: small.copyWith(fontFamily: 'Consolas', fontFamilyFallback: monoFallback)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
