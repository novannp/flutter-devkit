import 'package:flutter/material.dart';

const panelGap = 6.0;

Color canvasOf(ColorScheme scheme) => scheme.surfaceContainer;

class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(10);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(borderRadius: shape, border: Border.all(color: scheme.outlineVariant.withValues(alpha: .55))),
      child: ClipRRect(borderRadius: shape, child: ColoredBox(color: scheme.surface, child: child)),
    );
  }
}

class PillTab extends StatelessWidget {
  const PillTab({super.key, required this.selected, required this.onTap, required this.child, this.active = true, this.padding = const EdgeInsets.symmetric(horizontal: 10)});

  final bool selected;

  /// Whether the selection is where the keyboard is: an unfocused split dims its tab.
  final bool active;
  final VoidCallback onTap;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(8);
    final fill = !selected ? Colors.transparent : (active ? scheme.primary.withValues(alpha: .14) : scheme.surfaceContainerHigh);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: fill,
        borderRadius: shape,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: Padding(padding: padding, child: Center(widthFactor: 1, child: child)),
        ),
      ),
    );
  }
}

/// Something to click in the status bar. Ink would be hidden behind the bar's own color, so this draws its own.
class StatusBarItem extends StatefulWidget {
  const StatusBarItem({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<StatusBarItem> createState() => _StatusBarItemState();
}

class _StatusBarItemState extends State<StatusBarItem> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final tint = Theme.of(context).colorScheme.onSurface.withValues(alpha: .1);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(color: _hover && enabled ? tint : Colors.transparent, borderRadius: BorderRadius.circular(4)),
          child: widget.child,
        ),
      ),
    );
  }
}
