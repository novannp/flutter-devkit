import 'package:flutter/material.dart';

/// A dropdown with short rows: Flutter's own DropdownButton won't go below 48 px per item.
class CompactDropdown<T> extends StatefulWidget {
  const CompactDropdown({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    this.onChanged,
    this.hint,
    this.style,
    this.decoration,
    this.isExpanded = false,
    this.isDense = true,
    this.underline,
    this.borderRadius,
  });

  final T? value, initialValue;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final TextStyle? style;
  final InputDecoration? decoration;
  final bool isExpanded;

  // Accepted so a DropdownButton swaps in unchanged; every row here is dense and has no underline.
  final bool isDense;
  final Widget? underline;
  final BorderRadius? borderRadius;

  @override
  State<CompactDropdown<T>> createState() => _CompactDropdownState<T>();
}

class _CompactDropdownState<T> extends State<CompactDropdown<T>> {
  static const _rowHeight = 28.0;
  late T? _current = widget.value ?? widget.initialValue;

  @override
  void didUpdateWidget(CompactDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _current = widget.value ?? widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = widget.items ?? const [];
    final style = (widget.style ?? DefaultTextStyle.of(context).style).copyWith(fontSize: widget.style?.fontSize ?? 13);
    final enabled = widget.onChanged != null && items.isNotEmpty;
    final selected = items.where((i) => i.value == _current).firstOrNull;
    Widget label = DefaultTextStyle(
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: selected?.child ?? widget.hint ?? const SizedBox.shrink(),
    );
    if (widget.isExpanded || widget.decoration != null) label = Expanded(child: label);
    final content = Row(
      mainAxisSize: widget.isExpanded || widget.decoration != null ? MainAxisSize.max : MainAxisSize.min,
      children: [label, Icon(Icons.arrow_drop_down, size: 18, color: enabled ? scheme.onSurfaceVariant : scheme.outline)],
    );
    // Wrapped, because a popup item whose value is null counts as "nothing picked".
    return PopupMenuButton<(T?,)>(
      enabled: enabled,
      tooltip: '',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 480, maxHeight: 340),
      menuPadding: const EdgeInsets.symmetric(vertical: 3),
      onSelected: (picked) {
        setState(() => _current = picked.$1);
        widget.onChanged?.call(picked.$1);
      },
      itemBuilder: (_) => [
        for (final item in items)
          PopupMenuItem(
            value: (item.value,),
            enabled: item.enabled,
            height: _rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: DefaultTextStyle(
              style: style.copyWith(
                color: item.value == _current ? scheme.primary : null,
                fontWeight: item.value == _current ? FontWeight.w600 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: item.child,
            ),
          ),
      ],
      child: widget.decoration == null ? content : InputDecorator(decoration: widget.decoration!, child: content),
    );
  }
}
