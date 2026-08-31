import 'package:flutter/material.dart';

/// Flat list card with an optional 4px status accent bar on the left edge —
/// the shared container for mobile list rows (invoices, customers, ...).
///
/// The accent bar is drawn with a Stack + Positioned bar rather than a
/// `Row(crossAxisAlignment: stretch)` pair, so the card is safe under the
/// unbounded vertical constraints of a scrollable list (stretch Rows try to
/// fill an infinite cross extent and blank out / throw inside ListViews).
class EntityCard extends StatelessWidget {
  final Widget child;
  final Color? accentColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const EntityCard({
    super.key,
    required this.child,
    this.accentColor,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);
    final hasAccent = accentColor != null;
    return Padding(
      padding: margin,
      child: Material(
        color: theme.cardColor,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            children: [
              if (hasAccent)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 4,
                  child: ColoredBox(color: accentColor!),
                ),
              Padding(
                padding: hasAccent
                    ? padding.add(const EdgeInsets.only(left: 4))
                    : padding,
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
