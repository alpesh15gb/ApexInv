import 'package:flutter/material.dart';

import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/providers/industry_provider.dart';

/// Canonical dashboard destinations.
///
/// The integer [id] is the stable legacy tab id: deep-links, the compact
/// bottom bar, the More menu, and in-screen shortcuts all still navigate by
/// id, so ids must never be renumbered. Id 12 never owned a screen and
/// aliases to reports. Presentation (icons, labels, sections, admin gating)
/// lives here instead of scattered across the shell.
enum DashboardTab {
  dashboard(0),
  createInvoice(1),
  salesInvoices(2),
  estimates(3),
  paymentIn(4),
  parties(5),
  items(6),
  reports(7),
  expenses(8),
  purchaseOrders(9),
  settings(10),
  purchaseBills(11),
  creditNote(13),
  debitNote(14),
  deliveryChallan(15),
  proforma(16),
  reminders(17),
  auditLog(18),
  saleOrders(19),
  pos(20),
  paymentOut(21),
  bankAccounts(22),
  cashInHand(23),
  cheques(24),
  loanAccounts(25),
  metalRates(26),
  jobWork(27),
  moreMenu(100);

  const DashboardTab(this.id);
  final int id;

  static DashboardTab? fromId(int id) {
    // Id 12 never owned a screen (Trial Balance lives in Reports).
    if (id == 12) return DashboardTab.reports;
    for (final tab in DashboardTab.values) {
      if (tab.id == id) return tab;
    }
    return null;
  }
}

enum DashboardSection { none, sales, purchase, cashBank }

extension DashboardDestination on DashboardTab {
  IconData get outlinedIcon => switch (this) {
        DashboardTab.dashboard => Icons.dashboard_outlined,
        DashboardTab.createInvoice => Icons.receipt_outlined,
        DashboardTab.salesInvoices => Icons.receipt_long_outlined,
        DashboardTab.estimates => Icons.request_quote_outlined,
        DashboardTab.paymentIn => Icons.payments_outlined,
        DashboardTab.parties => Icons.people_outline,
        DashboardTab.items => Icons.inventory_2_outlined,
        DashboardTab.reports => Icons.bar_chart_outlined,
        DashboardTab.expenses => Icons.receipt_long_outlined,
        DashboardTab.purchaseOrders => Icons.shopping_cart_outlined,
        DashboardTab.settings => Icons.settings_outlined,
        DashboardTab.purchaseBills => Icons.inventory_outlined,
        DashboardTab.creditNote => Icons.note_alt_outlined,
        DashboardTab.debitNote => Icons.note_add_outlined,
        DashboardTab.deliveryChallan => Icons.local_shipping_outlined,
        DashboardTab.proforma => Icons.request_page_outlined,
        DashboardTab.reminders => Icons.notifications_active_outlined,
        DashboardTab.auditLog => Icons.fact_check_outlined,
        DashboardTab.saleOrders => Icons.shopping_bag_outlined,
        DashboardTab.pos => Icons.point_of_sale_outlined,
        DashboardTab.paymentOut => Icons.payments_outlined,
        DashboardTab.bankAccounts => Icons.account_balance_outlined,
        DashboardTab.cashInHand => Icons.account_balance_wallet_outlined,
        DashboardTab.cheques => Icons.confirmation_number_outlined,
        DashboardTab.loanAccounts => Icons.request_quote_outlined,
        DashboardTab.metalRates => Icons.scale_outlined,
        DashboardTab.jobWork => Icons.handyman_outlined,
        DashboardTab.moreMenu => Icons.more_horiz,
      };

  IconData get filledIcon => switch (this) {
        DashboardTab.dashboard => Icons.dashboard,
        DashboardTab.createInvoice => Icons.receipt,
        DashboardTab.salesInvoices => Icons.receipt_long,
        DashboardTab.estimates => Icons.request_quote,
        DashboardTab.paymentIn => Icons.payments,
        DashboardTab.parties => Icons.people,
        DashboardTab.items => Icons.inventory_2,
        DashboardTab.reports => Icons.bar_chart,
        DashboardTab.expenses => Icons.receipt_long,
        DashboardTab.purchaseOrders => Icons.shopping_cart,
        DashboardTab.settings => Icons.settings,
        DashboardTab.purchaseBills => Icons.inventory,
        DashboardTab.creditNote => Icons.note_alt,
        DashboardTab.debitNote => Icons.note_add,
        DashboardTab.deliveryChallan => Icons.local_shipping,
        DashboardTab.proforma => Icons.request_page,
        DashboardTab.reminders => Icons.notifications_active,
        DashboardTab.auditLog => Icons.fact_check,
        DashboardTab.saleOrders => Icons.shopping_bag,
        DashboardTab.pos => Icons.point_of_sale,
        DashboardTab.paymentOut => Icons.payments,
        DashboardTab.bankAccounts => Icons.account_balance,
        DashboardTab.cashInHand => Icons.account_balance_wallet,
        DashboardTab.cheques => Icons.confirmation_number,
        DashboardTab.loanAccounts => Icons.request_quote,
        DashboardTab.metalRates => Icons.scale,
        DashboardTab.jobWork => Icons.handyman,
        DashboardTab.moreMenu => Icons.more_horiz,
      };

  String label(AppLocalizations l10n) => switch (this) {
        DashboardTab.dashboard => l10n.navDashboard,
        DashboardTab.createInvoice => l10n.navNewInvoice,
        DashboardTab.salesInvoices => l10n.navSalesInvoices,
        DashboardTab.estimates => l10n.navEstimates,
        DashboardTab.paymentIn => l10n.navPaymentIn,
        DashboardTab.parties => l10n.navParties,
        DashboardTab.items => l10n.navItems,
        DashboardTab.reports => l10n.navReports,
        DashboardTab.expenses => l10n.navExpenses,
        DashboardTab.purchaseOrders => l10n.navPurchaseOrder,
        DashboardTab.settings => l10n.navSettings,
        DashboardTab.purchaseBills => l10n.navPurchaseBills,
        DashboardTab.creditNote => l10n.navCreditNote,
        DashboardTab.debitNote => l10n.navDebitNote,
        DashboardTab.deliveryChallan => l10n.navDeliveryChallan,
        DashboardTab.proforma => l10n.navProformaInvoice,
        DashboardTab.reminders => l10n.navReminders,
        DashboardTab.auditLog => l10n.navAuditLog,
        DashboardTab.saleOrders => l10n.navSaleOrder,
        DashboardTab.pos => l10n.navPos,
        DashboardTab.paymentOut => l10n.navPaymentOut,
        DashboardTab.bankAccounts => l10n.navBankAccounts,
        DashboardTab.cashInHand => l10n.navCashInHand,
        DashboardTab.cheques => l10n.navCheques,
        DashboardTab.loanAccounts => l10n.navLoanAccounts,
        DashboardTab.metalRates => l10n.navMetalRates,
        DashboardTab.jobWork => l10n.navJobWork,
        DashboardTab.moreMenu => l10n.navMore,
      };

  DashboardSection get section => switch (this) {
        DashboardTab.salesInvoices ||
        DashboardTab.estimates ||
        DashboardTab.proforma ||
        DashboardTab.paymentIn ||
        DashboardTab.saleOrders ||
        DashboardTab.deliveryChallan ||
        DashboardTab.creditNote ||
        DashboardTab.pos =>
          DashboardSection.sales,
        DashboardTab.purchaseBills ||
        DashboardTab.purchaseOrders ||
        DashboardTab.paymentOut ||
        DashboardTab.expenses ||
        DashboardTab.debitNote =>
          DashboardSection.purchase,
        DashboardTab.bankAccounts ||
        DashboardTab.cashInHand ||
        DashboardTab.cheques ||
        DashboardTab.loanAccounts =>
          DashboardSection.cashBank,
        _ => DashboardSection.none,
      };

  /// Section header shown above the first destination of each group.
  String? sectionHeader(AppLocalizations l10n) => switch (this) {
        DashboardTab.salesInvoices => l10n.navSectionSales,
        DashboardTab.purchaseBills => l10n.navSectionPurchase,
        DashboardTab.bankAccounts => l10n.navSectionCashBank,
        _ => null,
      };

  bool get adminOnly => this == DashboardTab.auditLog;
  bool get showsUpdateDot => this == DashboardTab.settings;

  /// Trades that see this destination. Null = shared by every trade.
  Set<IndustryProfile>? get industries => switch (this) {
        DashboardTab.metalRates => const {IndustryProfile.jewellery},
        DashboardTab.jobWork => const {IndustryProfile.jewellery},
        // These generic workflows only persist a catalog price/quantity. Hide
        // them in jewellery mode until they can freeze sell rates, weights,
        // making charges, and tagged-piece identity like the invoice editor.
        DashboardTab.saleOrders || DashboardTab.pos => const {
            IndustryProfile.retail
          },
        _ => null,
      };
}

/// Sidebar order. Section headers render from [sectionHeader] above the
/// first destination of each group.
const dashboardSidebarOrder = [
  DashboardTab.dashboard,
  DashboardTab.parties,
  DashboardTab.items,
  DashboardTab.metalRates,
  DashboardTab.jobWork,
  DashboardTab.salesInvoices,
  DashboardTab.estimates,
  DashboardTab.proforma,
  DashboardTab.paymentIn,
  DashboardTab.saleOrders,
  DashboardTab.deliveryChallan,
  DashboardTab.creditNote,
  DashboardTab.pos,
  DashboardTab.purchaseBills,
  DashboardTab.purchaseOrders,
  DashboardTab.paymentOut,
  DashboardTab.expenses,
  DashboardTab.debitNote,
  DashboardTab.bankAccounts,
  DashboardTab.cashInHand,
  DashboardTab.cheques,
  DashboardTab.loanAccounts,
  DashboardTab.reports,
  DashboardTab.createInvoice,
  DashboardTab.settings,
  DashboardTab.reminders,
  DashboardTab.auditLog,
];

/// Compact bottom-bar destinations (Home / New / Invoices / Parties / More).
const mobileTabTargets = [
  DashboardTab.dashboard,
  DashboardTab.createInvoice,
  DashboardTab.salesInvoices,
  DashboardTab.parties,
  DashboardTab.moreMenu,
];
