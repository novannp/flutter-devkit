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
