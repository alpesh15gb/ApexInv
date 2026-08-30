import 'package:flutter/material.dart';

import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/screens/dashboard_screen.dart';
import 'package:apexbooks/screens/mobile_dashboard_screen.dart';
import 'package:apexbooks/utils/responsive_layout.dart';

/// Keeps the existing desktop dashboard untouched while selecting the
/// touch-friendly shell for phone and tablet-sized viewports.
class ResponsiveDashboardScreen extends StatelessWidget {
  final User loggedInUser;

  const ResponsiveDashboardScreen(this.loggedInUser, {super.key});

  @override
  Widget build(BuildContext context) {
    if (!context.isWideLayout) {
      return MobileDashboardScreen(loggedInUser);
    }
    return DashboardScreen(loggedInUser);
  }
}
