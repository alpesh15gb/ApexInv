import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/widgets/discovery_banner.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/providers/app_config_provider.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/services/update_service.dart';
import 'package:apexbooks/services/analytics/cloudflare_analytics_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/licensing/license_service.dart';
import 'package:apexbooks/widgets/update_dialog.dart';
import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/customer_identity.dart';
import 'package:apexbooks/common/app_colors.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/screens/settings/settings_screen.dart';
import 'package:apexbooks/services/invoice_pdf_services.dart';
import 'package:apexbooks/services/pdf_service.dart';
import 'package:apexbooks/utils/formatters.dart';
import 'package:apexbooks/widgets/apply_payment_dialog.dart';
import 'package:apexbooks/widgets/customer_info_button.dart';
import 'package:apexbooks/utils/session_manager.dart';
import 'package:apexbooks/widgets/app/app.dart';

import 'package:apexbooks/models/user.dart';
// import 'package:apexbooks/screens/customer_management_screen.dart';
import 'package:apexbooks/screens/customer_management_screen_v2.dart';
import 'package:apexbooks/database/audit_log_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/report_service.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/services/reminder_service.dart';
import 'package:apexbooks/screens/import_screen.dart';
import 'package:apexbooks/screens/screens_v1/create_invoice_screen.dart' as v1;
import 'package:apexbooks/screens/create_invoice_screen_v2.dart';
// import 'package:apexbooks/screens/product_management_screen.dart';
import 'package:apexbooks/screens/product_management_screen_v2.dart';
// import 'package:apexbooks/screens/invoice_management_screen.dart';
import 'package:apexbooks/screens/invoice_management_screen_v2.dart';
import 'package:apexbooks/screens/auth/login_screen.dart';
import 'package:apexbooks/screens/reports_screen.dart';
import 'package:apexbooks/screens/expense_management_screen.dart';
import 'package:apexbooks/screens/purchase_order_screen.dart';
import 'package:apexbooks/screens/more_menu_screen.dart';
import 'package:apexbooks/screens/purchase_bill_screen.dart';
import 'package:apexbooks/screens/reminders_screen.dart';
import 'package:apexbooks/screens/audit_log_screen.dart';
import 'package:apexbooks/screens/cheques_screen.dart';
import 'package:apexbooks/screens/financial_accounts_screen.dart';
import 'package:apexbooks/screens/loan_accounts_screen.dart';
import 'package:apexbooks/screens/payment_out_screen.dart';
import 'package:apexbooks/screens/pos_screen.dart';
import 'package:apexbooks/screens/sale_orders_screen.dart';
import 'package:apexbooks/database/recurring_invoice_engine.dart';

// invoice.type is a raw internal value ('Invoice'/'Quotation'/'Receipt'/
// 'Credit Note'/'Debit Note'/'Delivery Challan'/'Proforma') used
// for comparisons throughout this file — only the displayed label is localized.
String _invoiceTypeLabel(BuildContext context, String type) {
  final l10n = AppLocalizations.of(context)!;
  switch (type) {
    case 'Quotation':
      return l10n.labelQuotation;
    case 'Receipt':
      return l10n.labelReceipt;
    case 'Credit Note':
      return 'Credit Note';
    case 'Debit Note':
      return 'Debit Note';
    case 'Delivery Challan':
      return 'Delivery Challan';
    case 'Proforma':
      return 'Proforma';
    default:
      return l10n.labelInvoice;
  }
}

// Dashboard Screen
class DashboardScreen extends ConsumerStatefulWidget {
  final User loggedInUser;

  const DashboardScreen(this.loggedInUser, {super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const int _moreTabIndex = 100;

  /// Tab indices surfaced by the compact-shell bottom navigation bar
  /// (Home / New / Invoices / Customers / More).
  static const List<int> _mobileTabTargets = [0, 1, 2, 5, _moreTabIndex];

  int _selectedIndex = 0;
  bool _sidebarExpanded = true;
  late User _currentUser;
  String? _pendingReportsStatementCustomerKey;

  Invoice? invoiceToEdit;
  Invoice? _invoiceToClone;
  String _cloneType = 'Invoice';
  String _newInvoiceType = 'Invoice';
  bool _hasUpdate = false;
  String _createInvoiceLayout = 'v2';
  int? _accessibilityJumpToken;
  final InvoiceFormGuard _invoiceFormGuard = InvoiceFormGuard();
  final v1.InvoiceFormGuard _invoiceFormGuardV1 = v1.InvoiceFormGuard();
  final FocusNode _shortcutsFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentUser = widget.loggedInUser;
    AuditActor.setCurrent(_currentUser.username);
    SessionManager.initialize(_logoutAndResetSession);
    _loadCreateInvoiceLayout();
    // Anonymous usage heartbeat: at most one ping per day, only with
    // explicit consent. Fire-and-forget; offline or opted-out = silence.
    _sendAnalyticsHeartbeat();
    // License/trial status for the banner. Display-only; enforcement lives
    // in LicenseGate at the document-creation choke points.
    _loadLicenseStatus();
    // Offline-first recurring billing: generate due instances on start.
    RecurringInvoiceEngine.generateDue().catchError((_) => 0);
    if (ref.read(appEditionConfigProvider).enableUpdateCheck) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdates());
    }
    // Tab 1 (Create Invoice) owns its own autofocus/shortcuts — only claim
    // focus here for the other tabs, so it doesn't get stolen away and
    // block the Create Invoice screen's own Ctrl shortcuts from working.
    if (_selectedIndex != 1) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _shortcutsFocusNode.requestFocus());
    }
  }

  Future<void> _sendAnalyticsHeartbeat() async {
    try {
      final settingsRepo = ref.read(settingsRepositoryProvider);
      final consent =
          await settingsRepo.getSetting(SettingKey.analyticsConsent);
      if (consent != 'granted') return;
      final lastSent =
          await settingsRepo.getSetting(SettingKey.analyticsLastSent);
      final sentDay = await CloudflareAnalyticsService.maybeSendHeartbeat(
        consented: true,
        lastSentDay: lastSent,
      );
      if (sentDay != null && sentDay != lastSent) {
        await settingsRepo.setSetting(SettingKey.analyticsLastSent, sentDay);
      }
    } catch (_) {
      // Telemetry must never disturb the app.
    }
  }

  LicenseStatus? _licenseStatus;
  bool _licenseBannerDismissed = false;

  Future<void> _loadLicenseStatus() async {
    try {
      final status = await LicenseGate.check();
      if (!mounted) return;
      setState(() => _licenseStatus = status);
    } catch (_) {
      // Licensing display must never disturb the app.
    }
  }

  bool get _showLicenseBanner {
    final status = _licenseStatus;
    if (status == null) return false;
    if (status.isReadOnly) return true;
    if (status.isGrace) return true;
    if (status.isTrialExpiring && !_licenseBannerDismissed) return true;
    return false;
  }

  Widget _buildLicenseBanner() {
    final status = _licenseStatus!;
    final Color bg;
    final String text;
    if (status.isReadOnly) {
      bg = Theme.of(context).colorScheme.error;
      text = 'Trial expired — read-only. Your data is safe.';
    } else if (status.isGrace) {
      bg = Colors.orange.shade800;
      text =
          'Trial ended — ${status.daysLeft} grace days left. Activate to keep creating documents.';
    } else {
      bg = Colors.orange.shade800;
      text = 'Free trial ends in ${status.daysLeft} days (5 May 2027).';
    }
    return Material(
      color: bg,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.workspace_premium_outlined,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => LicenseGate.openLicenseScreen(context),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Activate'),
              ),
              if (!status.isReadOnly && !status.isGrace)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 18),
                  onPressed: () =>
                      setState(() => _licenseBannerDismissed = true),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadCreateInvoiceLayout() async {
    final layout = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.createInvoiceLayout);
    if (!mounted) return;
    setState(() => _createInvoiceLayout = layout ?? 'v2');
  }

  Future<void> _checkForUpdates() async {
    final info = await UpdateService.checkForUpdate();
    if (info == null) return;
    if (info.hasUpdate && mounted) setState(() => _hasUpdate = true);
    if (!await UpdateService.shouldNotify(info)) return;
    if (!mounted) return;
    await UpdateDialog.show(context, info);
  }

  @override
  void dispose() {
    SessionManager.dispose();
    _shortcutsFocusNode.dispose();
    super.dispose();
  }

  void _logoutAndResetSession() async {
    // Forget the persisted auto-login user, then drop to the login screen.
    AuditActor.clear();
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.currentUserId, '');
    await ref.read(authRepositoryProvider).logoutAndSessionReset();
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _refreshUser() async {
    final cfg = ref.watch(appEditionConfigProvider);
    if (cfg.isCloud || !mounted) return;
    final fresh =
        await ref.read(authRepositoryProvider).getUserById(_currentUser.id);
    if (fresh != null && mounted) {
      setState(() => _currentUser = fresh);
      AuditActor.setCurrent(fresh.username);
    }
  }

  Widget buildScreen() {
    switch (_selectedIndex) {
      case 0:
        return DashboardHome(
            onEditInvoice: editInvoice,
            onCloneInvoice: cloneInvoice,
            onCreateInvoice: () => _openNewDocument('Invoice'),
            onNavigateTab: (index) {
              _selectTab(index);
            },
            user: _currentUser);
      case 1:
        final createInvoiceKey = ValueKey(
            'create_invoice_${invoiceToEdit?.id ?? 'new'}_${_invoiceToClone?.id ?? ''}_$_newInvoiceType');
        void onCreateNewInvoice() {
          if (!mounted) return;
          setState(() {
            invoiceToEdit = null;
            _invoiceToClone = null;
          });
        }
        return _createInvoiceLayout == 'v1'
            ? v1.CreateInvoiceScreen(
                key: createInvoiceKey,
                invoiceToEdit: invoiceToEdit,
                cloneFrom: _invoiceToClone,
                cloneType: _invoiceToClone != null ? _cloneType : null,
                initialType: _newInvoiceType,
                guard: _invoiceFormGuardV1,
                onCreateNewInvoice: onCreateNewInvoice,
              )
            : CreateInvoiceScreenV2(
                key: createInvoiceKey,
                invoiceToEdit: invoiceToEdit,
                cloneFrom: _invoiceToClone,
                cloneType: _invoiceToClone != null ? _cloneType : null,
                initialType: _newInvoiceType,
                guard: _invoiceFormGuard,
                onCreateNewInvoice: onCreateNewInvoice,
              );
      case 2:
        return InvoiceManagementScreenV2(
          key: const ValueKey('invoice_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Invoice'),
          user: _currentUser,
          filterType: 'Invoice',
        );
      case 3:
        return InvoiceManagementScreenV2(
          key: const ValueKey('quotation_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Quotation'),
          user: _currentUser,
          filterType: 'Quotation',
        );
      case 4:
        return InvoiceManagementScreenV2(
          key: const ValueKey('receipt_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Receipt'),
          user: _currentUser,
          filterType: 'Receipt',
        );
      case 5:
        return CustomerManagementScreenV2(
          user: _currentUser,
          onViewCustomerStatement: (c) {
            setState(() {
              _pendingReportsStatementCustomerKey =
                  CustomerIdentity.key(id: c.id, name: c.name);
              _selectedIndex = 7;
            });
          },
        );
      case 6:
        return ProductManagementScreenV2(user: _currentUser);
      case 7:
        final statementCustomerKey = _pendingReportsStatementCustomerKey;
        _pendingReportsStatementCustomerKey = null;
        return ReportsScreen(initialStatementCustomerKey: statementCustomerKey);
      case 8:
        return const ExpenseManagementScreen();
      case 9:
        return PurchaseOrderScreen(user: _currentUser);
      case 11:
        return PurchaseBillScreen(user: _currentUser);
      case 12:
        // No dedicated screen ever owned index 12 (Trial Balance lives in
        // Reports) — land on Reports instead of the 'Unknown tab' fallback
        // so stale deep-links/bookmarks keep working.
        return const ReportsScreen();
      case 13:
        return InvoiceManagementScreenV2(
          key: const ValueKey('credit_note_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Credit Note'),
          user: _currentUser,
          filterType: 'Credit Note',
        );
      case 14:
        return InvoiceManagementScreenV2(
          key: const ValueKey('debit_note_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Debit Note'),
          user: _currentUser,
          filterType: 'Debit Note',
        );
      case 15:
        return InvoiceManagementScreenV2(
          key: const ValueKey('challan_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Delivery Challan'),
          user: _currentUser,
          filterType: 'Delivery Challan',
        );
      case 16:
        return InvoiceManagementScreenV2(
          key: const ValueKey('proforma_list'),
          onEditInvoice: editInvoice,
          onCloneInvoice: cloneInvoice,
          onCreateInvoice: () => _openNewDocument('Proforma'),
          user: _currentUser,
          filterType: 'Proforma',
        );
      case 17:
        return const RemindersScreen();
      case 18:
        return const AuditLogScreen();
      case 19:
        return const SaleOrdersScreen();
      case 20:
        return const PosScreen();
      case 21:
        return const PaymentOutScreen();
      case 22:
        return const FinancialAccountsScreen(accountType: 'bank');
      case 23:
        return const FinancialAccountsScreen(accountType: 'cash');
      case 24:
        return const ChequesScreen();
      case 25:
        return const LoanAccountsScreen();
      case 10:
        return SettingsScreen(
          currentUser: _currentUser,
          openAccessibilityToken: _accessibilityJumpToken,
        );
      case _moreTabIndex:
        return MoreMenuScreen(
          user: _currentUser,
          hasUpdate: _hasUpdate,
          onSelectTab: _selectTab,
          onLogout: _logoutAndResetSession,
        );
      default:
        return Center(
            child:
                Text(AppLocalizations.of(context)!.dashboardUnknownTabLabel));
    }
  }

  Widget _buildCreateInvoiceLayoutToggle() {
    final isV2 = _createInvoiceLayout == 'v2';
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: CircleBorder(
          side:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      elevation: 2,
      child: IconButton(
        icon: Icon(isV2 ? Icons.auto_awesome : Icons.history, size: 20),
        tooltip: l10n.dashboardInvoiceLayoutTooltip(
            isV2 ? l10n.dashboardLayoutNew : l10n.dashboardLayoutClassic),
        onPressed: _showCreateInvoiceLayoutInfo,
      ),
    );
  }

  void _showCreateInvoiceLayoutInfo() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dashboardInvoiceLayoutDialogTitle),
        content: Text(l10n.dashboardInvoiceLayoutDialogBody(
            _createInvoiceLayout == 'v1'
                ? l10n.dashboardLayoutClassic
                : l10n.dashboardLayoutNew)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.actionClose)),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!await _canLeaveInvoiceForm()) return;
              if (!mounted) return;
              setState(() {
                _selectedIndex = 8;
                _accessibilityJumpToken = (_accessibilityJumpToken ?? 0) + 1;
              });
            },
            child: Text(l10n.dashboardOpenSettingsAction),
          ),
        ],
      ),
    );
  }

  void editInvoice(Invoice invoice) {
    _openEditInvoice(invoice);
  }

  Future<void> _openEditInvoice(Invoice invoice) async {
    if (!await _canLeaveInvoiceForm()) return;
    if (!mounted) return;
    setState(() {
      _selectedIndex = 1;
      invoiceToEdit = invoice;
      _invoiceToClone = null;
    });
    _shortcutsFocusNode.unfocus();
  }

  void cloneInvoice(Invoice invoice, String type) {
    _openCloneInvoice(invoice, type);
  }

  Future<void> _openCloneInvoice(Invoice invoice, String type) async {
    if (!await _canLeaveInvoiceForm()) return;
    if (!mounted) return;
    setState(() {
      _selectedIndex = 1;
      invoiceToEdit = null;
      _invoiceToClone = invoice;
      _cloneType = type;
    });
    _shortcutsFocusNode.unfocus();
  }

  Future<bool> _canLeaveInvoiceForm() async {
    if (_createInvoiceLayout == 'v1') {
      return await _invoiceFormGuardV1.canLeave?.call() ?? true;
    }
    return await _invoiceFormGuard.canLeave?.call() ?? true;
  }

  Future<void> _openNewDocument(String type) async {
    if (_selectedIndex == 1 && !await _canLeaveInvoiceForm()) return;
    if (_selectedIndex != 1) await _selectTab(1);
    if (!mounted) return;
    setState(() {
      invoiceToEdit = null;
      _invoiceToClone = null;
      _newInvoiceType = type;
    });
  }

  Future<void> _selectTab(int index) async {
    if (_selectedIndex == index) return;
    if (_selectedIndex == 1 && !await _canLeaveInvoiceForm()) return;
    if (_selectedIndex == 7 && index != 7) await _refreshUser();
    if (index == 1) await _loadCreateInvoiceLayout();
    if (!mounted) return;
    setState(() {
      _selectedIndex = index;
      if (index != 1) {
        invoiceToEdit = null;
        _invoiceToClone = null;
      } else {
        _newInvoiceType = 'Invoice';
      }
    });
    // See initState: only hold shortcuts focus for non-create-invoice tabs.
    // Autofocus is a no-op while this scope already has a focused node, so
    // on the way IN to tab 1 we must explicitly unfocus — otherwise Create
    // Invoice's own `Focus(autofocus: true)` never actually takes focus and
    // its Ctrl+S/N/M/O/P shortcuts silently stop firing.
    if (index == 1) {
      _shortcutsFocusNode.unfocus();
    } else {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _shortcutsFocusNode.requestFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () =>
            _selectTab(1),
      },
      child: Listener(
        onPointerDown: (_) => SessionManager.onUserActivity(),
        onPointerMove: (_) => SessionManager.onUserActivity(),
        child: Focus(
          focusNode: _shortcutsFocusNode,
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                final screen = Stack(
                  children: [
                    buildScreen(),
                    // Floating v1/v2 layout toggle: desktop only. On compact it
                    // overlaps the Create Invoice bottom action bar (the same
                    // toggle lives in Settings → Accessibility).
                    if (_selectedIndex == 1 &&
                        constraints.maxWidth >= Breakpoints.expandedMin)
                      Positioned(
                          bottom: 16,
                          right: 16,
                          child: _buildCreateInvoiceLayoutToggle()),
                    // License/trial banner overlays the top of every tab.
                    if (_showLicenseBanner)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _buildLicenseBanner(),
                      ),
                  ],
                );
                if (constraints.maxWidth >= Breakpoints.expandedMin) {
                  return Row(
                    children: [
                      _buildSidebar(),
                      Expanded(child: screen),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: SafeArea(top: true, bottom: false, child: screen),
                    ),
                    _buildBottomNavigationBar(),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  int get _mobileNavIndex {
    final index = _mobileTabTargets.indexOf(_selectedIndex);
    // Destinations living inside "More" (quotations, receipts, reports, ...)
    // keep the More tab highlighted.
    return index < 0 ? _mobileTabTargets.length - 1 : index;
  }

  Widget _buildBottomNavigationBar() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final updateBadge = Badge(
      smallSize: 8,
      isLabelVisible: _hasUpdate,
      child: const Icon(Icons.more_horiz),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
            color: theme.colorScheme.outlineVariant, height: 1, thickness: 1),
        NavigationBar(
          height: 72,
          backgroundColor: theme.colorScheme.surfaceContainer,
          indicatorColor: theme.primaryColor.withValues(alpha: 0.12),
          selectedIndex: _mobileNavIndex,
          onDestinationSelected: (i) => _selectTab(_mobileTabTargets[i]),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.dashboard_outlined),
              selectedIcon: const Icon(Icons.dashboard),
              label: l10n.navDashboard,
            ),
            NavigationDestination(
              icon: const Icon(Icons.receipt_outlined),
              selectedIcon: const Icon(Icons.receipt),
              label: l10n.navNewInvoice,
            ),
            NavigationDestination(
              icon: const Icon(Icons.receipt_long_outlined),
              selectedIcon: const Icon(Icons.receipt_long),
              label: l10n.navInvoices,
            ),
            NavigationDestination(
              icon: const Icon(Icons.people_outline),
              selectedIcon: const Icon(Icons.people),
              label: l10n.navCustomers,
            ),
            NavigationDestination(
              icon: updateBadge,
              selectedIcon: updateBadge,
              label: l10n.navMore,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    final expanded = _sidebarExpanded;
    final primary = Theme.of(context).primaryColor;
    final cfg = ref.watch(appEditionConfigProvider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: expanded ? 210 : 64,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border(
            right: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant, width: 1)),
      ),
      child: ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Logo + toggle ──────────────────────────
            if (expanded)
              SizedBox(
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Positioned(
                      left: 16,
                      right: 36,
                      child: AppBrandLogo(height: 36),
                    ),
                    Positioned(
                      right: 6,
                      child: Tooltip(
                        message: AppLocalizations.of(context)!
                            .dashboardCollapseSidebarTooltip,
                        child: InkWell(
                          onTap: () {
                            if (!mounted) return;
                            setState(() => _sidebarExpanded = false);
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(Icons.chevron_left_rounded,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                size: 20),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                height: 76,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const AppBrandLogo(height: 38, showWordmark: false),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: AppLocalizations.of(context)!
                          .dashboardExpandSidebarTooltip,
                      child: InkWell(
                        onTap: () {
                          if (!mounted) return;
                          setState(() => _sidebarExpanded = true);
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.chevron_right_rounded,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            Divider(
                color: Theme.of(context).colorScheme.outlineVariant,
                height: 1,
                thickness: 1),
            const SizedBox(height: 8),

            // ── Nav Items — Tally-style grouped ─────────────────
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildNavItem(0, Icons.dashboard_outlined, Icons.dashboard,
                        AppLocalizations.of(context)!.navDashboard),
                    const SizedBox(height: 4),
                    _buildNavItem(
                        5, Icons.people_outline, Icons.people, 'Parties'),
                    _buildNavItem(6, Icons.inventory_2_outlined,
                        Icons.inventory_2, 'Items'),
                    if (expanded) const Divider(height: 16),
                    if (expanded) _buildSectionHeader('Sales (Master)'),
                    _buildNavItem(2, Icons.receipt_long_outlined,
                        Icons.receipt_long, 'Sales Invoices'),
                    _buildNavItem(3, Icons.request_quote_outlined,
                        Icons.request_quote, 'Estimates'),
                    _buildNavItem(16, Icons.request_page_outlined,
                        Icons.request_page, 'Proforma Invoice'),
                    _buildNavItem(4, Icons.payments_outlined, Icons.payments,
                        'Payment In'),
                    _buildNavItem(19, Icons.shopping_bag_outlined,
                        Icons.shopping_bag, 'Sale Order'),
                    _buildNavItem(15, Icons.local_shipping_outlined,
                        Icons.local_shipping, 'Delivery Challan'),
                    _buildNavItem(13, Icons.note_alt_outlined, Icons.note_alt,
                        'Credit Note'),
                    _buildNavItem(20, Icons.point_of_sale_outlined,
                        Icons.point_of_sale, 'POS'),
                    if (expanded) const Divider(height: 16),
                    if (expanded) _buildSectionHeader('Purchase (Master)'),
                    _buildNavItem(11, Icons.inventory_outlined, Icons.inventory,
                        'Purchase Bills'),
                    _buildNavItem(9, Icons.shopping_cart_outlined,
                        Icons.shopping_cart, 'Purchase Order'),
                    _buildNavItem(21, Icons.payments_outlined, Icons.payments,
                        'Payment Out'),
                    _buildNavItem(8, Icons.receipt_long_outlined,
                        Icons.receipt_long, 'Expenses'),
                    _buildNavItem(14, Icons.note_add_outlined, Icons.note_add,
                        'Debit Note'),
                    if (expanded) const Divider(height: 16),
                    if (expanded) _buildSectionHeader('Cash And Bank'),
                    _buildNavItem(22, Icons.account_balance_outlined,
                        Icons.account_balance, 'Bank Accounts'),
                    _buildNavItem(23, Icons.account_balance_wallet_outlined,
                        Icons.account_balance_wallet, 'Cash In Hand'),
                    _buildNavItem(24, Icons.confirmation_number_outlined,
                        Icons.confirmation_number, 'Cheques'),
                    _buildNavItem(25, Icons.request_quote_outlined,
                        Icons.request_quote, 'Loan Accounts'),
                    if (expanded) const Divider(height: 16),
                    _buildNavItem(7, Icons.bar_chart_outlined, Icons.bar_chart,
                        AppLocalizations.of(context)!.navReports),
                    _buildNavItem(1, Icons.receipt_outlined, Icons.receipt,
                        AppLocalizations.of(context)!.navNewInvoice),
                    _buildNavItem(10, Icons.settings_outlined, Icons.settings,
                        AppLocalizations.of(context)!.navSettings,
                        showDot: _hasUpdate),
                    _buildNavItem(17, Icons.notifications_active_outlined,
                        Icons.notifications_active, 'Reminders'),
                    if (_currentUser.isAdmin())
                      _buildNavItem(18, Icons.fact_check_outlined,
                          Icons.fact_check, 'Audit Log'),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),

            // ── User Info ──────────────────────────────
            Divider(
                color: Theme.of(context).colorScheme.outlineVariant,
                height: 1,
                thickness: 1),
            LayoutBuilder(
              builder: (context, constraints) {
                final useExpanded = constraints.maxWidth > 110;
                if (useExpanded) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 15,
                              backgroundColor: primary.withValues(alpha: 0.12),
                              child: Text(
                                _currentUser.username.isNotEmpty
                                    ? _currentUser.username[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                    color: primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _currentUser.username,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    _currentUser.isAdmin()
                                        ? AppLocalizations.of(context)!
                                            .dashboardRoleAdmin
                                        : AppLocalizations.of(context)!
                                            .dashboardRoleUser,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            Tooltip(
                              message: AppLocalizations.of(context)!
                                  .dashboardSupportTooltip,
                              child: InkWell(
                                onTap: () => launchUrl(
                                    Uri.parse(AppConfig.supportForm),
                                    mode: LaunchMode.externalApplication),
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.support_agent_outlined,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      size: 18),
                                ),
                              ),
                            ),
                            Tooltip(
                              message: AppLocalizations.of(context)!
                                  .dashboardLogoutTooltip,
                              child: InkWell(
                                onTap: () => _logoutAndResetSession(),
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.logout_rounded,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      size: 18),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            cfg.version,
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (TestBuildConfig.isTestBuild) ...[
                          const SizedBox(height: 4),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                AppLocalizations.of(context)!
                                    .dashboardTestBuildBadge,
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
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(
                        child: Tooltip(
                          message: _currentUser.username,
                          child: CircleAvatar(
                            radius: 15,
                            backgroundColor: primary.withValues(alpha: 0.12),
                            child: Text(
                              _currentUser.username.isNotEmpty
                                  ? _currentUser.username[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                  color: primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Tooltip(
                          message: AppLocalizations.of(context)!
                              .dashboardSupportTooltip,
                          child: InkWell(
                            onTap: () => launchUrl(
                                Uri.parse(AppConfig.supportForm),
                                mode: LaunchMode.externalApplication),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.support_agent_outlined,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  size: 18),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Tooltip(
                          message: AppLocalizations.of(context)!
                              .dashboardLogoutTooltip,
                          child: InkWell(
                            onTap: () => _logoutAndResetSession(),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.logout_rounded,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  size: 18),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Text(
                          cfg.version,
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(context).colorScheme.outlineVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (TestBuildConfig.isTestBuild) ...[
                        const SizedBox(height: 3),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              AppLocalizations.of(context)!
                                  .dashboardTestBadgeShort,
                              style: TextStyle(
                                fontSize: 7,
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
              },
            ),
          ],
        ),
      ), // ClipRect
    );
  }

  /*
  Widget _buildComingSoonNavItem(IconData icon, String label) {
    const disabledColor = Color(0xFFCBD5E1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final useExpanded = constraints.maxWidth > 110;

        if (!useExpanded) {
          return Tooltip(
            message: '$label — Coming Soon',
            preferBelow: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Container(
                padding: const EdgeInsets.all(12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: disabledColor, size: 20),
              ),
            ),
          );
        }

        return Tooltip(
          message: 'Coming Soon',
          preferBelow: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(icon, color: disabledColor, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: disabledColor,
                        fontWeight: FontWeight.w400,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: const Text(
                      'Soon',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: disabledColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  */

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AppSectionHeader(title),
    );
  }

  Widget _buildNavItem(
      int index, IconData outlinedIcon, IconData filledIcon, String label,
      {bool showDot = false}) {
    final selected = _selectedIndex == index;
    final primary = Theme.of(context).primaryColor;

    Future<void> onTap() => _selectTab(index);

    // Use LayoutBuilder so the layout switches based on actual rendered width,
    // not just state — prevents overflow errors during the AnimatedContainer transition.
    return LayoutBuilder(
      builder: (context, constraints) {
        final useExpanded = constraints.maxWidth > 110;

        if (!useExpanded) {
          return Tooltip(
            message: label,
            preferBelow: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(8),
                  hoverColor: primary.withValues(alpha: 0.06),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.all(12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? primary.withValues(alpha: 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          selected ? filledIcon : outlinedIcon,
                          color: selected
                              ? primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        if (showDot)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              hoverColor: primary.withValues(alpha: 0.06),
              splashColor: primary.withValues(alpha: 0.1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: selected
                      ? primary.withValues(alpha: 0.1)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          selected ? filledIcon : outlinedIcon,
                          color: selected
                              ? primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        if (showDot)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: selected
                              ? primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    if (selected)
                      Container(
                        width: 3,
                        height: 18,
                        decoration: BoxDecoration(
                          color: primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DashboardHome extends ConsumerStatefulWidget {
  final Function(Invoice) onEditInvoice;
  final Function(Invoice, String) onCloneInvoice;
  final User user;
  final VoidCallback? onCreateInvoice;

  /// Routes to another dashboard tab via the existing [_selectTab] routing
  /// (same guards/destinations as the sidebar and bottom navigation bar).
  final ValueChanged<int> onNavigateTab;
  const DashboardHome({
    required this.onEditInvoice,
    required this.onCloneInvoice,
    required this.user,
    required this.onNavigateTab,
    this.onCreateInvoice,
    super.key,
  });

  @override
  ConsumerState<DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends ConsumerState<DashboardHome> {
  final dbHelper = DatabaseHelper();
  int totalCustomers = 0;
  int totalProducts = 0;
  int totalInvoices = 0;
  double totalRevenue = 0.0;
  double totalOutstanding = 0.0;
  List<Invoice> recentInvoices = [];
  List<Invoice> dueSoonInvoices = [];
  List<Product> outOfStockProducts = [];
  List<Invoice> overdueInvoices = [];
  String _currencySymbol = '₹';
  String _currencyCode = 'INR';
  // ── Ledgerly overview (all read-only aggregations over existing queries) ──
  /// Full overdue list for ageing/focus panels (ReminderService batch query).
  List<OverdueInvoice> _reminderOverdue = [];

  /// Monthly P&L for the last 5 full months + current month-to-date.
  List<PnlSummary> _pnlSeries = [];

  /// Previous-month same-day window P&L, for an honest MoM profit delta.
  PnlSummary? _pnlPrevWindow;

  /// Dated cash events for the cash-flow panel (ReportService day book).
  List<DayBookEntry> _dayBook = [];

  /// Active cash/bank accounts in the selected currency + live balances.
  List<FinancialAccount> _cashAccounts = [];
  Map<String, double> _cashBalances = {};

  /// Month-end cash totals (5 month-ends + now) for the cash sparkline/delta.
  List<double> _cashSeries = [];
  double _cashPrevMonthEnd = 0;
  List<Product> _allProducts = [];

  /// Current-month sales invoices, for the honest GSTR-1 status block.
  List<Invoice> _periodInvoices = [];

  /// Current-month purchase bills, for the honest ITC comparison block.
  List<PurchaseBill> _periodBills = [];
  bool isLoading = true;
  String _dashboardLayout = 'default';
  bool _showLayoutBanner = false;
  bool _showThemeBanner = false;
  bool _showShortcutsBanner = false;
  bool _showSupportBanner = false;
  String _supportMilestone = '';
  List<Map<String, dynamic>> _monthlyRevenue = [];
  List<Map<String, dynamic>> _topCustomers = [];
  List<Map<String, dynamic>> _topProducts = [];

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    if (!mounted) return;
    setState(() => isLoading = true);

    // Dashboard renders under a single currency symbol — fetch it first so
    // revenue/outstanding/monthly/top-customers are filtered to it (mixed
    // currencies must never be summed under one symbol).
    final currency = await ref.read(settingsRepositoryProvider).getCurrency();
    if (!mounted) return;
    final results = await Future.wait([
      ref.read(customerRepositoryProvider).getTotalCustomerCount(), // 0
      ref.read(productRepositoryProvider).getTotalProductCount(), // 1
      ref
          .read(invoiceRepositoryProvider)
          .getDashboardFinancials(currencyCode: currency.code), // 2
      ref.read(invoiceRepositoryProvider).getRecentInvoices(limit: 5), // 3
      ref.read(invoiceRepositoryProvider).getDueSoonInvoices(), // 4
      ref.read(invoiceRepositoryProvider).getOverdueInvoices(limit: 10), // 5
      ref
          .read(invoiceRepositoryProvider)
          .getMonthlyRevenue(currencyCode: currency.code), // 6
      ref
          .read(settingsRepositoryProvider)
          .getSetting(SettingKey.dashboardLayout), // 7
      ref
          .read(invoiceRepositoryProvider)
          .getTopCustomers(currencyCode: currency.code), // 8
      ref.read(invoiceRepositoryProvider).getTopProducts(), // 9
      ref
          .read(settingsRepositoryProvider)
          .getSetting(SettingKey.layoutBannerDismissed), // 10
      ref
          .read(settingsRepositoryProvider)
          .getSetting(SettingKey.supportBannerDismissed), // 11
      ref.read(productRepositoryProvider).getOutOfStockProducts(), // 12
      ref
          .read(settingsRepositoryProvider)
          .getSetting(SettingKey.themeBannerDismissed), // 13
      ref
          .read(settingsRepositoryProvider)
          .getSetting(SettingKey.shortcutsBannerDismissed), // 14
    ]);

    // ── Ledgerly overview batch: read-only and additive. Every figure below
    // comes from an existing query; the screen only groups/filters the
    // returned rows (ageing buckets, monthly money-in/out, stock value).
    // A failure here must never blank the core dashboard, so the panels
    // fall back to honest empty states.
    final code = currency.code;
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final prevMonthStart = DateTime(now.year, now.month - 1, 1);
    final daysInPrevMonth =
        DateTime(prevMonthStart.year, prevMonthStart.month + 1, 0).day;
    final prevWindowEnd = DateTime(prevMonthStart.year, prevMonthStart.month,
        now.day > daysInPrevMonth ? daysInPrevMonth : now.day, 23, 59, 59);
    final sixMonthStart = DateTime(now.year, now.month - 5, 1);
    final seriesStarts =
        List.generate(6, (i) => DateTime(now.year, now.month - (5 - i), 1));
    DateTime monthEnd(DateTime m) =>
        DateTime(m.year, m.month + 1, 0, 23, 59, 59);

    var reminderOverdue = <OverdueInvoice>[];
    var dayBook = <DayBookEntry>[];
    var cashAccounts = <FinancialAccount>[];
    var cashBalances = <String, double>{};
    var cashSeries = <double>[];
    var cashPrevMonthEnd = 0.0;
    var allProducts = <Product>[];
    var periodInvoices = <Invoice>[];
    var periodBills = <PurchaseBill>[];
    var pnlSeries = <PnlSummary>[];
    PnlSummary? pnlPrevWindow;
    try {
      final extra = await Future.wait([
        ReminderService.getOverdue(limit: 200), // 0
        ReportService.getDayBook(sixMonthStart, now, currencyCode: code), // 1
        AccountingService.getAccounts(), // 2
        ref.read(productRepositoryProvider).getAllProducts(), // 3
        ref.read(invoiceRepositoryProvider).getInvoicesForExport(
            fromDate: monthStart, toDate: now, filterType: 'Invoice'), // 4
        PurchaseBillService.getBills(from: monthStart, to: now), // 5
        for (var i = 0; i < seriesStarts.length; i++)
          ReportService.getPnl(
            seriesStarts[i],
            i == seriesStarts.length - 1 ? now : monthEnd(seriesStarts[i]),
            currencyCode: code,
          ), // 6..11
        ReportService.getPnl(prevMonthStart, prevWindowEnd,
            currencyCode: code), // 12
      ]);
      reminderOverdue = extra[0] as List<OverdueInvoice>;
      dayBook = extra[1] as List<DayBookEntry>;
      final accounts = extra[2] as List<FinancialAccount>;
      // Currency scope: never sum mixed currencies under one symbol.
      cashAccounts = accounts.where((a) => a.currencyCode == code).toList();
      allProducts = extra[3] as List<Product>;
      periodInvoices = extra[4] as List<Invoice>;
      periodBills = extra[5] as List<PurchaseBill>;
      pnlSeries = extra.sublist(6, 12).cast<PnlSummary>();
      pnlPrevWindow = extra[12] as PnlSummary;
      // Live balances plus real historical balances (AccountingService
      // supports `through`, so month-end points are actuals, not estimates).
      cashBalances = await AccountingService.getBalances(cashAccounts);
      final seriesDates = [
        for (var i = 0; i < 5; i++)
          DateTime(now.year, now.month - (4 - i), 0, 23, 59, 59),
        now,
      ];
      final balanceFutures = <Future<double>>[];
      for (var d = 0; d < seriesDates.length; d++) {
        final date = seriesDates[d];
        final historical = d < seriesDates.length - 1;
        balanceFutures.add(() async {
          var total = 0.0;
          for (final account in cashAccounts) {
            total += await AccountingService.getBalance(account.id,
                through: historical ? date : null);
          }
          return total;
        }());
      }
      cashSeries = await Future.wait(balanceFutures);
      cashPrevMonthEnd =
          cashSeries.length >= 2 ? cashSeries[cashSeries.length - 2] : 0.0;
    } catch (_) {
      // Panels keep their honest empty defaults (see initializers above).
    }

    final customerCount = results[0] as int;
    final productCount = results[1] as int;
    final financials =
        results[2] as ({int count, double revenue, double outstanding});
    final recent = results[3] as List<Invoice>;
    final dueSoon = results[4] as List<Invoice>;
    final overdue = results[5] as List<Invoice>;
    final monthly = results[6] as List<Map<String, dynamic>>;
    final layout = results[7] as String?;
    final topCust = results[8] as List<Map<String, dynamic>>;
    final topProd = results[9] as List<Map<String, dynamic>>;
    final bannerDismissed = results[10] as String?;
    final supportDismissed = results[11] as String?;
    final outOfStock = results[12] as List<Product>;
    final themeBannerDismissed = results[13] as String?;
    final shortcutsBannerDismissed =
        Platform.isAndroid ? '1' : results[14] as String?;
    final String milestone = financials.count >= 100
        ? '100'
        : financials.count >= 50
            ? '50'
            : financials.count > 10
                ? '10'
                : '';
    if (!mounted) return;
    setState(() {
      totalCustomers = customerCount;
      totalProducts = productCount;
      outOfStockProducts = outOfStock;
      totalInvoices = financials.count;
      totalRevenue = financials.revenue;
      totalOutstanding = financials.outstanding;
      recentInvoices = recent;
      dueSoonInvoices = dueSoon;
      overdueInvoices = overdue;
      _currencySymbol = currency.symbol;
      _currencyCode = code;
      _reminderOverdue = reminderOverdue;
      _dayBook = dayBook;
      _cashAccounts = cashAccounts;
      _cashBalances = cashBalances;
      _cashSeries = cashSeries;
      _cashPrevMonthEnd = cashPrevMonthEnd;
      _allProducts = allProducts;
      _periodInvoices = periodInvoices;
      _periodBills = periodBills;
      _pnlSeries = pnlSeries;
      _pnlPrevWindow = pnlPrevWindow;
      _monthlyRevenue = monthly;
      _dashboardLayout = layout ?? 'default';
      _topCustomers = topCust;
      _topProducts = topProd;
      _showLayoutBanner = bannerDismissed != '1';
      _showThemeBanner = themeBannerDismissed != '1';
      _showShortcutsBanner = shortcutsBannerDismissed != '1';
      _supportMilestone = milestone;
      _showSupportBanner =
          milestone.isNotEmpty && supportDismissed != milestone;
      isLoading = false;
    });
  }

  Future<void> _dismissSupportBanner() async {
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.supportBannerDismissed, _supportMilestone);
    if (mounted) setState(() => _showSupportBanner = false);
  }

  Future<void> _dismissLayoutBanner() async {
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.layoutBannerDismissed, '1');
    if (mounted) setState(() => _showLayoutBanner = false);
  }

  Future<void> _dismissThemeBanner() async {
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.themeBannerDismissed, '1');
    if (mounted) setState(() => _showThemeBanner = false);
  }

  Future<void> _dismissShortcutsBanner() async {
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.shortcutsBannerDismissed, '1');
    if (mounted) setState(() => _showShortcutsBanner = false);
  }

  void _showShortcutsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.keyboard_outlined),
            const SizedBox(width: 12),
            Text(AppLocalizations.of(context)!.dashboardKeyboardShortcutsTitle),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: AppShortcuts.all(context)
                .map((s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                            ),
                            child: Text(s.$1,
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(s.$2,
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.actionClose),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutsDiscoveryBanner() {
    return DiscoveryBanner(
      visible: _showShortcutsBanner,
      icon: Icons.keyboard_outlined,
      iconColor: const Color(0xFF059669),
      backgroundColor: const Color(0xFFECFDF5),
      borderColor: const Color(0xFFA7F3D0),
      title: Text(
        AppLocalizations.of(context)!.dashboardShortcutsBannerTitle,
        style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF065F46)),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.dashboardShortcutsBannerSubtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFF059669)),
      ),
      actionLabel: AppLocalizations.of(context)!.dashboardViewAllAction,
      onAction: _showShortcutsDialog,
      actionColor: const Color(0xFF059669),
      onDismiss: _dismissShortcutsBanner,
      dismissIconColor: const Color(0xFF6EE7B7),
    );
  }

  Widget _buildLayoutDiscoveryBanner() {
    return DiscoveryBanner(
      visible: _showLayoutBanner,
      icon: Icons.dashboard_customize_outlined,
      iconColor: const Color(0xFF2563EB),
      backgroundColor: const Color(0xFFEFF6FF),
      borderColor: const Color(0xFFBFDBFE),
      title: Text(
        AppLocalizations.of(context)!.dashboardLayoutBannerTitle,
        style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF1E40AF)),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.dashboardLayoutBannerSubtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFF3B82F6)),
      ),
      actionLabel: AppLocalizations.of(context)!.actionGotIt,
      onAction: _dismissLayoutBanner,
      actionColor: const Color(0xFF2563EB),
      onDismiss: _dismissLayoutBanner,
      dismissIconColor: const Color(0xFF93C5FD),
    );
  }

  Widget _buildThemeDiscoveryBanner() {
    return DiscoveryBanner(
      visible: _showThemeBanner,
      icon: Icons.dark_mode_outlined,
      iconColor: const Color(0xFF7C3AED),
      backgroundColor: const Color(0xFFF5F3FF),
      borderColor: const Color(0xFFDDD6FE),
      title: Row(
        children: [
          Text(
            AppLocalizations.of(context)!.dashboardThemeBannerTitle,
            style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: Color(0xFF5B21B6)),
          ),
          const SizedBox(width: 6),
          const _BetaTag(),
        ],
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.dashboardThemeBannerSubtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFF7C3AED)),
      ),
      actionLabel: AppLocalizations.of(context)!.actionGotIt,
      onAction: _dismissThemeBanner,
      actionColor: const Color(0xFF7C3AED),
      onDismiss: _dismissThemeBanner,
      dismissIconColor: const Color(0xFFC4B5FD),
    );
  }

  Widget _buildSupportBanner() {
    final bool isReviewMilestone = _supportMilestone == '10';
    return DiscoveryBanner(
      visible: _showSupportBanner,
      margin: const EdgeInsets.only(bottom: 16),
      crossAxisAlignment: CrossAxisAlignment.start,
      icon: isReviewMilestone ? Icons.star_outline : Icons.celebration_outlined,
      iconSize: 22,
      iconColor: const Color(0xFFD97706),
      backgroundColor: const Color(0xFFFFFBEB),
      borderColor: const Color(0xFFFDE68A),
      title: Text(
        AppLocalizations.of(context)!
            .dashboardSupportBannerTitle(_supportMilestone),
        style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF92400E)),
      ),
      subtitle: Text(
        isReviewMilestone
            ? AppLocalizations.of(context)!.dashboardSupportBannerReviewSubtitle
            : AppLocalizations.of(context)!
                .dashboardSupportBannerSupportSubtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFFB45309)),
      ),
      actionLabel: isReviewMilestone
          ? AppLocalizations.of(context)!.dashboardReviewAction
          : AppLocalizations.of(context)!.dashboardSupportAction,
      onAction: () async {
        final uri = Uri.parse(isReviewMilestone
            ? '${AppConfig.website}/review'
            : '${AppConfig.website}/support');
        if (await canLaunchUrl(uri)) await launchUrl(uri);
      },
      actionColor: const Color(0xFF92400E),
      actionBackgroundColor: const Color(0xFFFDE68A),
      onDismiss: _dismissSupportBanner,
      dismissIconColor: const Color(0xFFD97706),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? null
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.dashboardOverviewTitle),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor ??
            Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        actions: [
          _buildLayoutToggle(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDashboardData,
            tooltip: AppLocalizations.of(context)!.actionRefresh,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: isLoading ? const AppLoadingState() : _buildContent(),
    );
  }

  Widget _buildContent() {
    switch (_dashboardLayout) {
      case 'classic':
        return _buildClassicLayout();
      case 'simple':
        return _buildSimpleFeedLayout();
      case 'bento':
        return _buildBentoLayout();
      default:
        return _buildDefaultLayout();
    }
  }

  Widget _buildDefaultLayout() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(context.isCompact ? 16 : 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.maxWidthNormal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLayoutDiscoveryBanner(),
              _buildThemeDiscoveryBanner(),
              _buildShortcutsDiscoveryBanner(),
              _buildSupportBanner(),
              // ── Ledgerly overview ──────────────────────────────
              _buildLedgerlyGreeting(),

              const SizedBox(height: 20),

              _buildLedgerlyKpis(),

              const SizedBox(height: 20),

              _buildLedgerlyPanels(),

              const SizedBox(height: 20),

              _buildLedgerlyQuickActions(),

              // ── Due Soon ─────────────────────────────────────
              if (dueSoonInvoices.isNotEmpty) ...[
                const SizedBox(height: 36),
                _buildDueSoonSection(),
              ],

              // ── Out of Stock ──────────────────────────────────
              if (outOfStockProducts.isNotEmpty) ...[
                const SizedBox(height: 36),
                _buildOutOfStockSection(),
              ],

              // ── Overdue Invoices ──────────────────────────────
              if (overdueInvoices.isNotEmpty) ...[
                const SizedBox(height: 36),
                _buildOverdueSection(),
              ],

              const SizedBox(height: 36),

              // ── Recent Invoices Header ────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 4,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context)!.dashboardRecentInvoicesTitle,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3),
                  ),
                  const Spacer(),
                  Text(
                    AppLocalizations.of(context)!
                        .dashboardLastFiveInvoicesLabel,
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              recentInvoices.isEmpty
                  ? AppEmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: AppLocalizations.of(context)!
                          .dashboardNoInvoicesYetTitle,
                      subtitle: AppLocalizations.of(context)!
                          .dashboardNoInvoicesYetSubtitle,
                      action: AppPrimaryButton(
                        onPressed: widget.onCreateInvoice,
                        label:
                            Text(AppLocalizations.of(context)!.navNewInvoice),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: recentInvoices.length,
                      itemBuilder: (context, index) {
                        final invoice = recentInvoices[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: AppCard(
                            child: LayoutBuilder(
                              builder: (context, rowConstraints) {
                                final badge =
                                    _recentInvoiceBadge(invoice, index);
                                if (rowConstraints.maxWidth <
                                    Breakpoints.compactMax) {
                                  return _compactRecentInvoiceCard(
                                      invoice, index, badge);
                                }
                                return Row(
                                  children: [
                                    badge,
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: _recentInvoiceDetails(invoice),
                                    ),
                                    const SizedBox(width: 16),
                                    Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.purple
                                                .withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '${invoice.currencySymbol} ${invoice.payableTotal.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.purple,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          alignment: WrapAlignment.end,
                                          children: [
                                            _buildActionButton(
                                                Icons.visibility_outlined,
                                                Colors.green,
                                                AppLocalizations.of(context)!
                                                    .actionView,
                                                () => InvoicePdfServices
                                                    .showInvoiceDetails(
                                                        context, invoice)),
                                            _buildActionButton(
                                                Icons.edit_outlined,
                                                Colors.blue,
                                                AppLocalizations.of(context)!
                                                    .actionEdit,
                                                () => widget
                                                    .onEditInvoice(invoice)),
                                            _buildActionButton(
                                                Icons.copy_all_outlined,
                                                Colors.teal,
                                                AppLocalizations.of(context)!
                                                    .actionDuplicate,
                                                () =>
                                                    _showCloneDialog(invoice)),
                                            _buildActionButton(
                                                Icons.picture_as_pdf_outlined,
                                                Colors.orange,
                                                AppLocalizations.of(context)!
                                                    .actionPdfPreview,
                                                () => InvoicePdfServices
                                                    .previewPDF(
                                                        context, invoice)),
                                            _buildActionButton(
                                                Icons.download_outlined,
                                                Colors.deepPurple,
                                                AppLocalizations.of(context)!
                                                    .actionDownloadPdf,
                                                () => PDFService.downloadPDF(
                                                    context, invoice)),
                                            _buildActionButton(
                                                Icons.print_outlined,
                                                Colors.blueGrey,
                                                AppLocalizations.of(context)!
                                                    .actionPrint,
                                                () => InvoicePdfServices
                                                    .generatePDF(
                                                        context, invoice)),
                                            _buildActionButton(
                                                Icons.payments_outlined,
                                                Colors.purple,
                                                AppLocalizations.of(context)!
                                                    .actionPayment,
                                                invoice.type == 'Invoice'
                                                    ? () => showDialog(
                                                          context: context,
                                                          barrierDismissible:
                                                              false,
                                                          builder: (_) =>
                                                              ApplyPaymentDialog(
                                                            invoice: invoice,
                                                            onPaymentRecorded:
                                                                () {
                                                              if (!mounted)
                                                                return;
                                                              setState(() {});
                                                            },
                                                          ),
                                                        )
                                                    : null),
                                            _buildActionButton(
                                                Icons.delete_outline,
                                                Colors.red,
                                                AppLocalizations.of(context)!
                                                    .actionDelete,
                                                widget.user.isAdmin()
                                                    ? () => _showDeleteDialog(
                                                        invoice)
                                                    : null),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ],
          ),
        ),
      ),
    );
  }

  /// Numbered badge for a recent-invoice row — overdue-tinted when the
  /// invoice has a past due date.
  Widget _recentInvoiceBadge(Invoice invoice, int index) {
    final isOverdue = invoice.dueDate != null &&
        InvoiceCalculator.isOverdue(
          dueDate: invoice.dueDate,
          outstanding: invoice.outstandingBalance,
        );
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: isOverdue
            ? DashboardScreenColors.invoiceNumberOverDueLinearGradient
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).primaryColor,
                  Theme.of(context).primaryColor.withValues(alpha: 0.7),
                ],
              ),
        borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
      ),
      child: Center(
        child: Text(
          '${index + 1}',
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  /// Title / chips / customer-and-date meta shared by the compact card and
  /// the desktop row of the Recent Invoices list.
  Widget _recentInvoiceDetails(Invoice invoice) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${invoice.type} #${invoice.invoiceNumber ?? invoice.id}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: invoice.type == 'Invoice'
                    ? Colors.indigo.withValues(alpha: 0.1)
                    : Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: invoice.type == 'Invoice'
                      ? Colors.indigo.withValues(alpha: 0.35)
                      : Colors.orange.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                _invoiceTypeLabel(context, invoice.type),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: invoice.type == 'Invoice'
                      ? Colors.indigo[700]
                      : Colors.orange[800],
                  letterSpacing: 0.5,
                ),
              ),
            ),
            if (invoice.type == 'Invoice')
              _buildPaymentStatusChip(invoice.paymentStatus),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(
                    child: Text(
                  invoice.customer.name.limit(15),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface),
                )),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Flexible(
                    child: Text(
                  invoice.date.toString().split(' ')[0],
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(context).colorScheme.onSurface),
                )),
              ],
            ),
            if (invoice.dueDate != null)
              () {
                final isOverdue = InvoiceCalculator.isOverdue(
                  dueDate: invoice.dueDate,
                  outstanding: invoice.outstandingBalance,
                );
                final color = isOverdue
                    ? Colors.red[700]!
                    : Theme.of(context).colorScheme.onSurfaceVariant;
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.event_outlined, size: 16, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          AppLocalizations.of(context)!.dashboardDueDateLabel(
                              AppFormatters.formatShortDate(invoice.dueDate)),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight:
                                isOverdue ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }(),
          ],
        ),
      ],
    );
  }

  /// Compact-phone recent-invoice card: badge + details + amount on the top
  /// row, primary actions and an overflow menu below — the desktop row's
  /// trailing 8-button block cannot survive 320-430px.
  Widget _compactRecentInvoiceCard(Invoice invoice, int index, Widget badge) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(width: 12),
            Expanded(child: _recentInvoiceDetails(invoice)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${invoice.currencySymbol} ${invoice.payableTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.purple,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildActionButton(
                Icons.visibility_outlined,
                Colors.green,
                l10n.actionView,
                () => InvoicePdfServices.showInvoiceDetails(context, invoice)),
            const SizedBox(width: 6),
            _buildActionButton(Icons.edit_outlined, Colors.blue,
                l10n.actionEdit, () => widget.onEditInvoice(invoice)),
            const SizedBox(width: 6),
            _buildActionButton(Icons.copy_all_outlined, Colors.teal,
                l10n.actionDuplicate, () => _showCloneDialog(invoice)),
            const Spacer(),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: l10n.invoiceMgmtMoreActionsTooltip,
              onSelected: (action) {
                switch (action) {
                  case 'pdf':
                    InvoicePdfServices.previewPDF(context, invoice);
                  case 'download':
                    PDFService.downloadPDF(context, invoice);
                  case 'print':
                    InvoicePdfServices.generatePDF(context, invoice);
                  case 'payment':
                    if (invoice.type == 'Invoice') {
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => ApplyPaymentDialog(
                          invoice: invoice,
                          onPaymentRecorded: () {
                            if (!mounted) return;
                            setState(() {});
                          },
                        ),
                      );
                    }
                  case 'delete':
                    if (widget.user.isAdmin()) _showDeleteDialog(invoice);
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                    value: 'pdf',
                    child: Row(children: [
                      const Icon(Icons.picture_as_pdf_outlined,
                          size: 18, color: Colors.orange),
                      const SizedBox(width: 10),
                      Text(l10n.actionPdfPreview),
                    ])),
                PopupMenuItem(
                    value: 'download',
                    child: Row(children: [
                      const Icon(Icons.download_outlined,
                          size: 18, color: Colors.deepPurple),
                      const SizedBox(width: 10),
                      Text(l10n.actionDownloadPdf),
                    ])),
                PopupMenuItem(
                    value: 'print',
                    child: Row(children: [
                      const Icon(Icons.print_outlined,
                          size: 18, color: Colors.blueGrey),
                      const SizedBox(width: 10),
                      Text(l10n.actionPrint),
                    ])),
                if (invoice.type == 'Invoice')
                  PopupMenuItem(
                      value: 'payment',
                      child: Row(children: [
                        const Icon(Icons.payments_outlined,
                            size: 18, color: Colors.purple),
                        const SizedBox(width: 10),
                        Text(l10n.actionPayment),
                      ])),
                if (widget.user.isAdmin())
                  PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline,
                            size: 18,
                            color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 10),
                        Text(l10n.actionDelete,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ])),
              ],
            ),
          ],
        ),
      ],
    );
  }

  // ── Ledgerly overview ─────────────────────────────────────────────────────
  // Presentation-only redesign of the default overview tab. Every number
  // below comes from the queries loaded in _loadDashboardData; this section
  // only formats, filters by the selected currency, and groups returned rows
  // (ageing buckets, monthly money-in/out, stock value). No calculation,
  // query predicate, persistence, sync, or accounting logic lives here.

  /// Month-over-month % change. Null when the previous value is ~zero, so
  /// the card omits the chip instead of showing a misleading figure.
  double? _momPct(double current, double previous) {
    if (previous.abs() < 0.005) return null;
    return (current - previous) / previous.abs() * 100;
  }

  Widget? _deltaChip(double? pct) {
    if (pct == null || !pct.isFinite) return null;
    final up = pct >= 0;
    final color = up ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 12, color: color),
          const SizedBox(width: 2),
          Text('${pct.abs().toStringAsFixed(1)}%',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _buildSparkline(List<double> values, Color color) {
    final maxV = values.fold(0.0, (a, b) => b > a ? b : a);
    final minV = values.fold(0.0, (a, b) => b < a ? b : a);
    return SizedBox(
      height: 44,
      child: LineChart(
        LineChartData(
          minY: minV < 0 ? minV * 1.2 : 0,
          maxY: maxV > 0 ? maxV * 1.2 : 1,
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < values.length; i++)
                  FlSpot(i.toDouble(), values[i]),
              ],
              isCurved: true,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData:
                  BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
            ),
          ],
          titlesData: const FlTitlesData(show: false),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
        ),
      ),
    );
  }

  Widget _ledgerlyKpi({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    Widget? titleChip,
    double? deltaPct,
    List<double>? sparkline,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final chip = _deltaChip(deltaPct);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (titleChip != null) titleChip,
              if (chip != null) ...[
                const SizedBox(width: 6),
                chip,
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(value,
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(subtitle,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          if (sparkline != null && sparkline.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildSparkline(sparkline, color),
          ],
          if (action != null) ...[
            const SizedBox(height: 10),
            action,
          ],
        ],
      ),
    );
  }

  Widget _overdueTitleChip(int count) {
    final color = count > 0 ? const Color(0xFFC62828) : const Color(0xFF2E7D32);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20)),
      child: Text(count > 0 ? '$count overdue' : 'All clear',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  /// Four KPI cards. Sales headlines are all-time collected/count/average
  /// from getDashboardFinancials (one consistent source); the delta chip and
  /// sparkline show the monthly-receipts trend. Net Profit is the P&L profit
  /// for the current month (ReportService.getPnl, same engine as the
  /// Reports P&L tab) with margin, MoM delta, and a 6-month P&L sparkline.
  Widget _buildLedgerlyKpis() {
    final months = _lastSixMonths();
    final keys = months.map(_monthKey).toList();
    final receipts = [for (final k in keys) _receiptsByMonth[k] ?? 0.0];
    final salesDelta = _momPct(
        _receiptsByMonth[keys.last] ?? 0, _receiptsByMonth[keys[4]] ?? 0);
    final avgBill = totalInvoices > 0 ? totalRevenue / totalInvoices : 0.0;

    const emptyPnl =
        PnlSummary(revenue: 0, expenses: 0, purchases: 0, collected: 0);
    final cur = _pnlSeries.length == 6 ? _pnlSeries.last : emptyPnl;
    final profits = _pnlSeries.length == 6
        ? [for (final p in _pnlSeries) p.profit]
        : List.filled(6, 0.0);
    final profitDelta = _pnlPrevWindow == null
        ? null
        : _momPct(cur.profit, _pnlPrevWindow!.profit);
    final margin =
        cur.revenue.abs() > 0.005 ? cur.profit / cur.revenue * 100 : null;

    var inCash = 0.0;
    var inBank = 0.0;
    for (final a in _cashAccounts) {
      final b = _cashBalances[a.id] ?? 0;
      if (a.type == 'cash') {
        inCash += b;
      } else {
        inBank += b;
      }
    }
    final cashNow = inCash + inBank;
    final cashDelta = _momPct(cashNow, _cashPrevMonthEnd);
    final List<double>? cashSpark =
        _cashSeries.length == 6 ? _cashSeries : null;

    final overdueCount = _scopedOverdue.length;
    final salesCard = _ledgerlyKpi(
      title: 'Sales',
      value: _inrCompact(totalRevenue),
      subtitle: totalInvoices > 0
          ? '$totalInvoices invoices · avg ${_inrCompact(avgBill)}'
          : 'No invoices yet',
      icon: Icons.trending_up_outlined,
      color: const Color(0xFF6A1B9A),
      deltaPct: salesDelta,
      sparkline: receipts,
    );
    final profitCard = _ledgerlyKpi(
      title: 'Net Profit',
      value: _inrCompact(cur.profit),
      subtitle: margin == null
          ? 'This month · margin —'
          : 'This month · margin ${margin.toStringAsFixed(1)}%',
      icon: Icons.savings_outlined,
      color: const Color(0xFF2E7D32),
      deltaPct: profitDelta,
      sparkline: profits,
    );
    final outstandingCard = _ledgerlyKpi(
      title: 'Outstanding',
      value: _inrCompact(totalOutstanding),
      subtitle: totalOutstanding.abs() < 0.005
          ? 'Nothing outstanding'
          : overdueCount > 0
              ? 'From $_scopedOverdueCustomerCount customers'
              : 'Nothing overdue',
      icon: Icons.hourglass_top_outlined,
      color: const Color(0xFFC62828),
      titleChip: _overdueTitleChip(overdueCount),
      action: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => widget.onNavigateTab(17),
          icon: const Icon(Icons.send_outlined, size: 16),
          label: const Text('Send reminder'),
        ),
      ),
    );
    final cashCard = _ledgerlyKpi(
      title: 'Cash & Bank',
      value: _inrCompact(cashNow),
      subtitle: _cashAccounts.isEmpty
          ? 'No accounts in $_currencyCode'
          : 'Cash ${_inrCompact(inCash)} · Bank ${_inrCompact(inBank)}',
      icon: Icons.account_balance_wallet_outlined,
      color: const Color(0xFF1565C0),
      deltaPct: cashDelta,
      sparkline: cashSpark,
    );

    return LayoutBuilder(
      builder: (context, c) {
        final cards = [salesCard, profitCard, outstandingCard, cashCard];
        if (c.maxWidth < Breakpoints.compactMax) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                cards[i],
              ],
            ],
          );
        }
        if (c.maxWidth < 1100) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 12),
                Expanded(child: cards[1]),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: cards[2]),
                const SizedBox(width: 12),
                Expanded(child: cards[3]),
              ]),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: cards[i]),
            ],
          ],
        );
      },
    );
  }

  /// 6-month grouped bars: money-in (invoice receipts) vs money-out
  /// (expenses + purchase-bill payments), grouped in-screen from the
  /// currency-scoped day-book rows. Zero months are honest zeroes.
  Widget _buildCashFlowPanel() {
    final scheme = Theme.of(context).colorScheme;
    final months = _lastSixMonths();
    final inByMonth = <String, double>{};
    final outByMonth = <String, double>{};
    for (final e in _dayBook) {
      final key = _monthKey(e.date);
      inByMonth[key] = (inByMonth[key] ?? 0) + e.moneyIn;
      outByMonth[key] = (outByMonth[key] ?? 0) + e.moneyOut;
    }
    final ins = [for (final m in months) inByMonth[_monthKey(m)] ?? 0.0];
    final outs = [for (final m in months) outByMonth[_monthKey(m)] ?? 0.0];
    final hasData =
        ins.any((v) => v.abs() > 0.005) || outs.any((v) => v.abs() > 0.005);
    const inColor = Color(0xFF2E7D32);
    const outColor = Color(0xFFE65100);

    final Widget chart;
    if (!hasData) {
      chart = Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Text('No cash movement in the last 6 months.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
      );
    } else {
      final maxV = [...ins, ...outs].fold<double>(0, (a, b) => b > a ? b : a);
      chart = SizedBox(
        height: 210,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            groupsSpace: 14,
            maxY: maxV * 1.25,
            barGroups: [
              for (var i = 0; i < 6; i++)
                BarChartGroupData(
                  x: i,
                  barsSpace: 4,
                  barRods: [
                    BarChartRodData(
                      toY: ins[i],
                      width: 10,
                      color: inColor,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                    BarChartRodData(
                      toY: outs[i],
                      width: 10,
                      color: outColor,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(4)),
                    ),
                  ],
                ),
            ],
            titlesData: FlTitlesData(
              leftTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (value, meta) {
                    final idx = value.toInt();
                    if (idx < 0 || idx >= months.length) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(DateFormat('MMM').format(months[idx]),
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    );
                  },
                ),
              ),
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.grey.withValues(alpha: 0.12), strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  final label = rodIndex == 0 ? 'In' : 'Out';
                  return BarTooltipItem(
                    '$label ${_inrCompact(rod.toY)}',
                    const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  );
                },
              ),
            ),
          ),
        ),
      );
    }
    return _ledgerlyPanel(
      title: 'Cash Flow',
      subtitle: 'Last 6 months',
      icon: Icons.waterfall_chart_outlined,
      color: const Color(0xFF0288D1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _legendDot(inColor, 'Money in (receipts)'),
              _legendDot(outColor, 'Money out (payments & expenses)'),
            ],
          ),
          const SizedBox(height: 12),
          chart,
        ],
      ),
    );
  }

  Widget _focusRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        TextButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }

  /// Next GSTR-3B due date from the calendar (20th; monthly filers).
  /// Honestly calendar-based — quarterly filers follow a different schedule.
  DateTime _nextGstr3bDue() {
    final now = DateTime.now();
    if (now.day <= 20) return DateTime(now.year, now.month, 20);
    return DateTime(now.year, now.month + 1, 20);
  }

  Widget _buildFocusPanel() {
    final overdueCount = _scopedOverdue.length;
    final lowStockCount = _restockCount;
    final due = _nextGstr3bDue();
    return _ledgerlyPanel(
      title: "Today's Focus",
      subtitle: DateFormat('EEEE, MMM d').format(DateTime.now()),
      icon: Icons.center_focus_strong_outlined,
      color: const Color(0xFF7C3AED),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _focusRow(
            icon: Icons.warning_amber_rounded,
            color: const Color(0xFFC62828),
            title: 'Overdue invoices',
            subtitle: overdueCount == 0
                ? 'All clear — nothing overdue'
                : '$overdueCount invoices · ${_inrCompact(_scopedOverdueTotal)} to collect',
            actionLabel: 'View & Remind',
            onAction: () => widget.onNavigateTab(17),
          ),
          const Divider(height: 20),
          _focusRow(
            icon: Icons.inventory_2_outlined,
            color: const Color(0xFFE65100),
            title: 'Low stock',
            subtitle: lowStockCount == 0
                ? 'Stock levels healthy'
                : '$lowStockCount items need restocking',
            actionLabel: 'View Items',
            onAction: () => widget.onNavigateTab(6),
          ),
          const Divider(height: 20),
          _focusRow(
            icon: Icons.receipt_long_outlined,
            color: const Color(0xFF00897B),
            title: 'GSTR-3B due ${DateFormat('d MMM yyyy').format(due)}',
            subtitle: 'Calendar-based · monthly filer',
            actionLabel: 'File Now',
            onAction: () => widget.onNavigateTab(7),
          ),
        ],
      ),
    );
  }

  /// Receivables buckets from the currency-scoped overdue rows.
  /// Current = total outstanding (same engine, all invoices) minus the
  /// overdue buckets — the not-yet-due residual.
  ({double current, double d30, double d60, double dOver}) _ageingBuckets() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var d30 = 0.0;
    var d60 = 0.0;
    var dOver = 0.0;
    for (final r in _scopedOverdue) {
      final due = r.dueDate;
      final days = due == null
          ? 0
          : today.difference(DateTime(due.year, due.month, due.day)).inDays;
      if (days <= 30) {
        d30 += r.outstanding;
      } else if (days <= 60) {
        d60 += r.outstanding;
      } else {
        dOver += r.outstanding;
      }
    }
    final residual = totalOutstanding - (d30 + d60 + dOver);
    return (
      current: residual > 0 ? residual : 0.0,
      d30: d30,
      d60: d60,
      dOver: dOver,
    );
  }

  Widget _buildAgeingPanel() {
    final scheme = Theme.of(context).colorScheme;
    final b = _ageingBuckets();
    final total = b.current + b.d30 + b.d60 + b.dOver;
    if (total.abs() < 0.005) {
      return _ledgerlyPanel(
        title: 'Receivables Ageing',
        subtitle: 'By due date',
        icon: Icons.hourglass_bottom_outlined,
        color: const Color(0xFF5C6BC0),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text('No outstanding receivables.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ),
        ),
      );
    }
    final segments = <({String label, double value, Color color})>[
      (label: 'Current', value: b.current, color: const Color(0xFF2E7D32)),
      (label: '1–30 days', value: b.d30, color: const Color(0xFFF9A825)),
      (label: '31–60 days', value: b.d60, color: const Color(0xFFE65100)),
      (label: '60+ days', value: b.dOver, color: const Color(0xFFC62828)),
    ];
    return _ledgerlyPanel(
      title: 'Receivables Ageing',
      subtitle: 'Total ${_inrCompact(total)}',
      icon: Icons.hourglass_bottom_outlined,
      color: const Color(0xFF5C6BC0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  for (final s in segments)
                    if (s.value > 0.005)
                      Expanded(
                        flex: (s.value / total * 1000).round().clamp(1, 1000),
                        child: Container(color: s.color),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final s in segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: s.color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(s.label,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  Text(_inrCompact(s.value),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 48,
                    child: Text(
                        '${(s.value / total * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ),
                ],
              ),
            ),
          if (_reminderOverdue.length >= 200)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Overdue list capped at 200 rows — Current absorbs the rest.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  List<Invoice> get _scopedPeriodInvoices =>
      _periodInvoices.where((i) => i.currencyCode == _currencyCode).toList();

  List<PurchaseBill> get _scopedPeriodBills =>
      _periodBills.where((b) => b.currencyCode == _currencyCode).toList();

  Widget _gstStatusRow({
    required String title,
    required String detail,
    required String status,
    required Color statusColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20)),
              child: Text(status,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: statusColor)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(detail,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  /// Honest GST statuses from real period data only: current-month sales
  /// invoices (count + taxable + output tax) and ITC-eligible purchase-bill
  /// tax vs output tax with the gap amount. No computed-looking "matched %"
  /// is shown unless it is exactly this ratio.
  Widget _buildGstPanel() {
    final now = DateTime.now();
    final invoices = _scopedPeriodInvoices;
    final taxable = invoices.fold(0.0, (s, i) => s + (i.total - i.tax));
    final salesTax = invoices.fold(0.0, (s, i) => s + i.tax);
    final bills = _scopedPeriodBills;
    final itcTax =
        bills.where((b) => b.itcEligible).fold(0.0, (s, b) => s + b.totalTax);
    final matchPct = salesTax > 0.005 ? itcTax / salesTax * 100 : null;
    final gap = salesTax - itcTax;

    final String itcDetail;
    final String itcStatus;
    final Color itcColor;
    if (bills.isEmpty && salesTax.abs() < 0.005) {
      itcDetail = 'No purchase bills or sales tax this period';
      itcStatus = 'No data';
      itcColor = Colors.grey;
    } else if (bills.isEmpty) {
      itcDetail = 'No purchase bills — ITC ${_inrCompact(0)}';
      itcStatus = 'No bills';
      itcColor = const Color(0xFFE65100);
    } else if (matchPct == null) {
      itcDetail = 'ITC ${_inrCompact(itcTax)} · no output tax this period';
      itcStatus = 'No output tax';
      itcColor = Colors.grey;
    } else {
      itcDetail =
          'ITC ${_inrCompact(itcTax)} vs output ${_inrCompact(salesTax)} · '
          '${matchPct.toStringAsFixed(1)}% · gap ${_inrCompact(gap)}';
      if (gap.abs() < 0.005) {
        itcStatus = 'Fully matched';
        itcColor = const Color(0xFF2E7D32);
      } else {
        itcStatus = 'Check gap';
        itcColor = const Color(0xFFE65100);
      }
    }

    return _ledgerlyPanel(
      title: 'GST Health',
      subtitle: DateFormat('MMMM yyyy').format(now),
      icon: Icons.verified_outlined,
      color: const Color(0xFF00897B),
      trailing: TextButton(
        onPressed: () => widget.onNavigateTab(7),
        child: const Text('GST reports'),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _gstStatusRow(
            title: 'GSTR-1 · sales',
            detail: invoices.isEmpty
                ? 'No sales invoices this period'
                : '${invoices.length} invoices · taxable ${_inrCompact(taxable)} · '
                    'tax ${_inrCompact(salesTax)}',
            status: invoices.isEmpty ? 'Nothing to file' : 'Ready to file',
            statusColor:
                invoices.isEmpty ? Colors.grey : const Color(0xFF2E7D32),
          ),
          const SizedBox(height: 12),
          _gstStatusRow(
            title: 'ITC vs output tax',
            detail: itcDetail,
            status: itcStatus,
            statusColor: itcColor,
          ),
        ],
      ),
    );
  }

  List<Product> get _saleableProducts => _allProducts
      .where((p) => p.type == 'product' && !p.unlimitedStock)
      .toList();

  /// Per-item reorder level when set, else the Items screen's existing
  /// low-stock convention (10 units).
  double _lowThreshold(Product p) => p.reorderLevel > 0 ? p.reorderLevel : 10;

  List<Product> get _outOfStockNow {
    final list = _saleableProducts
        .where((p) => p.stock.toDouble() <= 0)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  List<Product> get _lowStockNow {
    final list = _saleableProducts
        .where((p) =>
            p.stock.toDouble() > 0 && p.stock.toDouble() <= _lowThreshold(p))
        .toList()
      ..sort((a, b) => a.stock.compareTo(b.stock));
    return list;
  }

  int get _restockCount => _outOfStockNow.length + _lowStockNow.length;

  double get _stockValue =>
      _saleableProducts.fold(0.0, (s, p) => s + p.price * p.stock.toDouble());

  /// Total stock value from the loaded product rows (price × stock).
  /// A last-month delta is not computable from current rows, so it is
  /// omitted rather than estimated.
  Widget _buildInventoryPanel() {
    final scheme = Theme.of(context).colorScheme;
    final items = [..._outOfStockNow, ..._lowStockNow].take(5).toList();
    return _ledgerlyPanel(
      title: 'Inventory Pulse',
      subtitle: '${_saleableProducts.length} stocked items',
      icon: Icons.inventory_2_outlined,
      color: const Color(0xFF2E7D32),
      trailing: TextButton(
        onPressed: () => widget.onNavigateTab(6),
        child: const Text('View Items'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_inrCompact(_stockValue),
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface)),
          Text('Total stock value',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Text(
                _saleableProducts.isEmpty
                    ? 'No stocked items yet.'
                    : 'Nothing needs restocking.',
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant))
          else
            for (final p in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(p.name,
                          style: TextStyle(
                              fontSize: 12.5, color: scheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      p.stock.toDouble() <= 0
                          ? 'Out of stock · reorder at ${_fmtQty(p.reorderLevel)}'
                          : '${_fmtQty(p.stock)} left · reorder at ${_fmtQty(p.reorderLevel)}',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: p.stock.toDouble() <= 0
                              ? const Color(0xFFC62828)
                              : const Color(0xFFE65100)),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Update stock',
                      child: InkWell(
                        onTap: () => _showUpdateStockDialog(p),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(Icons.add_box_outlined,
                              size: 16, color: scheme.primary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildLedgerlyPanels() {
    final cashFlow = _buildCashFlowPanel();
    final focus = _buildFocusPanel();
    final ageing = _buildAgeingPanel();
    final gst = _buildGstPanel();
    final inventory = _buildInventoryPanel();
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < Breakpoints.compactMax) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              cashFlow,
              const SizedBox(height: 16),
              focus,
              const SizedBox(height: 16),
              ageing,
              const SizedBox(height: 16),
              gst,
              const SizedBox(height: 16),
              inventory,
            ],
          );
        }
        Widget pair(Widget left, Widget right) => IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: left),
                  const SizedBox(width: 16),
                  Expanded(child: right),
                ],
              ),
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            pair(cashFlow, focus),
            const SizedBox(height: 16),
            pair(ageing, gst),
            const SizedBox(height: 16),
            inventory,
          ],
        );
      },
    );
  }

  static const List<String> _businessQuotes = [
    'Cash flow is the lifeblood of your business.',
    'Know your numbers, and your numbers will grow.',
    'Profit is a habit, not an event.',
    'Small steps every day lead to big results.',
    'Discipline in collections keeps growth funded.',
    'What gets measured gets managed.',
  ];

  String _timeOfDayGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String _ownerFirstName() {
    final name = widget.user.username.trim();
    if (name.isEmpty) return 'there';
    return name.split(RegExp(r'\s+')).first;
  }

  /// Compact Indian money formatting, presentation only:
  /// `₹ 8.42 L`, `₹ 1.24 Cr`, `₹ 62,400`, `₹ 850.50`.
  String _inrCompact(double amount) {
    final negative = amount < 0;
    final v = amount.abs();
    final String body;
    if (v >= 10000000) {
      body = '${(v / 10000000).toStringAsFixed(2)} Cr';
    } else if (v >= 100000) {
      body = '${(v / 100000).toStringAsFixed(2)} L';
    } else if (v >= 1000) {
      body = NumberFormat('#,##0').format(v);
    } else {
      body = v.toStringAsFixed(2);
    }
    return '${negative ? '-' : ''}$_currencySymbol $body';
  }

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// Last six calendar month starts, oldest first (labels + zero-padding).
  List<DateTime> _lastSixMonths() {
    final now = DateTime.now();
    return List.generate(6, (i) => DateTime(now.year, now.month - (5 - i), 1));
  }

  static String _fmtQty(num v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  Map<String, double> get _receiptsByMonth => {
        for (final row in _monthlyRevenue)
          (row['month'] as String): (row['revenue'] as num).toDouble(),
      };

  /// Overdue rows in the selected currency (ReminderService exposes the
  /// symbol, which is what the dashboard renders under).
  List<OverdueInvoice> get _scopedOverdue => _reminderOverdue
      .where((r) => r.currencySymbol == _currencySymbol)
      .toList();

  double get _scopedOverdueTotal =>
      _scopedOverdue.fold(0.0, (sum, r) => sum + r.outstanding);

  int get _scopedOverdueCustomerCount => _scopedOverdue
      .map((r) => r.customerName.trim())
      .where((n) => n.isNotEmpty)
      .toSet()
      .length;

  void _openScanBill() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const ImportScreen()));
  }

  Widget _buildLedgerlyGreeting() {
    final now = DateTime.now();
    final dayIndex = now.difference(DateTime(now.year, 1, 1)).inDays;
    final quote = _businessQuotes[dayIndex % _businessQuotes.length];
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_timeOfDayGreeting()}, ${_ownerFirstName()}!',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
                letterSpacing: -0.3),
          ),
          const SizedBox(height: 4),
          Text(
            "Here's what's happening with your business today.",
            style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.format_quote_rounded, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  quote,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                      color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            DateFormat('EEEE, MMM d, yyyy').format(now),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Shared panel chrome for the Ledgerly overview cards.
  Widget _ledgerlyPanel({
    required String title,
    String? subtitle,
    required IconData icon,
    required Color color,
    Widget? trailing,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: color, size: 17),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _quickActionButton(
      ({IconData icon, String label, VoidCallback onTap, Color color}) action,
      {required bool expanded}) {
    final button = FilledButton.tonalIcon(
      onPressed: action.onTap,
      icon: Icon(action.icon, size: 18, color: action.color),
      label: Text(action.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        alignment: expanded ? Alignment.centerLeft : Alignment.center,
      ),
    );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }

  /// Quick Actions row — wired to the same destinations the dashboard already
  /// uses (tabs 1/4/8/11, ImportScreen for Scan Bill).
  Widget _buildLedgerlyQuickActions() {
    final actions =
        <({IconData icon, String label, VoidCallback onTap, Color color})>[
      (
        icon: Icons.add_circle_outline_rounded,
        label: 'Create Invoice',
        onTap: () => widget.onCreateInvoice?.call(),
        color: Theme.of(context).primaryColor,
      ),
      (
        icon: Icons.payments_outlined,
        label: 'Record Payment',
        onTap: () => widget.onNavigateTab(4),
        color: const Color(0xFF6A1B9A),
      ),
      (
        icon: Icons.trending_down_outlined,
        label: 'Add Expense',
        onTap: () => widget.onNavigateTab(8),
        color: const Color(0xFFE65100),
      ),
      (
        icon: Icons.inventory_outlined,
        label: 'Purchase Bill',
        onTap: () => widget.onNavigateTab(11),
        color: const Color(0xFF1565C0),
      ),
      (
        icon: Icons.qr_code_scanner_rounded,
        label: 'Scan Bill',
        onTap: _openScanBill,
        color: const Color(0xFF2E7D32),
      ),
    ];
    return _ledgerlyPanel(
      title: 'Quick Actions',
      icon: Icons.bolt_outlined,
      color: const Color(0xFF7C3AED),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < Breakpoints.compactMax) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _quickActionButton(actions[i], expanded: true),
                ],
              ],
            );
          }
          return Row(
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                    child: _quickActionButton(actions[i], expanded: false)),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildGreetingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      decoration: BoxDecoration(
        gradient: DashboardScreenColors.welcomePanelBackgroundGradientColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E293B).withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: context.isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppLocalizations.of(context)!
                      .dashboardWelcomeBackMessage(widget.user.username),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  AppLocalizations.of(context)!.dashboardBusinessGlanceSubtitle,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.white.withValues(alpha: 0.72)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      DateFormat('EEEE, MMM d, yyyy').format(DateTime.now()),
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppLocalizations.of(context)!
                          .dashboardWelcomeBackMessage(widget.user.username),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      AppLocalizations.of(context)!
                          .dashboardBusinessGlanceSubtitle,
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.72)),
                    ),
                  ],
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('EEEE').format(DateTime.now()),
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.72)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('MMM d, yyyy').format(DateTime.now()),
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildDueSoonSection() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.orange[700],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.notifications_active_outlined,
                color: Colors.orange, size: 22),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context)!.dashboardDueSoonTitle,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: Text(
                AppLocalizations.of(context)!
                    .dashboardInvoiceCountLabel(dueSoonInvoices.length),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange[800]),
              ),
            ),
            const Spacer(),
            Text(
              AppLocalizations.of(context)!.dashboardTodayTomorrowLabel,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Cards
        ...dueSoonInvoices.map((invoice) {
          final due = DateTime(invoice.dueDate!.year, invoice.dueDate!.month,
              invoice.dueDate!.day);
          final isToday = due == today;
          final badgeColor = isToday ? Colors.red : Colors.orange;
          final badgeLabel = isToday
              ? AppLocalizations.of(context)!.dashboardDueTodayBadge
              : AppLocalizations.of(context)!.dashboardDueTomorrowBadge;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            child: Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
                side: BorderSide(
                    color: badgeColor.withValues(alpha: 0.3), width: 1),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: LayoutBuilder(builder: (context, rowConstraints) {
                  final dueBadge = Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: badgeColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      badgeLabel,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: badgeColor),
                    ),
                  );
                  final amountPill = Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$_currencySymbol ${invoice.outstandingBalance.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: badgeColor),
                    ),
                  );
                  final customerRow = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_outline,
                          size: 15,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          invoice.customer.name,
                          style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      CustomerInfoButton(customer: invoice.customer),
                    ],
                  );
                  if (rowConstraints.maxWidth < Breakpoints.compactMax) {
                    // Two-line compact layout: badge + id + amount, then
                    // customer, then actions — the single-line desktop row
                    // needs ~400px minimum.
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            dueBadge,
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                '#${invoice.invoiceNumber ?? invoice.id}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            amountPill,
                          ],
                        ),
                        const SizedBox(height: 8),
                        customerRow,
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildActionButton(
                                Icons.visibility_outlined,
                                Colors.green,
                                AppLocalizations.of(context)!.actionView,
                                () => InvoicePdfServices.showInvoiceDetails(
                                    context, invoice)),
                            const SizedBox(width: 6),
                            _buildActionButton(
                                Icons.picture_as_pdf_outlined,
                                Colors.orange,
                                AppLocalizations.of(context)!.actionPdfPreview,
                                () => InvoicePdfServices.previewPDF(
                                    context, invoice)),
                            const SizedBox(width: 6),
                            _buildActionButton(
                                Icons.payments_outlined,
                                Colors.purple,
                                AppLocalizations.of(context)!
                                    .actionRecordPayment,
                                () => showDialog(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (_) => ApplyPaymentDialog(
                                        invoice: invoice,
                                        onPaymentRecorded: _loadDashboardData,
                                      ),
                                    )),
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      // Due badge
                      dueBadge,
                      const SizedBox(width: 16),
                      // Invoice ID
                      Text(
                        '#${invoice.invoiceNumber ?? invoice.id}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 16),
                      // Customer
                      customerRow,
                      const SizedBox(width: 16),
                      // Outstanding amount
                      amountPill,
                      const SizedBox(width: 12),
                      // Actions
                      _buildActionButton(
                          Icons.visibility_outlined,
                          Colors.green,
                          AppLocalizations.of(context)!.actionView,
                          () => InvoicePdfServices.showInvoiceDetails(
                              context, invoice)),
                      const SizedBox(width: 6),
                      _buildActionButton(
                          Icons.picture_as_pdf_outlined,
                          Colors.orange,
                          AppLocalizations.of(context)!.actionPdfPreview,
                          () =>
                              InvoicePdfServices.previewPDF(context, invoice)),
                      const SizedBox(width: 6),
                      _buildActionButton(
                          Icons.payments_outlined,
                          Colors.purple,
                          AppLocalizations.of(context)!.actionRecordPayment,
                          () => showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => ApplyPaymentDialog(
                                  invoice: invoice,
                                  onPaymentRecorded: _loadDashboardData,
                                ),
                              )),
                    ],
                  );
                }),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildOverdueSection() {
    final today = InvoiceCalculator.dateOnly(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.red[800],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.warning_amber_rounded, color: Colors.red[700], size: 22),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context)!.dashboardOverdueSectionTitle,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Text(
                AppLocalizations.of(context)!
                    .dashboardInvoiceCountLabel(overdueInvoices.length),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red[800]),
              ),
            ),
            const Spacer(),
            Text(
              AppLocalizations.of(context)!.dashboardOldestFirstLabel,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...overdueInvoices.map((invoice) {
          final daysOverdue = InvoiceCalculator.daysOverdue(
            dueDate: invoice.dueDate,
            asOf: today,
          );

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            child: Card(
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
                side: BorderSide(
                    color: Colors.red.withValues(alpha: 0.3), width: 1),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: LayoutBuilder(builder: (context, rowConstraints) {
                  final daysBadge = Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!
                          .dashboardDaysOverdueLabel(daysOverdue),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.red[800]),
                    ),
                  );
                  final amountPill = Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$_currencySymbol ${invoice.outstandingBalance.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.red[800]),
                    ),
                  );
                  final customerRow = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_outline,
                          size: 15,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          invoice.customer.name,
                          style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      CustomerInfoButton(customer: invoice.customer),
                    ],
                  );
                  if (rowConstraints.maxWidth < Breakpoints.compactMax) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            daysBadge,
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                '#${invoice.invoiceNumber ?? invoice.id}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            amountPill,
                          ],
                        ),
                        const SizedBox(height: 8),
                        customerRow,
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildActionButton(
                                Icons.visibility_outlined,
                                Colors.green,
                                AppLocalizations.of(context)!.actionView,
                                () => InvoicePdfServices.showInvoiceDetails(
                                    context, invoice)),
                            const SizedBox(width: 6),
                            _buildActionButton(
                                Icons.picture_as_pdf_outlined,
                                Colors.orange,
                                AppLocalizations.of(context)!.actionPdfPreview,
                                () => InvoicePdfServices.previewPDF(
                                    context, invoice)),
                            const SizedBox(width: 6),
                            _buildActionButton(
                              Icons.payments_outlined,
                              Colors.purple,
                              AppLocalizations.of(context)!.actionRecordPayment,
                              () => showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (_) => ApplyPaymentDialog(
                                  invoice: invoice,
                                  onPaymentRecorded: _loadDashboardData,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      // Days overdue badge
                      daysBadge,
                      const SizedBox(width: 16),
                      // Invoice ID
                      Text(
                        '#${invoice.invoiceNumber ?? invoice.id}',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 16),
                      // Customer
                      customerRow,
                      const SizedBox(width: 16),
                      // Outstanding amount
                      amountPill,
                      const SizedBox(width: 12),
                      // Actions
                      _buildActionButton(
                          Icons.visibility_outlined,
                          Colors.green,
                          AppLocalizations.of(context)!.actionView,
                          () => InvoicePdfServices.showInvoiceDetails(
                              context, invoice)),
                      const SizedBox(width: 6),
                      _buildActionButton(
                          Icons.picture_as_pdf_outlined,
                          Colors.orange,
                          AppLocalizations.of(context)!.actionPdfPreview,
                          () =>
                              InvoicePdfServices.previewPDF(context, invoice)),
                      const SizedBox(width: 6),
                      _buildActionButton(
                        Icons.payments_outlined,
                        Colors.purple,
                        AppLocalizations.of(context)!.actionRecordPayment,
                        () => showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => ApplyPaymentDialog(
                            invoice: invoice,
                            onPaymentRecorded: _loadDashboardData,
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _showUpdateStockDialog(Product product) async {
    final controller = TextEditingController(text: product.stock.toString());
    final l10n = AppLocalizations.of(context)!;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.inventory_2, color: Colors.red[600], size: 20),
            const SizedBox(width: 8),
            Flexible(
                child: Text(product.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        content: SizedBox(
          width: 300,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.dashboardNewStockQuantityLabel,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              prefixIcon: const Icon(Icons.add_box_outlined),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.actionCancel)),
          FilledButton(
            onPressed: () async {
              final qty = int.tryParse(controller.text.trim());
              if (qty == null || qty < 0) return;
              await ref
                  .read(productRepositoryProvider)
                  .updateProductStock(product.id, qty);
              if (ctx.mounted) Navigator.pop(ctx);
              _loadDashboardData();
            },
            child: Text(l10n.actionUpdate),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Widget _buildOutOfStockSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Container(
              width: 4,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.red[700],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.inventory_2, color: Colors.red[600], size: 22),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context)!.dashboardOutOfStockSectionTitle,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Text(
                AppLocalizations.of(context)!
                    .dashboardItemCountLabel(outOfStockProducts.length),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.red[700]),
              ),
            ),
            const Spacer(),
            Text(
              AppLocalizations.of(context)!.dashboardTapToRestockLabel,
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...outOfStockProducts.map((product) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              child: Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
                  side: BorderSide(
                      color: Colors.red.withValues(alpha: 0.3), width: 1),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      // Icon
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.inventory_2,
                            color: Colors.red[600], size: 20),
                      ),
                      const SizedBox(width: 16),
                      // Name & type
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              product.name,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              product.type == 'service'
                                  ? AppLocalizations.of(context)!.labelService
                                  : AppLocalizations.of(context)!.labelProduct,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Price
                      Text(
                        '$_currencySymbol${product.price.toStringAsFixed(2)}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface),
                      ),
                      const SizedBox(width: 16),
                      // Stock badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: Colors.red.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          AppLocalizations.of(context)!
                              .dashboardStockLabel(product.stock.toInt()),
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.red[700]),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Update stock button
                      _buildActionButton(
                        Icons.add_box_outlined,
                        Colors.green,
                        AppLocalizations.of(context)!.actionUpdateStock,
                        () => _showUpdateStockDialog(product),
                      ),
                    ],
                  ),
                ),
              ),
            )),
      ],
    );
  }

  Widget _buildActionButton(
      IconData icon, Color color, String tooltip, VoidCallback? onPressed) {
    final effectiveColor = onPressed != null
        ? color
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: effectiveColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: effectiveColor.withValues(alpha: 0.2)),
          ),
          child: Icon(icon, color: effectiveColor, size: 20),
        ),
      ),
    );
  }

  Widget _buildPaymentStatusChip(PaymentStatus status) {
    final l10n = AppLocalizations.of(context)!;
    final Color color;
    final String label;
    switch (status) {
      case PaymentStatus.paid:
        color = Colors.green;
        label = l10n.paymentStatusPaid;
      case PaymentStatus.partial:
        color = Colors.orange;
        label = l10n.paymentStatusPartial;
      case PaymentStatus.unpaid:
        color = Colors.red;
        label = l10n.paymentStatusUnpaid;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Future<void> _showCloneDialog(Invoice invoice) async {
    final l10n = AppLocalizations.of(context)!;
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.copy_all, color: Colors.teal),
            const SizedBox(width: 12),
            Text(l10n.dashboardDuplicateInvoiceTitle),
          ],
        ),
        content: Text(
          l10n.dashboardDuplicateInvoiceBody(
              invoice.invoiceNumber ?? invoice.id, invoice.customer.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.actionCancel),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'Quotation'),
            icon: const Icon(Icons.request_quote_outlined),
            label: Text(l10n.labelQuotation),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'Invoice'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.receipt),
            label: Text(l10n.labelInvoice),
          ),
        ],
      ),
    );
    if (type != null) {
      widget.onCloneInvoice(invoice, type);
    }
  }

  void _showDeleteDialog(Invoice invoice) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.warning_amber_rounded, color: Colors.red),
            ),
            const SizedBox(width: 12),
            Text(l10n.dashboardDeleteInvoiceTitle),
          ],
        ),
        content: Text(
          l10n.dashboardDeleteInvoiceBody(invoice.invoiceNumber ?? invoice.id),
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.actionCancel,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              InvoicePdfServices.deleteInvoice(context, invoice);
              _loadDashboardData();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
  }

  // ── Layout Toggle ───────────────────────────────────────────────────────────

  Widget _buildLayoutToggle() {
    return PopupMenuButton<String>(
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.dashboard_customize_outlined, size: 20),
          if (_showLayoutBanner)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      tooltip: AppLocalizations.of(context)!.dashboardLayoutTooltip,
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (!mounted) return;
        await ref
            .read(settingsRepositoryProvider)
            .setSetting(SettingKey.dashboardLayout, value);
        setState(() => _dashboardLayout = value);
        if (_showLayoutBanner) _dismissLayoutBanner();
      },
      itemBuilder: (ctx) {
        final l10n = AppLocalizations.of(context)!;
        return [
          _layoutMenuItem(
              'default',
              Icons.view_agenda_outlined,
              l10n.dashboardLayoutDefaultTitle,
              l10n.dashboardLayoutDefaultSubtitle),
          _layoutMenuItem('classic', Icons.grid_view_outlined,
              l10n.dashboardLayoutClassic, l10n.dashboardLayoutClassicSubtitle),
          _layoutMenuItem(
              'bento',
              Icons.auto_awesome_mosaic_outlined,
              l10n.dashboardLayoutBentoTitle,
              l10n.dashboardLayoutBentoSubtitle),
          _layoutMenuItem(
              'simple',
              Icons.view_list_outlined,
              l10n.dashboardLayoutSimpleTitle,
              l10n.dashboardLayoutSimpleSubtitle),
        ];
      },
    );
  }

  PopupMenuItem<String> _layoutMenuItem(
      String value, IconData icon, String title, String sub) {
    final active = _dashboardLayout == value;
    final primary = Theme.of(context).primaryColor;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: active
                  ? primary
                  : Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.normal,
                        color: active
                            ? primary
                            : Theme.of(context).colorScheme.onSurface)),
                Text(sub,
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (active) Icon(Icons.check_rounded, size: 16, color: primary),
        ],
      ),
    );
  }

  // ── Layout: Classic ─────────────────────────────────────────────────────────

  Widget _buildClassicLayout() {
    final primary = Theme.of(context).primaryColor;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.maxWidthNormal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLayoutDiscoveryBanner(),
              _buildThemeDiscoveryBanner(),
              _buildShortcutsDiscoveryBanner(),
              _buildSupportBanner(),
              _buildGreetingBanner(),
              const SizedBox(height: 20),
              // KPI row
              LayoutBuilder(builder: (context, kpiConstraints) {
                final kpiCards = <Widget>[
                  _buildKpiCard(
                      AppLocalizations.of(context)!
                          .dashboardRevenueCollectedLabel,
                      '$_currencySymbol ${_fmtAmt(totalRevenue)}',
                      Icons.account_balance_wallet_outlined,
                      const Color(0xFF6A1B9A)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.dashboardOutstandingLabel,
                      '$_currencySymbol ${_fmtAmt(totalOutstanding)}',
                      Icons.hourglass_top_outlined,
                      const Color(0xFFC62828)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.dashboardTotalInvoicesLabel,
                      totalInvoices.toString(),
                      Icons.receipt_long_outlined,
                      const Color(0xFFE65100)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.navCustomers,
                      totalCustomers.toString(),
                      Icons.people_outline,
                      const Color(0xFF1565C0)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.navProducts,
                      totalProducts.toString(),
                      Icons.inventory_2_outlined,
                      const Color(0xFF2E7D32)),
                ];
                return _responsiveKpiBlock(kpiCards, kpiConstraints.maxWidth);
              }),
              const SizedBox(height: 20),
              // Charts row — stacked on compact so neither chart is crushed.
              LayoutBuilder(builder: (context, chartConstraints) {
                final chartRow = IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _buildRevenueBarChart(primary)),
                      const SizedBox(width: 16),
                      Expanded(flex: 2, child: _buildRevenueDonut()),
                    ],
                  ),
                );
                if (chartConstraints.maxWidth < Breakpoints.compactMax) {
                  return Column(
                    children: [
                      _buildRevenueBarChart(primary),
                      const SizedBox(height: 16),
                      _buildRevenueDonut(),
                    ],
                  );
                }
                return chartRow;
              }),
              const SizedBox(height: 20),
              // Bottom row
              LayoutBuilder(builder: (context, bottomConstraints) {
                final rightColumn = Column(
                  children: [
                    if (dueSoonInvoices.isNotEmpty) ...[
                      _buildDueSoonCard(),
                      const SizedBox(height: 14),
                    ],
                    if (overdueInvoices.isNotEmpty) ...[
                      _buildOverdueCompactCard(),
                      const SizedBox(height: 14),
                    ],
                    if (outOfStockProducts.isNotEmpty) ...[
                      _buildOutOfStockCard(),
                      const SizedBox(height: 14),
                    ],
                    _buildQuickActionsCard(),
                  ],
                );
                if (bottomConstraints.maxWidth < Breakpoints.compactMax) {
                  return Column(
                    children: [
                      _buildCompactRecentInvoices(limit: 7),
                      const SizedBox(height: 14),
                      rightColumn,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        flex: 3, child: _buildCompactRecentInvoices(limit: 7)),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: rightColumn),
                  ],
                );
              }),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  /// KPI block shared by the dashboard layouts: 2-column wrap on compact
  /// widths, equal-width row on wide windows.
  Widget _responsiveKpiBlock(List<Widget> cards, double availableWidth) {
    if (availableWidth < Breakpoints.compactMax) {
      const gap = 12.0;
      final cardWidth = (availableWidth - gap) / 2;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final card in cards) SizedBox(width: cardWidth, child: card),
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }

  // ── Layout: Simple Feed ─────────────────────────────────────────────────────

  Widget _buildSimpleFeedLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.maxWidthNormal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLayoutDiscoveryBanner(),
              _buildThemeDiscoveryBanner(),
              _buildShortcutsDiscoveryBanner(),
              _buildSupportBanner(),
              _buildGreetingBanner(),
              const SizedBox(height: 20),
              // Mini KPI strip
              LayoutBuilder(builder: (context, kpiConstraints) {
                final kpiCards = <Widget>[
                  _buildKpiCard(
                      AppLocalizations.of(context)!
                          .dashboardRevenueCollectedLabel,
                      '$_currencySymbol ${_fmtAmt(totalRevenue)}',
                      Icons.account_balance_wallet_outlined,
                      const Color(0xFF6A1B9A)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.dashboardOutstandingLabel,
                      '$_currencySymbol ${_fmtAmt(totalOutstanding)}',
                      Icons.hourglass_top_outlined,
                      const Color(0xFFC62828)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.navInvoices,
                      totalInvoices.toString(),
                      Icons.receipt_long_outlined,
                      const Color(0xFFE65100)),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.navCustomers,
                      totalCustomers.toString(),
                      Icons.people_outline,
                      const Color(0xFF1565C0)),
                  _buildKpiCard(
                    AppLocalizations.of(context)!.navProducts,
                    totalProducts.toString(),
                    Icons.inventory_2_outlined,
                    const Color(0xFF2E7D32),
                  ),
                ];
                return _responsiveKpiBlock(kpiCards, kpiConstraints.maxWidth);
              }),
              const SizedBox(height: 20),
              // Two-column body — stacks on compact phones.
              LayoutBuilder(builder: (context, bodyConstraints) {
                final mainColumn = Column(
                  children: [
                    _buildCompactRecentInvoices(limit: 10),
                    if (_topCustomers.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildTopCustomersCard(),
                    ],
                    if (_topProducts.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildTopProductsCard(),
                    ],
                  ],
                );
                final sidebarColumn = Column(
                  children: [
                    _buildQuickActionsCard(),
                    const SizedBox(height: 14),
                    if (overdueInvoices.isNotEmpty) ...[
                      _buildOverdueCompactCard(),
                      const SizedBox(height: 14),
                    ],
                    if (dueSoonInvoices.isNotEmpty) ...[
                      _buildDueSoonCard(),
                      const SizedBox(height: 14),
                    ],
                    if (outOfStockProducts.isNotEmpty) _buildOutOfStockCard(),
                  ],
                );
                if (bodyConstraints.maxWidth < Breakpoints.compactMax) {
                  return Column(
                    children: [
                      mainColumn,
                      const SizedBox(height: 14),
                      sidebarColumn,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left: recent invoices + top customers + top products
                    Expanded(flex: 3, child: mainColumn),
                    const SizedBox(width: 20),
                    // Right sidebar
                    Expanded(flex: 2, child: sidebarColumn),
                  ],
                );
              }),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared: KPI Card ────────────────────────────────────────────────────────

  Widget _buildKpiCard(String title, String value, IconData icon, Color color,
      {bool alert = false}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: alert
            ? Border.all(color: color.withValues(alpha: 0.35), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title wraps naturally (up to 2 lines) instead of
                // ellipsizing ordinary labels like "Products".
                Text(title,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        height: 1.25),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(value,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared: Revenue Bar Chart ────────────────────────────────────────────────

  Widget _buildRevenueBarChart(Color primary) {
    final hasData = _monthlyRevenue.isNotEmpty;
    final maxY = hasData
        ? _monthlyRevenue
                .map((e) => (e['revenue'] as num).toDouble())
                .reduce((a, b) => a > b ? a : b) *
            1.25
        : 1000.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppLocalizations.of(context)!.dashboardRevenueLast6MonthsTitle,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 16),
          SizedBox(
            height: 190,
            child: hasData
                ? BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: maxY,
                      barGroups: _monthlyRevenue.asMap().entries.map((entry) {
                        final rev = (entry.value['revenue'] as num).toDouble();
                        return BarChartGroupData(
                          x: entry.key,
                          barRods: [
                            BarChartRodData(
                              toY: rev,
                              gradient: LinearGradient(
                                colors: [
                                  primary,
                                  primary.withValues(alpha: 0.55)
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              width: 28,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(6)),
                            ),
                          ],
                        );
                      }).toList(),
                      titlesData: FlTitlesData(
                        leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              if (idx < 0 || idx >= _monthlyRevenue.length) {
                                return const SizedBox.shrink();
                              }
                              final monthStr =
                                  _monthlyRevenue[idx]['month'] as String;
                              try {
                                final date =
                                    DateFormat('yyyy-MM').parse(monthStr);
                                return Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Text(DateFormat('MMM').format(date),
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                                );
                              } catch (_) {
                                return const SizedBox.shrink();
                              }
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                            color: Colors.grey.withValues(alpha: 0.12),
                            strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                            '$_currencySymbol ${_fmtAmt(rod.toY)}',
                            const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.bar_chart_outlined,
                            size: 48,
                            color:
                                Theme.of(context).colorScheme.outlineVariant),
                        const SizedBox(height: 8),
                        Text(
                            AppLocalizations.of(context)!
                                .dashboardNoPaymentDataYetLabel,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 13)),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ── Shared: Revenue Donut ────────────────────────────────────────────────────

  Widget _buildRevenueDonut() {
    final total = totalRevenue + totalOutstanding;
    final hasData = total > 0.01;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppLocalizations.of(context)!.dashboardFinancialOverviewTitle,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: hasData
                ? PieChart(
                    PieChartData(
                      centerSpaceRadius: 46,
                      sectionsSpace: 3,
                      sections: [
                        PieChartSectionData(
                          value: totalRevenue,
                          color: const Color(0xFF2E7D32),
                          title: '',
                          radius: 38,
                        ),
                        PieChartSectionData(
                          value: totalOutstanding,
                          color: const Color(0xFFC62828),
                          title: '',
                          radius: 38,
                        ),
                      ],
                    ),
                  )
                : Center(
                    child: Text(
                        AppLocalizations.of(context)!
                            .dashboardNoInvoicesYetTitle,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13))),
          ),
          const SizedBox(height: 14),
          _buildDonutLegend(
              AppLocalizations.of(context)!.dashboardCollectedLabel,
              const Color(0xFF2E7D32),
              '$_currencySymbol ${_fmtAmt(totalRevenue)}'),
          const SizedBox(height: 6),
          _buildDonutLegend(
              AppLocalizations.of(context)!.dashboardOutstandingLabel,
              const Color(0xFFC62828),
              '$_currencySymbol ${_fmtAmt(totalOutstanding)}'),
          if (overdueInvoices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFB71C1C).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 13, color: Color(0xFFB71C1C)),
                  const SizedBox(width: 6),
                  Text(
                      AppLocalizations.of(context)!
                          .dashboardInvoiceCountOverdueLabel(
                              overdueInvoices.length),
                      style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB71C1C),
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDonutLegend(String label, Color color, String amount) {
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Text(amount,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface)),
      ],
    );
  }

  // ── Shared: Compact Recent Invoices ─────────────────────────────────────────

  Widget _buildCompactRecentInvoices({int limit = 7}) {
    final invoices = recentInvoices.take(limit).toList();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(AppLocalizations.of(context)!.dashboardRecentInvoicesTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              const Spacer(),
              Text(AppLocalizations.of(context)!.dashboardLastNLabel(limit),
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 4),
          // Header row
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                    flex: 2,
                    child: Text(AppLocalizations.of(context)!.labelInvoice,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600))),
                Expanded(
                    flex: 3,
                    child: Text(AppLocalizations.of(context)!.labelCustomer,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600))),
                Expanded(
                    flex: 2,
                    child: Text(AppLocalizations.of(context)!.labelAmount,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600))),
                const SizedBox(width: 60),
              ],
            ),
          ),
          Divider(
              height: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 4),
          if (invoices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: Text(
                      AppLocalizations.of(context)!.dashboardNoInvoicesYetTitle,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13))),
            )
          else
            ...invoices.map(_buildCompactInvoiceRow),
        ],
      ),
    );
  }

  Widget _buildCompactInvoiceRow(Invoice inv) {
    final status = inv.paymentStatus;
    final Color statusColor;
    final String statusLabel;
    final l10n = AppLocalizations.of(context)!;
    switch (status) {
      case PaymentStatus.paid:
        statusColor = const Color(0xFF2E7D32);
        statusLabel = l10n.paymentStatusPaid;
        break;
      case PaymentStatus.partial:
        statusColor = const Color(0xFFF57C00);
        statusLabel = l10n.paymentStatusPartial;
        break;
      default:
        final isOver = InvoiceCalculator.isOverdue(
            dueDate: inv.dueDate, outstanding: inv.outstandingBalance);
        statusColor =
            isOver ? const Color(0xFFC62828) : const Color(0xFF546E7A);
        statusLabel = isOver
            ? l10n.dashboardOverdueSectionTitle
            : l10n.paymentStatusUnpaid;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
                '#${inv.id.length > 8 ? inv.id.substring(inv.id.length - 8) : inv.id}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 3,
            child: Text(inv.customer.name,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text('$_currencySymbol ${_fmtAmt(inv.payableTotal)}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                textAlign: TextAlign.right,
                maxLines: 1),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6)),
            child: Text(statusLabel,
                style: TextStyle(
                    fontSize: 10,
                    color: statusColor,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Edit',
            child: InkWell(
              onTap: () => widget.onEditInvoice(inv),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.edit_outlined,
                    size: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Download PDF',
            child: InkWell(
              onTap: () => PDFService.downloadPDF(context, inv),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.download_outlined,
                    size: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared: Due Soon Card ────────────────────────────────────────────────────

  Widget _buildDueSoonCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: const Color(0xFFF57C00).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.event_outlined,
                    color: Color(0xFFF57C00), size: 15),
              ),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.dashboardDueSoonTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: const Color(0xFFF57C00).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Text('${dueSoonInvoices.length}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFF57C00),
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...dueSoonInvoices.take(5).map((inv) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(inv.customer.name,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Text('$_currencySymbol ${_fmtAmt(inv.outstandingBalance)}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 2),
                    _buildInvoiceActionMenu(inv),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ── Shared: Out of Stock Card ────────────────────────────────────────────────

  Widget _buildOutOfStockCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.18), width: 1),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.inventory_2_outlined,
                    color: Colors.red, size: 15),
              ),
              const SizedBox(width: 8),
              Text(
                  AppLocalizations.of(context)!.dashboardOutOfStockSectionTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Text('${outOfStockProducts.length}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...outOfStockProducts.take(5).map((p) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(p.name,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Text(AppLocalizations.of(context)!.dashboardZeroLeftLabel,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: AppLocalizations.of(context)!.actionUpdateStock,
                      child: InkWell(
                        onTap: () => _showUpdateStockDialog(p),
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.add_box_outlined,
                                  size: 13, color: Colors.green),
                              const SizedBox(width: 4),
                              Text(AppLocalizations.of(context)!.labelStock,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.green,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ── Shared: Overdue Compact Card ─────────────────────────────────────────────

  Widget _buildOverdueCompactCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: const Color(0xFFC62828).withValues(alpha: 0.2), width: 1),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: const Color(0xFFC62828).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFC62828), size: 15),
              ),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.dashboardOverdueSectionTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: const Color(0xFFC62828).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: Text('${overdueInvoices.length}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFC62828),
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...overdueInvoices.take(5).map((inv) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(inv.customer.name,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Text('$_currencySymbol ${_fmtAmt(inv.outstandingBalance)}',
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFC62828),
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 4),
                    Tooltip(
                      message:
                          AppLocalizations.of(context)!.actionRecordPayment,
                      child: InkWell(
                        onTap: () => showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => ApplyPaymentDialog(
                            invoice: inv,
                            onPaymentRecorded: _loadDashboardData,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF6A1B9A).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.payments_outlined,
                                  size: 13, color: Color(0xFF6A1B9A)),
                              const SizedBox(width: 4),
                              Text(AppLocalizations.of(context)!.actionPay,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF6A1B9A),
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    _buildPdfActionMenu(inv),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ── Shared: Quick Actions Card ───────────────────────────────────────────────

  Widget _buildQuickActionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppLocalizations.of(context)!.dashboardQuickActionsTitle,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 12),
          _buildQuickActionRow(
              Icons.add_circle_outline_rounded,
              AppLocalizations.of(context)!.navNewInvoice,
              Theme.of(context).primaryColor, () {
            if (!mounted) return;
            context
                .findAncestorStateOfType<_DashboardScreenState>()
                ?.setState(() {
              context
                  .findAncestorStateOfType<_DashboardScreenState>()
                  ?._selectedIndex = 1;
            });
          }),
          const SizedBox(height: 4),
          _buildQuickActionRow(
              Icons.person_add_outlined,
              AppLocalizations.of(context)!.navCustomers,
              const Color(0xFF1565C0), () {
            if (!mounted) return;
            context
                .findAncestorStateOfType<_DashboardScreenState>()
                ?.setState(() {
              context
                  .findAncestorStateOfType<_DashboardScreenState>()
                  ?._selectedIndex = 5;
            });
          }),
          const SizedBox(height: 4),
          _buildQuickActionRow(
              Icons.bar_chart_outlined,
              AppLocalizations.of(context)!.navReports,
              const Color(0xFF2E7D32), () {
            if (!mounted) return;
            context
                .findAncestorStateOfType<_DashboardScreenState>()
                ?.setState(() {
              context
                  .findAncestorStateOfType<_DashboardScreenState>()
                  ?._selectedIndex = 7;
            });
          }),
        ],
      ),
    );
  }

  Widget _buildQuickActionRow(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: color, size: 15),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w500))),
            Icon(Icons.chevron_right_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  // ── Shared: Amount Formatter ─────────────────────────────────────────────────

  String _fmtAmt(double amount) {
    if (amount >= 10000000) {
      return '${(amount / 10000000).toStringAsFixed(2)}Cr';
    }
    if (amount >= 100000) return '${(amount / 100000).toStringAsFixed(2)}L';
    if (amount >= 1000) return '${(amount / 1000).toStringAsFixed(1)}K';
    return amount.toStringAsFixed(2);
  }

  // ── Layout: Bento Grid ──────────────────────────────────────────────────────

  Widget _buildBentoLayout() {
    final primary = Theme.of(context).primaryColor;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppLayout.maxWidthNormal),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLayoutDiscoveryBanner(),
              _buildThemeDiscoveryBanner(),
              _buildShortcutsDiscoveryBanner(),
              _buildSupportBanner(),
              _buildGreetingBanner(),
              const SizedBox(height: 20),
              // ── Top row: Hero chart + 2×2 KPI grid ──────────────────────────
              // Compact phones: chart and KPI cards stack full-width instead
              // of sharing a fixed-290px hero row that crushes both.
              LayoutBuilder(builder: (context, heroConstraints) {
                final kpiTiles = <Widget>[
                  _buildKpiCard(
                    AppLocalizations.of(context)!
                        .dashboardRevenueCollectedLabel,
                    '$_currencySymbol ${_fmtAmt(totalRevenue)}',
                    Icons.account_balance_wallet_outlined,
                    const Color(0xFF6A1B9A),
                  ),
                  _buildKpiCard(
                    AppLocalizations.of(context)!.navInvoices,
                    totalInvoices.toString(),
                    Icons.receipt_long_outlined,
                    const Color(0xFFE65100),
                  ),
                  _buildKpiCard(
                    AppLocalizations.of(context)!.dashboardOutstandingLabel,
                    '$_currencySymbol ${_fmtAmt(totalOutstanding)}',
                    Icons.hourglass_top_outlined,
                    const Color(0xFFC62828),
                  ),
                  _buildKpiCard(
                    AppLocalizations.of(context)!.dashboardOverdueSectionTitle,
                    overdueInvoices.length.toString(),
                    Icons.warning_amber_outlined,
                    const Color(0xFFB71C1C),
                    alert: overdueInvoices.isNotEmpty,
                  ),
                  _buildKpiCard(
                      AppLocalizations.of(context)!.navCustomers,
                      totalCustomers.toString(),
                      Icons.people_outline,
                      const Color(0xFF1565C0)),
                  _buildKpiCard(
                    AppLocalizations.of(context)!.navProducts,
                    totalProducts.toString(),
                    Icons.inventory_2_outlined,
                    const Color(0xFF2E7D32),
                  ),
                ];
                if (heroConstraints.maxWidth < Breakpoints.compactMax) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildRevenueBarChart(primary),
                      const SizedBox(height: 14),
                      _responsiveKpiBlock(kpiTiles, heroConstraints.maxWidth),
                    ],
                  );
                }
                return SizedBox(
                  height: 290,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Hero: Revenue bar chart
                      Expanded(
                        flex: 3,
                        child: _buildRevenueBarChart(primary),
                      ),
                      const SizedBox(width: 14),
                      // 2×3 KPI tiles
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            for (var row = 0; row < 3; row++)
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(child: kpiTiles[row * 2]),
                                    const SizedBox(width: 14),
                                    Expanded(child: kpiTiles[row * 2 + 1]),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 14),
              // ── Bottom row: Wide invoice table + narrow sidebar ───────────────
              LayoutBuilder(builder: (context, bottomConstraints) {
                final mainColumn = Column(
                  children: [
                    _buildCompactRecentInvoices(limit: 8),
                    if (_topProducts.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildTopProductsCard(),
                    ],
                  ],
                );
                final sidebarColumn = Column(
                  children: [
                    _buildQuickActionsCard(),
                    if (overdueInvoices.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildOverdueCompactCard(),
                    ],
                    if (dueSoonInvoices.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildDueSoonCard(),
                    ],
                    if (outOfStockProducts.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildOutOfStockCard(),
                    ],
                  ],
                );
                if (bottomConstraints.maxWidth < Breakpoints.compactMax) {
                  return Column(
                    children: [
                      mainColumn,
                      const SizedBox(height: 14),
                      sidebarColumn,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: mainColumn),
                    const SizedBox(width: 14),
                    Expanded(flex: 2, child: sidebarColumn),
                  ],
                );
              }),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared: PDF-Only Action Menu (⋯) ───────────────────────────────────────

  Widget _buildPdfActionMenu(Invoice inv) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert_rounded,
          size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
      iconSize: 22,
      padding: EdgeInsets.zero,
      tooltip: AppLocalizations.of(context)!.dashboardPdfActionsTooltip,
      offset: const Offset(0, 24),
      onSelected: (value) {
        if (value == 'preview') {
          InvoicePdfServices.previewPDF(context, inv);
        } else if (value == 'download') {
          PDFService.downloadPDF(context, inv);
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'preview',
          child: Row(children: [
            const Icon(Icons.visibility_outlined,
                size: 16, color: Colors.green),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context)!.actionPdfPreview,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(children: [
            const Icon(Icons.download_outlined,
                size: 16, color: Colors.deepPurple),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context)!.actionDownloadPdf,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ],
    );
  }

  // ── Shared: Invoice Action Menu (⋯) ────────────────────────────────────────

  Widget _buildInvoiceActionMenu(Invoice inv) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert_rounded,
          size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
      iconSize: 22,
      padding: EdgeInsets.zero,
      tooltip: AppLocalizations.of(context)!.dashboardActionsTooltip,
      offset: const Offset(0, 24),
      onSelected: (value) {
        switch (value) {
          case 'payment':
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => ApplyPaymentDialog(
                invoice: inv,
                onPaymentRecorded: _loadDashboardData,
              ),
            );
            break;
          case 'preview':
            InvoicePdfServices.previewPDF(context, inv);
            break;
          case 'download':
            PDFService.downloadPDF(context, inv);
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'payment',
          child: Row(children: [
            const Icon(Icons.payments_outlined,
                size: 16, color: Color(0xFF6A1B9A)),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context)!.actionRecordPayment,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
        PopupMenuItem(
          value: 'preview',
          child: Row(children: [
            const Icon(Icons.visibility_outlined,
                size: 16, color: Colors.green),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context)!.actionPdfPreview,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(children: [
            const Icon(Icons.download_outlined,
                size: 16, color: Colors.deepPurple),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context)!.actionDownloadPdf,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ],
    );
  }

  // ── Shared: Top Customers Card ───────────────────────────────────────────────

  Widget _buildTopCustomersCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.emoji_events_outlined,
                    color: Color(0xFF1565C0), size: 15),
              ),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.dashboardTopCustomersTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          ..._topCustomers.map((c) {
            final name = c['customer_name'] as String? ?? '';
            final paid = (c['total_paid'] as num).toDouble();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor:
                        const Color(0xFF1565C0).withValues(alpha: 0.1),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF1565C0),
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(name,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  Text('$_currencySymbol ${_fmtAmt(paid)}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Shared: Top Products Card ────────────────────────────────────────────────

  Widget _buildTopProductsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.trending_up_outlined,
                    color: Color(0xFF2E7D32), size: 15),
              ),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.dashboardTopProductsTitle,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          ..._topProducts.map((p) {
            final name = p['product_name'] as String? ?? '';
            final qty = (p['total_qty'] as num).toDouble();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(7)),
                    child: const Icon(Icons.inventory_2_outlined,
                        size: 13, color: Color(0xFF2E7D32)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(name,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  Text(
                      AppLocalizations.of(context)!.dashboardUnitsLabel(
                          qty % 1 == 0
                              ? qty.toInt().toString()
                              : qty.toStringAsFixed(1)),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _BetaTag extends StatelessWidget {
  const _BetaTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF7C3AED),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        AppLocalizations.of(context)!.dashboardBetaBadge,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
