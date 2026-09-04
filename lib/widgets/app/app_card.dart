import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';

/// Standard content card: radius 12, 1px outlineVariant border, no
/// elevation. Replaces the scattered radius-4..24 / elevation-0..8 mixes.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppPadding.xlarge),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      onTap: onTap,
      child: card,
    );
  }
}
