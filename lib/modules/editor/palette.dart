import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform_keys.dart';

class PaletteItem {
  const PaletteItem(this.label, this.onPick, {this.detail, this.keys, this.icon});

  final String label;
  final String? detail, keys;
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
    if (!words.every((w) => _isSubsequence(w, label))) continue;
    (label.startsWith(q) ? starts : rest).add(item);
  }
  return [...starts, ...rest];
}

/// A searchable list at the top of the window; the picked item runs once it has closed.
Future<void> showPalette(BuildContext context, {required String hint, required String empty, required List<PaletteItem> items}) async {
  final picked = await showDialog<PaletteItem>(
    context: context,
    builder: (_) => _Palette(hint: hint, empty: empty, items: items),
  );
  picked?.onPick();
}

class _Palette extends StatefulWidget {
  const _Palette({required this.hint, required this.empty, required this.items});

  final String hint, empty;
  final List<PaletteItem> items;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  static const _rowHeight = 30.0;
  var _index = 0;
  late var _shown = widget.items;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta) {
    if (_shown.isEmpty) return;
    setState(() => _index = (_index + delta) % _shown.length);
    if (!_scroll.hasClients) return;
    final top = _index * _rowHeight;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + _scroll.position.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - _scroll.position.viewportDimension);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: scheme.outline);
    return Dialog(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 640,
        height: 440,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
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
                  autofocus: true,
                  decoration: InputDecoration(hintText: widget.hint, isDense: true),
                  onChanged: (v) => setState(() {
                    _shown = filterPalette(widget.items, v);
                    _index = 0;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  }),
                  onSubmitted: (_) {
                    if (_shown.isNotEmpty) Navigator.pop(context, _shown[_index]);
                  },
                ),
              ),
            ),
            Expanded(
              child: _shown.isEmpty
                  ? Center(child: Text(widget.empty, style: TextStyle(color: scheme.outline, fontSize: 13)))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _shown.length,
                      itemExtent: _rowHeight,
                      itemBuilder: (_, i) {
                        final item = _shown[i];
                        return InkWell(
                          onTap: () => Navigator.pop(context, item),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            color: i == _index ? scheme.primary.withValues(alpha: .14) : null,
                            child: Row(
                              children: [
                                if (item.icon != null) ...[Icon(item.icon, size: 15, color: scheme.outline), const SizedBox(width: 8)],
                                Flexible(child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                                if (item.detail != null) ...[
                                  const SizedBox(width: 10),
                                  Flexible(child: Text(item.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
                                ],
                                const Spacer(),
                                if (item.keys != null) Text(platformKeys(item.keys!), style: small),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
