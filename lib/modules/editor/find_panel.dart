import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

/// Find (Ctrl+F) and replace (Ctrl+H) above the code.
class CodeFindPanel extends StatelessWidget implements PreferredSizeWidget {
  const CodeFindPanel({super.key, required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  static const _rowHeight = 38.0;

  @override
  Size get preferredSize {
    final v = controller.value;
    if (v == null) return Size.zero;
    return Size(double.infinity, v.replaceMode ? _rowHeight * 2 : _rowHeight);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final result = v.result;
    final count = result == null || result.matches.isEmpty ? 'No results' : '${result.index + 1} of ${result.matches.length}';

    Widget field(TextEditingController c, FocusNode f, String hint) => SizedBox(
      width: 280,
      height: 28,
      child: TextField(
        controller: c,
        focusNode: f,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
      ),
    );

    Widget toggle(String label, bool on, VoidCallback onTap, String tip) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: on ? scheme.primary.withValues(alpha: .2) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
        ),
      ),
    );

    Widget icon(IconData i, String tip, VoidCallback? onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      onPressed: onTap,
      icon: Icon(i),
    );

    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _rowHeight,
            child: Row(
              children: [
                if (!readOnly)
                  icon(v.replaceMode ? Icons.expand_more : Icons.chevron_right, 'Toggle replace', controller.toggleMode),
                field(controller.findInputController, controller.findInputFocusNode, 'Find'),
                const SizedBox(width: 6),
                toggle('Aa', v.option.caseSensitive, controller.toggleCaseSensitive, 'Match case'),
                toggle('.*', v.option.regex, controller.toggleRegex, 'Regular expression'),
                const SizedBox(width: 8),
                Text(count, style: TextStyle(fontSize: 12, color: scheme.outline)),
                icon(Icons.arrow_upward, 'Previous', result == null ? null : controller.previousMatch),
                icon(Icons.arrow_downward, 'Next', result == null ? null : controller.nextMatch),
                const Spacer(),
                icon(Icons.close, 'Close', controller.close),
              ],
            ),
          ),
          if (v.replaceMode && !readOnly)
            SizedBox(
              height: _rowHeight,
              child: Row(
                children: [
                  const SizedBox(width: 36),
                  field(controller.replaceInputController, controller.replaceInputFocusNode, 'Replace'),
                  const SizedBox(width: 6),
                  TextButton(onPressed: result == null ? null : controller.replaceMatch, child: const Text('Replace')),
                  TextButton(onPressed: result == null ? null : controller.replaceAllMatches, child: const Text('All')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
