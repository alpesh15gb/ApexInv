import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/navigation/dashboard_destinations.dart';
import 'package:apexbooks/providers/app_config_provider.dart';
import 'package:apexbooks/providers/industry_provider.dart';
import 'package:apexbooks/screens/import_screen.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Mobile "More" destination — grouped secondary navigation shown when the
/// window is too narrow for the persistent sidebar (see mobile_plan.md).
class MoreMenuScreen extends ConsumerWidget {
  final User user;
  final bool hasUpdate;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onLogout;

  const MoreMenuScreen({
    super.key,
    required this.user,
    required this.hasUpdate,
    required this.onSelectTab,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cfg = ref.watch(appEditionConfigProvider);
    final industry = ref.watch(industryProfileProvider);
    bool visible(DashboardTab tab) {
      if (tab.adminOnly && !user.isAdmin()) return false;
      final allowed = tab.industries;
      return allowed == null || allowed.contains(industry);
    }

    Widget tabTile(DashboardTab tab, {bool showDot = false}) => _tile(
        context, tab.id, tab.filledIcon, tab.label(l10n),
        showDot: showDot);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _userHeader(context),
          const SizedBox(height: 20),
          _groupHeading(context, l10n.moreSectionDocuments),
          if (visible(DashboardTab.metalRates))
            _section(
                context, l10n.navMetalRates, [tabTile(DashboardTab.metalRates)]),
          if (visible(DashboardTab.metalRates)) const SizedBox(height: 16),
          if (visible(DashboardTab.jobWork)) ...[
            _section(context, 'Job Work', [tabTile(DashboardTab.jobWork)]),
            const SizedBox(height: 16),
          ],
          _section(context, l10n.navSectionSales, [
            for (final tab in [
              DashboardTab.salesInvoices,
              DashboardTab.estimates,
              DashboardTab.proforma,
              DashboardTab.paymentIn,
              DashboardTab.saleOrders,
              DashboardTab.deliveryChallan,
              DashboardTab.creditNote,
              DashboardTab.pos,
            ])
              if (visible(tab)) tabTile(tab),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.navSectionPurchase, [
            for (final tab in [
              DashboardTab.purchaseBills,
              DashboardTab.purchaseOrders,
              DashboardTab.paymentOut,
              DashboardTab.expenses,
              DashboardTab.debitNote,
            ])
              if (visible(tab)) tabTile(tab),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.navSectionCashBank, [
            for (final tab in [
              DashboardTab.bankAccounts,
              DashboardTab.cashInHand,
              DashboardTab.cheques,
              DashboardTab.loanAccounts,
            ])
              if (visible(tab)) tabTile(tab),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.moreSectionAnalytics, [
            tabTile(DashboardTab.reports),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.moreSectionPreferences, [
            tabTile(DashboardTab.settings, showDot: hasUpdate),
            tabTile(DashboardTab.reminders),
            if (visible(DashboardTab.auditLog))
              tabTile(DashboardTab.auditLog),
            _pushTile(
              context,
              Icons.upload_file_outlined,
              'Import from Vyapar',
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ImportScreen()),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _logoutTile(context),
          const SizedBox(height: 20),
          Center(
            child: Text(
              cfg.version,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (TestBuildConfig.isTestBuild) ...[
            const SizedBox(height: 6),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  AppLocalizations.of(context)!.dashboardTestBuildBadge,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _userHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: primary.withValues(alpha: 0.12),
          child: Text(
            user.username.isNotEmpty ? user.username[0].toUpperCase() : '?',
            style: TextStyle(
                color: primary, fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                user.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              Text(
                user.isAdmin()
                    ? l10n.dashboardRoleAdmin
                    : l10n.dashboardRoleUser,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: l10n.dashboardSupportTooltip,
          icon: const Icon(Icons.support_agent_outlined),
          color: theme.colorScheme.onSurfaceVariant,
          onPressed: () => launchUrl(Uri.parse(AppConfig.supportForm),
              mode: LaunchMode.externalApplication),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> tiles) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(title),
        Material(
          color: theme.cardColor,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      thickness: 1,
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.6)),
                tiles[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupHeading(BuildContext context, String title) {
    return AppSectionHeader(title);
  }

  Widget _tile(BuildContext context, int tab, IconData icon, String label,
      {bool showDot = false}) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onSelectTab(tab),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.primaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: theme.primaryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w500),
              ),
            ),
            if (showDot)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 6),
                decoration: const BoxDecoration(
                    color: Colors.orange, shape: BoxShape.circle),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _pushTile(
      BuildContext context, IconData icon, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: theme.primaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: theme.primaryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w500),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _logoutTile(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    return Material(
      color: theme.cardColor,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onLogout,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: errorColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.logout_rounded, size: 20, color: errorColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.dashboardLogoutTooltip,
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: errorColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
