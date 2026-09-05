import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/common/setting_key.dart';
import 'package:apexbooks/providers/app_config_provider.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/screens/settings/license_screen.dart';
import 'package:apexbooks/services/update_service.dart';
import 'package:apexbooks/widgets/app/app.dart';

class AppInfoScreen extends ConsumerStatefulWidget {
  final UpdateInfo? updateInfo;
  final bool isCheckingUpdate;
  final bool updateCheckFailed;
  final VoidCallback onCheckForUpdates;

  const AppInfoScreen({
    super.key,
    required this.updateInfo,
    required this.isCheckingUpdate,
    required this.updateCheckFailed,
    required this.onCheckForUpdates,
  });

  @override
  ConsumerState<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends ConsumerState<AppInfoScreen> {
  // Anonymous usage telemetry. Null while loading; false (off) is the
  // default — the app only pings when this is explicitly granted.
  bool? _analyticsGranted;

  @override
  void initState() {
    super.initState();
    _loadAnalyticsConsent();
  }

  Future<void> _loadAnalyticsConsent() async {
    final value = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.analyticsConsent);
    if (!mounted) return;
    setState(() => _analyticsGranted = value == 'granted');
  }

  Future<void> _setAnalyticsConsent(bool granted) async {
    setState(() => _analyticsGranted = granted);
    await ref.read(settingsRepositoryProvider).setSetting(
        SettingKey.analyticsConsent, granted ? 'granted' : 'denied');
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;
    final cfg = ref.watch(appEditionConfigProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? null
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      appBar: AppBar(
        title: Text(l10n.appInfoTitle),
        backgroundColor:
            Theme.of(context).appBarTheme.backgroundColor ?? primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(context.isCompact ? 16 : 32),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Hero card ────────────────────────────────────────────
                AppCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
                  child: context.isCompact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Image.asset(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 'assets/images/logo_dark.png'
                                  : 'assets/images/logo.png',
                              width: 160,
                              height: 64,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              cfg.name.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: AppFontSize.xlarge,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              cfg.description,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: AppFontSize.small,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: primaryColor.withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                cfg.version,
                                style: TextStyle(
                                  fontSize: AppFontSize.medium,
                                  fontWeight: FontWeight.bold,
                                  color: primaryColor,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Image.asset(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 'assets/images/logo_dark.png'
                                  : 'assets/images/logo.png',
                              width: 130,
                              height: 52,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    cfg.name.toUpperCase(),
                                    style: const TextStyle(
                                      fontSize: AppFontSize.xxlarge,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    cfg.description,
                                    style: TextStyle(
                                      fontSize: AppFontSize.small,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: primaryColor.withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                cfg.version,
                                style: TextStyle(
                                  fontSize: AppFontSize.medium,
                                  fontWeight: FontWeight.bold,
                                  color: primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),

                const SizedBox(height: 20),

                // ── Two info cards ───────────────────────────────────────
                if (context.isCompact) ...[
                  _infoCard(l10n.appInfoAppDetailsTitle, [
                    _infoRow(Icons.apps_rounded, l10n.appInfoAppNameLabel,
                        cfg.name.toUpperCase()),
                    _infoRow(Icons.tag_rounded, l10n.appInfoVersionLabel,
                        cfg.version),
                    _infoRow(Icons.gavel_rounded, l10n.appInfoLicenseLabel,
                        cfg.license.toUpperCase()),
                  ]),
                  const SizedBox(height: 20),
                  _infoCard(l10n.appInfoDeveloperTitle, [
                    _infoRow(Icons.person_rounded, l10n.appInfoDeveloperLabel,
                        cfg.developer.toUpperCase()),
                    _infoRow(Icons.email_rounded, l10n.appInfoSupportEmailLabel,
                        cfg.supportEmail),
                    _infoRow(Icons.language_rounded, l10n.fieldWebsiteLabel,
                        cfg.website),
                  ]),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: _infoCard(l10n.appInfoAppDetailsTitle, [
                          _infoRow(Icons.apps_rounded, l10n.appInfoAppNameLabel,
                              cfg.name.toUpperCase()),
                          _infoRow(Icons.tag_rounded, l10n.appInfoVersionLabel,
                              cfg.version),
                          _infoRow(
                              Icons.gavel_rounded,
                              l10n.appInfoLicenseLabel,
                              cfg.license.toUpperCase()),
                        ]),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 3,
                        child: _infoCard(l10n.appInfoDeveloperTitle, [
                          _infoRow(
                              Icons.person_rounded,
                              l10n.appInfoDeveloperLabel,
                              cfg.developer.toUpperCase()),
                          _infoRow(Icons.email_rounded,
                              l10n.appInfoSupportEmailLabel, cfg.supportEmail),
                          _infoRow(Icons.language_rounded,
                              l10n.fieldWebsiteLabel, cfg.website),
                        ]),
                      ),
                    ],
                  ),

                const SizedBox(height: 20),

                // ── Update card ──────────────────────────────────────────
                if (cfg.enableUpdateCheck) _buildUpdateCard(),

                const SizedBox(height: 20),

                // ── Privacy card ─────────────────────────────────────────
                _infoCard('Privacy & license', [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: const Text(
                      'License & free trial',
                      style: TextStyle(
                          fontSize: AppFontSize.medium,
                          fontWeight: FontWeight.w500),
                    ),
                    subtitle: const Text(
                      'View status, activate a purchased key',
                      style: TextStyle(fontSize: AppFontSize.small),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LicenseScreen()),
                    ),
                  ),
                  SwitchListTile(
                    value: _analyticsGranted ?? false,
                    contentPadding: EdgeInsets.zero,
                    onChanged: _analyticsGranted == null
                        ? null
                        : (v) => _setAnalyticsConsent(v),
                    title: const Text(
                      'Share anonymous usage counts',
                      style: TextStyle(
                          fontSize: AppFontSize.medium,
                          fontWeight: FontWeight.w500),
                    ),
                    subtitle: const Text(
                      'One ping per day: app version and platform only. '
                      'No names, no business data. Turning this off stops '
                      'all telemetry immediately.',
                      style: TextStyle(fontSize: AppFontSize.small),
                    ),
                  ),
                ]),

                const SizedBox(height: 32),

                // ── Footer ───────────────────────────────────────────────
                Text(
                  l10n.appInfoFooterCopyright(
                      DateTime.now().year, cfg.developer, cfg.license),
                  style: TextStyle(
                    fontSize: AppFontSize.small,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpdateCard() {
    final primaryColor = Theme.of(context).primaryColor;
    final cfg = ref.watch(appEditionConfigProvider);
    final l10n = AppLocalizations.of(context)!;
    final info = widget.updateInfo;
    final hasUpdate = info != null && info.hasUpdate;
    final isUpToDate = info != null && !info.hasUpdate;

    Widget statusBadge;
    if (widget.isCheckingUpdate) {
      statusBadge = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child:
                CircularProgressIndicator(strokeWidth: 2, color: primaryColor),
          ),
          const SizedBox(width: 8),
          Text(l10n.appInfoCheckingLabel,
              style:
                  TextStyle(fontSize: AppFontSize.xsmall, color: primaryColor)),
        ],
      );
    } else if (hasUpdate) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.shade300),
        ),
        child: Text(
          l10n.appInfoUpdateAvailableLabel,
          style: TextStyle(
              fontSize: AppFontSize.xsmall,
              color: Colors.orange.shade800,
              fontWeight: FontWeight.w600),
        ),
      );
    } else if (isUpToDate) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.green.shade300),
        ),
        child: Text(
          l10n.appInfoUpToDateLabel,
          style: TextStyle(
              fontSize: AppFontSize.xsmall,
              color: Colors.green.shade700,
              fontWeight: FontWeight.w600),
        ),
      );
    } else if (widget.updateCheckFailed) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Text(
          l10n.appInfoCheckFailedLabel,
          style: TextStyle(
              fontSize: AppFontSize.xsmall,
              color: Colors.red.shade600,
              fontWeight: FontWeight.w600),
        ),
      );
    } else {
      statusBadge = const SizedBox.shrink();
    }

    return AppCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.appInfoUpdatesTitle,
                style: TextStyle(
                  fontSize: AppFontSize.xsmall,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 12),
              statusBadge,
            ],
          ),
          const SizedBox(height: 16),
          Divider(
              height: 1, color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          // Compact: the version blocks stack and the action buttons wrap —
          // Current+Latest in one Row can still exceed a 320px card.
          // Wide: single space-between Wrap.
          LayoutBuilder(builder: (context, updateConstraints) {
            final currentVersionRow = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tag_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.appInfoCurrentVersionLabel,
                        style: TextStyle(
                            fontSize: AppFontSize.xsmall,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text(cfg.version,
                        style: const TextStyle(
                            fontSize: AppFontSize.medium,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            );
            final latestVersionRow = info == null
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.new_releases_outlined,
                          size: 18,
                          color: hasUpdate
                              ? Colors.orange.shade400
                              : Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.appInfoLatestVersionLabel,
                              style: TextStyle(
                                  fontSize: AppFontSize.xsmall,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 3),
                          Text(
                            info.latestVersion,
                            style: TextStyle(
                              fontSize: AppFontSize.medium,
                              fontWeight: FontWeight.w600,
                              color: hasUpdate
                                  ? Colors.orange.shade700
                                  : Colors.green.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
            final actionButtons = Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppSecondaryButton(
                  onPressed:
                      widget.isCheckingUpdate ? null : widget.onCheckForUpdates,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(l10n.appInfoCheckNowButton),
                ),
                if (hasUpdate)
                  AppPrimaryButton(
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: Text(l10n.createInvoiceDownloadLabel),
                    onPressed: () => launchUrl(
                      Uri.parse('${AppConfig.appUrl}'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
              ],
            );
            if (updateConstraints.maxWidth < Breakpoints.compactMax) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  currentVersionRow,
                  if (info != null) ...[
                    const SizedBox(height: 12),
                    latestVersionRow,
                  ],
                  const SizedBox(height: 12),
                  actionButtons,
                ],
              );
            }
            return Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 12,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    currentVersionRow,
                    if (info != null) ...[
                      const SizedBox(width: 32),
                      latestVersionRow,
                    ],
                  ],
                ),
                actionButtons,
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _infoCard(String title, List<Widget> rows) {
    return AppCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppFontSize.xsmall,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          ...rows
              .expand((row) => [
                    row,
                    Divider(
                        height: 1,
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest),
                  ])
              .toList()
            ..removeLast(),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppFontSize.xsmall,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  value,
                  style: const TextStyle(
                    fontSize: AppFontSize.medium,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
