import 'package:flutter/material.dart';

/// Pinned bottom action area for pages that own their own primary action
/// (Create Invoice, settings forms on compact windows). Renders above the
/// app shell's NavigationBar because it lives inside the page body, and
/// above the keyboard because the host Scaffold resizes for insets.
class StickyActionBar extends StatelessWidget {
  final Widget child;
  final bool showTopBorder;

  const StickyActionBar({
    super.key,
    required this.child,
    this.showTopBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: showTopBorder
            ? Border(top: BorderSide(color: theme.colorScheme.outlineVariant))
            : null,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: child,
        ),
      ),
    );
  }
}
