import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/providers/app_config_provider.dart';

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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _userHeader(context),
          const SizedBox(height: 20),
          _section(context, 'Sales (Master)', [
            _tile(context, 2, Icons.receipt_long_outlined, 'Sales Invoices'),
            _tile(context, 3, Icons.request_quote_outlined, 'Estimates'),
            _tile(context, 16, Icons.request_page_outlined, 'Proforma Invoice'),
            _tile(context, 4, Icons.payments_outlined, 'Payment In'),
            _tile(context, 19, Icons.shopping_bag_outlined, 'Sale Order'),
            _tile(context, 15, Icons.local_shipping_outlined, 'Delivery Challan'),
            _tile(context, 13, Icons.note_alt_outlined, 'Credit Note'),
            _tile(context, 20, Icons.point_of_sale_outlined, 'POS'),
          ]),
          const SizedBox(height: 16),
          _section(context, 'Purchase (Master)', [
            _tile(context, 11, Icons.inventory_outlined, 'Purchase Bills'),
            _tile(context, 9, Icons.shopping_cart_outlined, 'Purchase Order'),
            _tile(context, 21, Icons.payments_outlined, 'Payment Out'),
            _tile(context, 8, Icons.receipt_long_outlined, 'Expenses'),
            _tile(context, 14, Icons.note_add_outlined, 'Debit Note'),
          ]),
          const SizedBox(height: 16),
          _section(context, 'Cash And Bank', [
            _tile(context, 22, Icons.account_balance_outlined, 'Bank Accounts'),
            _tile(context, 23, Icons.account_balance_wallet_outlined,
                'Cash In Hand'),
            _tile(context, 24, Icons.confirmation_number_outlined, 'Cheques'),
            _tile(context, 25, Icons.request_quote_outlined, 'Loan Accounts'),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.moreSectionAnalytics, [
            _tile(context, 7, Icons.bar_chart_outlined, l10n.navReports),
          ]),
          const SizedBox(height: 16),
          _section(context, l10n.moreSectionPreferences, [
            _tile(context, 10, Icons.settings_outlined, l10n.navSettings,
                showDot: hasUpdate),
            _tile(context, 17, Icons.notifications_active_outlined,
                'Payment Reminders'),
            if (user.isAdmin())
              _tile(context, 18, Icons.fact_check_outlined, 'Audit Log'),
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
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: theme.primaryColor,
            ),
          ),
        ),
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
