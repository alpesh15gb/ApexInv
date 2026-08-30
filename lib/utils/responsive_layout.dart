import 'package:flutter/widgets.dart';

/// Shared responsive breakpoints for Apex Books.
///
/// Keep layout decisions based on available width rather than platform so
/// tablets, foldables, resized desktop windows and mobile landscape all get
/// the layout that actually fits.
abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double wide = 980;
}

extension ResponsiveContext on BuildContext {
  double get viewportWidth => MediaQuery.sizeOf(this).width;

  bool get isCompactLayout => viewportWidth < AppBreakpoints.compact;

  bool get isTabletLayout =>
      viewportWidth >= AppBreakpoints.compact &&
      viewportWidth < AppBreakpoints.wide;

  bool get isWideLayout => viewportWidth >= AppBreakpoints.wide;
}
