import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/providers/repositories.dart';

/// Trade vertical for this company. Retail is the default (and the implicit
/// value for installs that predate the picker); jewellery unlocks weight
/// billing, metal rates, and hallmark surfaces. Everything else stays shared.
enum IndustryProfile { retail, jewellery }

IndustryProfile industryProfileFromKey(String? key) =>
    key == IndustryProfile.jewellery.key
        ? IndustryProfile.jewellery
        : IndustryProfile.retail;

extension IndustryProfileKey on IndustryProfile {
  String get key => switch (this) {
        IndustryProfile.retail => 'retail',
        IndustryProfile.jewellery => 'jewellery',
      };
}

/// Current trade, loaded once per session after auth (see
/// `navigateAfterAuth`) and updated whenever onboarding or Company Info
/// saves a new choice. Screens watch this to gate vertical surfaces.
final industryProfileProvider =
    StateProvider<IndustryProfile>((ref) => IndustryProfile.retail);

/// Reads the persisted choice into [industryProfileProvider]. Safe to call
/// repeatedly; unknown/blank values fall back to retail.
Future<void> loadIndustryProfile(WidgetRef ref) async {
  try {
    final key = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.industryProfile);
    ref.read(industryProfileProvider.notifier).state =
        industryProfileFromKey(key);
  } catch (_) {
    // A profile must never block startup; retail is the safe default.
  }
}

/// Persists a new choice and publishes it immediately.
Future<void> saveIndustryProfile(WidgetRef ref, IndustryProfile profile) async {
  await ref
      .read(settingsRepositoryProvider)
      .setSetting(SettingKey.industryProfile, profile.key);
  ref.read(industryProfileProvider.notifier).state = profile;
}
