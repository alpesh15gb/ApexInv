import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/providers/repositories.dart';

/// Compact dashboard composition for phone/tablet widths.
///
/// It intentionally uses the same repositories and invoice model as the
/// desktop dashboard; only presentation changes. This avoids squeezing the
/// desktop dashboard's five-card Row into a narrow viewport.
class MobileDashboardHome extends ConsumerStatefulWidget {
  final Function(Invoice) onEditInvoice;
  final Function(Invoice, String) onCloneInvoice;
  final User user;

  const MobileDashboardHome({
    super.key,
    required this.onEditInvoice,
    required this.onCloneInvoice,
    required this.user,
  });

  @override
  ConsumerState<MobileDashboardHome> createState() =>
      _MobileDashboardHomeState();
}

class _MobileDashboardHomeState extends ConsumerState<MobileDashboardHome> {
  bool _isLoading = true;
  String? _loadError;
  int _customerCount = 0;
  int _productCount = 0;
  int _invoiceCount = 0;
  double _revenue = 0;
  double _outstanding = 0;
  String _currencySymbol = '₹';
  List<Invoice> _recentInvoices = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final results = await Future.wait([
        ref.read(customerRepositoryProvider).getTotalCustomerCount(),
        ref.read(productRepositoryProvider).getTotalProductCount(),
        ref.read(invoiceRepositoryProvider).getDashboardFinancials(),
        ref.read(invoiceRepositoryProvider).getRecentInvoices(limit: 5),
        ref.read(settingsRepositoryProvider).getCurrency(),
      ]);

      if (!mounted) return;
      final financials =
          results[2] as ({int count, double revenue, double outstanding});
      final currency = results[4] as CurrencyOption;
      setState(() {
        _customerCount = results[0] as int;
        _productCount = results[1] as int;
        _invoiceCount = financials.count;
        _revenue = financials.revenue;
        _outstanding = financials.outstanding;
        _recentInvoices = results[3] as List<Invoice>;
        _currencySymbol = currency.symbol;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = error.toString();
      });
    }
  }

  Widget _metricCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: colors.onPrimaryContainer),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _metrics() {
    final l10n = AppLocalizations.of(context)!;
    final cards = [
      _metricCard(
        label: l10n.navCustomers,
        value: '$_customerCount',
        icon: Icons.people_outline,
      ),
      _metricCard(
        label: l10n.navProducts,
        value: '$_productCount',
        icon: Icons.inventory_2_outlined,
      ),
      _metricCard(
        label: l10n.navInvoices,
        value: '$_invoiceCount',
        icon: Icons.receipt_long_outlined,
      ),
      _metricCard(
        label: l10n.dashboardRevenueCollectedLabel,
        value: '$_currencySymbol${_revenue.toStringAsFixed(2)}',
        icon: Icons.account_balance_wallet_outlined,
      ),
      _metricCard(
        label: l10n.dashboardOutstandingLabel,
        value: '$_currencySymbol${_outstanding.toStringAsFixed(2)}',
        icon: Icons.hourglass_top_outlined,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        final columns = constraints.maxWidth >= 700 ? 3 : 2;
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final card in cards) SizedBox(width: cardWidth, child: card),
          ],
        );
      },
    );
  }

  String _invoiceTypeLabel(Invoice invoice) {
    final l10n = AppLocalizations.of(context)!;
    return switch (invoice.type) {
      'Quotation' => l10n.labelQuotation,
      'Receipt' => l10n.labelReceipt,
      _ => l10n.labelInvoice,
    };
  }

  Widget _recentInvoiceCard(Invoice invoice) {
    final colors = Theme.of(context).colorScheme;
    final number = invoice.invoiceNumber ?? invoice.id;
    final outstanding = invoice.outstandingBalance;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_invoiceTypeLabel(invoice)} #$number',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  DateFormat('dd MMM yyyy').format(invoice.date),
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              invoice.customer.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text(
                  '${invoice.currencySymbol}${invoice.total.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (outstanding > 0.005)
                  Text(
                    'Due ${invoice.currencySymbol}${outstanding.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colors.error,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => widget.onEditInvoice(invoice),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: 'Duplicate',
                  onSelected: (type) => widget.onCloneInvoice(invoice, type),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'Invoice',
                      child: Text(AppLocalizations.of(context)!.labelInvoice),
                    ),
                    PopupMenuItem(
                      value: 'Quotation',
                      child: Text(AppLocalizations.of(context)!.labelQuotation),
                    ),
                  ],
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.copy_outlined, size: 18),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardOverviewTitle),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionRefresh,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 42, color: colors.error),
                        const SizedBox(height: 12),
                        Text(
                          'Could not load dashboard',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      Text(
                        'Hi, ${widget.user.username}',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.dashboardOverviewTitle,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 18),
                      _metrics(),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.dashboardRecentInvoicesTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            '${_recentInvoices.length}/5',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_recentInvoices.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.outlineVariant),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            l10n.dashboardNoInvoicesYetTitle,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        )
                      else
                        for (final invoice in _recentInvoices)
                          _recentInvoiceCard(invoice),
                    ],
                  ),
                ),
    );
  }
}
