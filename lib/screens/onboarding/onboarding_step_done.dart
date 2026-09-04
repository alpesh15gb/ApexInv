import 'package:flutter/material.dart';
import 'package:apexbooks/l10n/app_localizations.dart';

/// Step 4 of the onboarding wizard: confirmation + anonymous-usage consent.
/// Consent defaults to off; leaving it off (or skipping earlier steps, which
/// leaves the setting unset) means the app never sends telemetry.
class OnboardingStepDone extends StatelessWidget {
  final bool analyticsConsented;
  final ValueChanged<bool> onAnalyticsChanged;

  const OnboardingStepDone({
    super.key,
    required this.analyticsConsented,
    required this.onAnalyticsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primaryColor = Theme.of(context).primaryColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle_rounded,
                  size: 56, color: primaryColor),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.onboardingDoneHeadline,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.onboardingDoneBody,
              style: TextStyle(
                fontSize: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            CheckboxListTile(
              value: analyticsConsented,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => onAnalyticsChanged(v ?? false),
              title: const Text(
                'Help improve ApexBooks',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Share one anonymous ping per day (app version and platform '
                'only — no names, no business data). You can turn this off '
                'anytime in Settings.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
