import 'package:flutter/material.dart';

import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/providers/industry_provider.dart';

/// Trade picker step of the onboarding wizard: Retail/General or Jewellery.
/// The choice gates vertical features for the whole app (see retail.md).
/// Defaults to retail so skipping preserves today's behaviour.
class OnboardingStepTrade extends StatelessWidget {
  final IndustryProfile selected;
  final ValueChanged<IndustryProfile> onChanged;

  const OnboardingStepTrade({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.onboardingTradeHint,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _TradeCard(
            selected: selected == IndustryProfile.retail,
            icon: Icons.storefront_rounded,
            title: l10n.onboardingTradeRetailTitle,
            subtitle: l10n.onboardingTradeRetailSubtitle,
            onTap: () => onChanged(IndustryProfile.retail),
          ),
          const SizedBox(height: 12),
          _TradeCard(
            selected: selected == IndustryProfile.jewellery,
            icon: Icons.diamond_outlined,
            title: l10n.onboardingTradeJewelleryTitle,
            subtitle: l10n.onboardingTradeJewellerySubtitle,
            onTap: () => onChanged(IndustryProfile.jewellery),
          ),
        ],
      ),
    );
  }
}

class _TradeCard extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TradeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: scheme.primary, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    color: scheme.primary, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}
