import 'package:flutter/material.dart';

/// Onboarding step 4 — optional cloud backup decision. The user either
/// provides a cloud sign-in (opens the Cloud Sync screen right after
/// onboarding) or explicitly opts out of cloud services. The choice is
/// persisted so the app never nags again.
class OnboardingStepCloud extends StatelessWidget {
  final String choice; // '' | 'enabled' | 'declined'
  final ValueChanged<String> onChanged;

  const OnboardingStepCloud({
    super.key,
    required this.choice,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cloud Backup (Optional)',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Your data is always saved on this device. You can also back it '
            'up to the cloud so it syncs across devices — or skip cloud '
            'services entirely. You can change this later in Settings → '
            'Cloud Sync.',
            style: TextStyle(
                fontSize: 13.5, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _optionCard(
            context,
            selected: choice == 'enabled',
            icon: Icons.cloud_sync_outlined,
            iconColor: Colors.green,
            title: 'Sign in to cloud sync',
            subtitle:
                'Create a cloud account or sign in, and your books sync to '
                'your own Apex Books server automatically.',
            onTap: () => onChanged('enabled'),
          ),
          const SizedBox(height: 12),
          _optionCard(
            context,
            selected: choice == 'declined',
            icon: Icons.cloud_off_outlined,
            iconColor: theme.colorScheme.onSurfaceVariant,
            title: 'No cloud services',
            subtitle:
                'Keep everything on this device only. Nothing is uploaded, '
                'and we won\'t ask again.',
            onTap: () => onChanged('declined'),
          ),
          const SizedBox(height: 16),
          const Text(
            'You can change this anytime in Settings → Cloud Sync.',
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Widget _optionCard(
    BuildContext context, {
    required bool selected,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    return Material(
      color: selected ? primary.withValues(alpha: 0.08) : theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? primary : theme.colorScheme.outlineVariant,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? primary : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
