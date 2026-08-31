import 'package:flutter/material.dart';

/// Standard responsive window tiers:
///  - compact  (< 700)  : phones — bottom navigation shell
///  - medium   (700-1024): tablets / narrow desktop windows — bottom navigation
///  - expanded (>= 1024) : desktop — persistent sidebar shell
enum WindowSize { compact, medium, expanded }

class Breakpoints {
  static const double compactMax = 700.0;
  static const double expandedMin = 1024.0;

  static WindowSize of(double width) {
    if (width < compactMax) return WindowSize.compact;
    if (width < expandedMin) return WindowSize.medium;
    return WindowSize.expanded;
  }

  static bool isCompact(double width) => width < compactMax;
  static bool isExpanded(double width) => width >= expandedMin;
}

extension ResponsiveContext on BuildContext {
  WindowSize get windowSize => Breakpoints.of(MediaQuery.sizeOf(this).width);
  bool get isCompact => windowSize == WindowSize.compact;
  bool get isExpanded => windowSize == WindowSize.expanded;
}

/// Rebuilds with the [WindowSize] derived from its *local* constraints (not
/// the global window size), so it also works inside panels and split layouts.
class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, WindowSize size) builder;

  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          builder(context, Breakpoints.of(constraints.maxWidth)),
    );
  }
}
