import 'package:flutter/material.dart';

import 'package:apexbooks/common/setting_key.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_service.dart';
import 'package:apexbooks/screens/settings/license_screen.dart';

/// UI glue over [LicenseService]: loads the stored key, computes the
/// status, stamps the clock-rollback guard, and routes blocked users to
/// the License screen. Read paths never block; only document *creation*
/// is gated (view/print/export/edit keep working in read-only states).
class LicenseGate {
  LicenseGate._();

  static Future<LicenseStatus> check() async {
    final results = await Future.wait([
      SettingsService.getSetting(SettingKey.licenseKey),
      SettingsService.getSetting(SettingKey.licenseLastSeen),
    ]);
    final status = await LicenseService.getStatus(
      now: DateTime.now(),
      licenseKey: results[0],
      lastSeenIso: results[1],
    );
    await SettingsService.setSetting(
        SettingKey.licenseLastSeen, LicenseService.stampNow(DateTime.now()));
    return status;
  }

  /// Returns true when a new business document may be created. Otherwise
  /// explains why and offers the License screen. Never throws.
  static Future<bool> canCreate(BuildContext context) async {
    try {
      final status = await check();
      if (LicenseService.canCreateDocuments(status)) return true;
      if (!context.mounted) return false;
      const message =
          'Trial ended. Activate a license to create new documents — your existing data stays readable.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(message),
          action: SnackBarAction(
            label: 'Activate',
            onPressed: () => openLicenseScreen(context),
          ),
        ),
      );
      return false;
    } catch (_) {
      // A broken settings read must never block money workflows.
      return true;
    }
  }

  static void openLicenseScreen(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LicenseScreen()),
    );
  }
}
