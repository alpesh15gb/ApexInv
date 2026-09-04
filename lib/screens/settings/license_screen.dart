import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/common/setting_key.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/licensing/license_service.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// License & trial status. Paste a purchased key to activate; verification
/// is fully offline. Buying happens in the browser (hosted Razorpay
/// checkout) and the key is delivered on screen and by email.
class LicenseScreen extends ConsumerStatefulWidget {
  const LicenseScreen({super.key});

  @override
  ConsumerState<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends ConsumerState<LicenseScreen> {
  final _keyController = TextEditingController();
  LicenseStatus? _status;
  bool _loading = true;
  bool _activating = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final status = await LicenseGate.check();
    if (!mounted) return;
    final stored = await SettingsService.getSetting(SettingKey.licenseKey);
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
      if ((stored ?? '').isNotEmpty && _keyController.text.isEmpty) {
        _keyController.text = stored!;
      }
    });
  }

  Future<void> _activate() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste your license key first')),
      );
      return;
    }
    setState(() => _activating = true);
    final info = await LicenseService.verifyLicenseKey(key);
    if (!mounted) return;
    setState(() => _activating = false);
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('That key is not valid. Check it and try again.')),
      );
      return;
    }
    await SettingsService.setSetting(SettingKey.licenseKey, key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('License activated')),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('License')),
      body: _loading || status == null
          ? const AppLoadingState()
          : ListView(
              padding: const EdgeInsets.all(AppPadding.xlarge),
              children: [
                AppCard(child: _statusBody(status)),
                const SizedBox(height: AppPadding.xlarge),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Activate a license',
                          style: TextStyle(
                              fontSize: AppFontSize.large,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppPadding.small),
                      const Text(
                        'Paid after buying online. The key works offline — '
                        'no sign-in needed.',
                        style: TextStyle(fontSize: AppFontSize.small),
                      ),
                      const SizedBox(height: AppPadding.medium),
                      AppTextField(
                        controller: _keyController,
                        labelText: 'License key',
                        hintText: 'AB1.…',
                        maxLines: 3,
                      ),
                      const SizedBox(height: AppPadding.medium),
                      AppPrimaryButton(
                        onPressed: _activating ? null : _activate,
                        label: const Text('Activate'),
                        expanded: true,
                        loading: _activating,
                      ),
                      const SizedBox(height: AppPadding.small),
                      AppSecondaryButton(
                        onPressed: () => launchUrl(
                          Uri.parse(AppConfig.licenseBuyUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                        label: const Text('Buy / renew license'),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _statusBody(LicenseStatus status) {
    final license = status.license;
    final days = status.daysLeft;
    final String headline;
    final String detail;
    if (status.isLicensed && license != null) {
      headline = 'Licensed${license.expiresAt == null ? ' (perpetual)' : ''}';
      detail =
          'Plan ${license.plan}${license.email.isNotEmpty ? ' · ${license.email}' : ''}'
          '${license.expiresAt == null ? '' : ' · expires ${license.expiresAt!.toIso8601String().substring(0, 10)}'}';
    } else if (status.isTrialExpiring) {
      headline = 'Trial ending — $days days left';
      detail = 'Free until 5 May 2027. Your books stay yours either way.';
    } else if (status.isTrial) {
      headline = 'Free trial — $days days left';
      detail = 'Free until 5 May 2027. Your books stay yours either way.';
    } else if (status.isGrace) {
      headline = 'Grace period — $days days left';
      detail = 'Trial ended. Activate a license to keep creating documents.';
    } else {
      headline = 'Read-only';
      detail =
          'Activate a license to create new documents. Viewing, printing and export keep working.';
    }
    final color = status.isReadOnly
        ? Theme.of(context).colorScheme.error
        : status.isTrialExpiring || status.isGrace
            ? Colors.orange.shade800
            : Colors.green.shade700;
    return Row(
      children: [
        Icon(
          status.isReadOnly
              ? Icons.lock_outline_rounded
              : Icons.verified_outlined,
          color: color,
          size: 32,
        ),
        const SizedBox(width: AppPadding.medium),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(headline,
                  style: TextStyle(
                      fontSize: AppFontSize.large,
                      fontWeight: FontWeight.w700,
                      color: color)),
              const SizedBox(height: 4),
              Text(detail, style: const TextStyle(fontSize: AppFontSize.small)),
            ],
          ),
        ),
      ],
    );
  }
}
