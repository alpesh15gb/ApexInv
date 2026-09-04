import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';

/// Standard empty state: muted icon + title + optional subtitle and action.
/// Replaces the bespoke Center(Text) / celebration / per-screen icon mixes.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppPadding.xxxlarge + 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 72,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: AppPadding.medium),
            Text(
              title,
              style: const TextStyle(
                fontSize: AppFontSize.large,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppPadding.xsmall),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: AppFontSize.small,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppPadding.xlarge),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Standard loading state: centered progress indicator.
class AppLoadingState extends StatelessWidget {
  const AppLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}
