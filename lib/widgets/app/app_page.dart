import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';

/// Standard list-screen page: Scaffold + AppBar + 16px padded body.
/// New and migrated screens use this instead of hand-rolled Scaffold mixes.
/// Business logic lives in the caller — this is layout only.
class AppPage extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final double maxWidth;

  const AppPage({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.maxWidth = double.infinity,
  });

  @override
  Widget build(BuildContext context) {
    final content = maxWidth == double.infinity
        ? body
        : Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: body,
            ),
          );
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: Padding(
        padding: const EdgeInsets.all(AppPadding.xlarge),
        child: content,
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}
