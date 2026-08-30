import 'package:flutter/material.dart';

import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/screens/dashboard_screen.dart';
import 'package:apexbooks/screens/mobile_dashboard_screen.dart';
import 'package:apexbooks/utils/responsive_layout.dart';

/// Keeps the existing desktop dashboard untouched while selecting the
/// phone-first shell when the available viewport is compact.
class ResponsiveDashboardScreen extends StatelessWidget {
  final User loggedInUser;

  const ResponsiveDashboardScreen(this.loggedInUser, {super.key});

  @override
  Widget build(BuildContext context) {
    if (context.isCompactLayout) {
      return MobileDashboardScreen(loggedInUser);
    }
    return DashboardScreen(loggedInUser);
  }
}
