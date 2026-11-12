import 'package:flutter/material.dart';

/// The category control shared by Home, the story library, and the game room.
class CategoryFilterPill extends StatelessWidget {
  const CategoryFilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticsLabel,
    this.inkColor,
    this.selectedColor,
    this.backgroundColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? semanticsLabel;
  final Color? inkColor;
  final Color? selectedColor;
  final Color? backgroundColor;

  static const double spacing = 10;
  static const double minimumHeight = 47;

  /// Keeps the Home rail's height while allowing large accessibility labels.
  static double railHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return minimumHeight + ((scale - 1).clamp(0.0, 2.0) * 16);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink =
        inkColor ?? (dark ? const Color(0xFFFFFCF6) : const Color(0xFF171421));
    final paper =
        backgroundColor ??
        (dark ? const Color(0xFF181B1A) : const Color(0xFFFFFCF6));
    final lavender =
        selectedColor ??
        (dark
            ? Color.alphaBlend(
                Colors.black.withValues(alpha: 0.52),
                const Color(0xFFB7A5FF),
              )
            : const Color(0xFFB7A5FF));

    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel ?? label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 48,
            minHeight: minimumHeight,
          ),
          child: Material(
            color: selected ? lavender : paper,
            shape: StadiumBorder(side: BorderSide(color: ink, width: 2)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              splashFactory: MediaQuery.disableAnimationsOf(context)
                  ? NoSplash.splashFactory
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 9,
                ),
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
