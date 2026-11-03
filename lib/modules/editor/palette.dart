import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform_keys.dart';

class PaletteItem {
  const PaletteItem(this.label, this.onPick, {this.detail, this.keys, this.icon, this.group});

  final String label;
  final String? detail, keys;

  /// The heading it sits under. Searching finds this too, so "flutter pub" works.
  final String? group;
  final IconData? icon;
  final VoidCallback onPick;
}

/// For an LSP symbol kind.
IconData symbolIcon(int kind) => switch (kind) {
  5 || 11 || 23 => Icons.category_outlined,
  6 || 9 || 12 => Icons.functions,
  7 || 8 || 13 || 14 => Icons.label_outline,
  10 || 22 => Icons.format_list_bulleted,
  _ => Icons.data_object,
};

bool _isSubsequence(String word, String text) {
  var at = 0;
  for (var i = 0; i < text.length && at < word.length; i++) {
    if (text.codeUnitAt(i) == word.codeUnitAt(at)) at++;
  }
  return at == word.length;
}

/// Every word typed has to match, in any order. Labels starting with the query come first, and
/// otherwise the list keeps its order.
List<PaletteItem> filterPalette(List<PaletteItem> items, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return items;
  final words = q.split(RegExp(r'\s+'));
  final starts = <PaletteItem>[], rest = <PaletteItem>[];
  for (final item in items) {
    final label = item.label.toLowerCase();
    final hay = item.group == null ? label : '${item.group!.toLowerCase()} $label';
    if (!words.every((w) => _isSubsequence(w, hay) || _isSubsequence(w, label))) continue;
    (label.startsWith(q) ? starts : rest).add(item);
  }
  return [...starts, ...rest];
}

/// A searchable list at the top of the window; the picked item runs once it has closed.
/// [prefixes] hand over to another search when the query starts with one, as `@` goes to symbols.
Future<void> showPalette(
  BuildContext context, {
  required String hint,
  required String empty,
  required List<PaletteItem> items,
  String query = '',
  Map<String, void Function(String rest)> prefixes = const {},
}) async {
  final picked = await showDialog<PaletteItem>(
    context: context,
    builder: (_) => _Palette(hint: hint, empty: empty, items: items, query: query, prefixes: prefixes),
  );
  picked?.onPick();
}

class _Palette extends StatefulWidget {
  const _Palette({required this.hint, required this.empty, required this.items, required this.query, required this.prefixes});

  final String hint, empty, query;
  final List<PaletteItem> items;
  final Map<String, void Function(String rest)> prefixes;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  static const _rowHeight = 34.0, _headingHeight = 28.0;
  var _index = 0;
  late var _query = widget.query.trim();
  late var _shown = filterPalette(widget.items, widget.query);
  late final _field = TextEditingController(text: widget.query)..selection = TextSelection.collapsed(offset: widget.query.length);
  final _scroll = ScrollController();

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Headings only while browsing: search results go by how well they match.
  bool get _grouped => _query.isEmpty && widget.items.any((i) => i.group != null);

  List<Object> get _rows {
    if (!_grouped) return _shown;
    final order = <String?>[];
    final groups = <String?, List<PaletteItem>>{};
    for (final item in _shown) {
      if (!groups.containsKey(item.group)) order.add(item.group);
      (groups[item.group] ??= []).add(item);
    }
    return [
      for (final group in order) ...[?group, ...groups[group]!],
    ];
  }

  /// In the order the rows show, which is what the arrows and Enter have to follow.
  List<PaletteItem> get _items => _rows.whereType<PaletteItem>().toList();

  void _move(int delta) {
    final items = _items;
    if (items.isEmpty) return;
    setState(() => _index = (_index + delta) % items.length);
    if (!_scroll.hasClients) return;
    var top = 0.0;
    var seen = 0;
    for (final row in _rows) {
      if (row is PaletteItem && seen++ == _index) break;
      top += row is PaletteItem ? _rowHeight : _headingHeight;
    }
    // The first command brings its heading along.
    if (_index == 0) top = 0;
    final position = _scroll.position;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + position.viewportDimension) {
      _scroll.jumpTo((top + _rowHeight - position.viewportDimension).clamp(0, position.maxScrollExtent));
    }
  }

  Widget _keyCap(String text, ColorScheme scheme) => Container(
    margin: const EdgeInsets.only(left: 3),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
  );

  Widget _keys(String keys, ColorScheme scheme) {
    final label = platformKeys(keys);
    // macOS writes them run together, as its own menus do.
    final parts = label.contains('+') && label.length > 1 ? label.split(RegExp(r'\+(?=.)')) : [label];
    return Row(mainAxisSize: MainAxisSize.min, children: [for (final part in parts) _keyCap(part, scheme)]);
  }

  Widget _row(PaletteItem item, bool selected, ColorScheme scheme) {
    final shape = BorderRadius.circular(7);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
        borderRadius: shape,
        child: InkWell(
          borderRadius: shape,
          onTap: () => Navigator.pop(context, item),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(width: 24, child: item.icon == null ? null : Icon(item.icon, size: 16, color: selected ? scheme.primary : scheme.outline)),
                // All in one Expanded: a Flexible next to a Spacer would split the room in half.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                      if (item.detail != null) ...[
                        const SizedBox(width: 10),
                        Flexible(child: Text(item.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.outline))),
                      ],
                      if (!_grouped && item.group != null) ...[
                        const SizedBox(width: 8),
                        Text(item.group!, style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                      ],
                    ],
                  ),
                ),
                if (item.keys != null) _keys(item.keys!, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    final items = _items;
    final selected = _index < items.length ? items[_index] : null;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is KeyUpEvent) return KeyEventResult.ignored;
                  if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                    _move(1);
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                    _move(-1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
                    prefixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 32),
                  ),
                  onChanged: (v) {
                    for (final e in widget.prefixes.entries) {
                      if (!v.startsWith(e.key)) continue;
                      final rest = v.substring(e.key.length);
                      return Navigator.pop(context, PaletteItem(v, () => e.value(rest)));
                    }
                    setState(() {
                    _query = v.trim();
                    _shown = filterPalette(widget.items, v);
                    _index = 0;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    });
                  },
                  onSubmitted: (_) {
                    final items = _items;
                    if (_index < items.length) Navigator.pop(context, items[_index]);
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? Center(child: Text(widget.empty, style: TextStyle(color: scheme.outline, fontSize: 13)))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final row = rows[i];
                        if (row is String) {
                          return Container(
                            height: _headingHeight,
                            alignment: Alignment.bottomLeft,
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                            child: Text(row, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: scheme.outline)),
                          );
                        }
                        final item = row as PaletteItem;
                        return SizedBox(height: _rowHeight, child: _row(item, identical(item, selected), scheme));
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  _keyCap('↑↓', scheme),
                  Text(' Move', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                  const SizedBox(width: 10),
                  _keyCap('Enter', scheme),
                  Text(' Run', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                  const SizedBox(width: 10),
                  _keyCap('Esc', scheme),
                  Text(' Close', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                  const Spacer(),
                  Text('${items.length}', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
