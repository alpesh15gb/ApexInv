import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:apexbooks/domain/customer_identity.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/screens/auth/login_screen.dart';
import 'package:apexbooks/screens/create_invoice_screen_v2.dart';
import 'package:apexbooks/screens/customer_management_screen_v2.dart';
import 'package:apexbooks/screens/dashboard_screen.dart' show DashboardHome;
import 'package:apexbooks/screens/expense_management_screen.dart';
import 'package:apexbooks/screens/invoice_management_screen_v2.dart';
import 'package:apexbooks/screens/product_management_screen_v2.dart';
import 'package:apexbooks/screens/purchase_order_screen.dart';
import 'package:apexbooks/screens/reports_screen.dart';
import 'package:apexbooks/screens/settings/settings_screen.dart';
import 'package:apexbooks/utils/session_manager.dart';

/// Phone-first application shell.
///
/// Business/data screens are deliberately shared with desktop. Only the app
/// chrome changes here: phones use bottom navigation for common destinations
/// and a drawer for the complete feature list instead of the fixed desktop
/// sidebar.
class MobileDashboardScreen extends ConsumerStatefulWidget {
  final User loggedInUser;

  const MobileDashboardScreen(this.loggedInUser, {super.key});

  @override
  ConsumerState<MobileDashboardScreen> createState() =>
      _MobileDashboardScreenState();
}

class _MobileDashboardScreenState
    extends ConsumerState<MobileDashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final InvoiceFormGuard _invoiceFormGuard = InvoiceFormGuard();

  int _selectedIndex = 0;
  late User _currentUser;
  Invoice? _invoiceToEdit;
  Invoice? _invoiceToClone;
  String _cloneType = 'Invoice';
  String? _pendingReportsStatementCustomerKey;
  int? _accessibilityJumpToken;

  @override
  void initState() {
    super.initState();
    _currentUser = widget.loggedInUser;
    SessionManager.initialize(_onSessionTimeout);
  }

  @override
  void dispose() {
    SessionManager.dispose();
    super.dispose();
  }

  void _onSessionTimeout() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context)!.dashboardSessionExpiredMessage,
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _logout() async {
    await ref.read(authRepositoryProvider).logoutAndSessionReset();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _refreshUser() async {
    if (!mounted) return;
    final fresh =
        await ref.read(authRepositoryProvider).getUserById(_currentUser.id);
    if (fresh != null && mounted) {
      setState(() => _currentUser = fresh);
    }
  }

  Future<bool> _canLeaveInvoiceForm() async {
    return await _invoiceFormGuard.canLeave?.call() ?? true;
  }

  Future<void> _selectTab(int index) async {
    if (_selectedIndex == index) {
      if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
        Navigator.of(context).maybePop();
      }
      return;
    }

    if (_selectedIndex == 1 && !await _canLeaveInvoiceForm()) return;
    if (_selectedIndex == 7 && index != 7) await _refreshUser();
    if (!mounted) return;

    setState(() {
      _selectedIndex = index;
      if (index != 1) {
        _invoiceToEdit = null;
        _invoiceToClone = null;
      }
    });

    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).maybePop();
    }
  }

  void _editInvoice(Invoice invoice) {
    _openEditInvoice(invoice);
  }

  Future<void> _openEditInvoice(Invoice invoice) async {
    if (_selectedIndex == 1 && !await _canLeaveInvoiceForm()) return;
    if (!mounted) return;
    setState(() {
      _selectedIndex = 1;
      _invoiceToEdit = invoice;
      _invoiceToClone = null;
    });
  }

  void _cloneInvoice(Invoice invoice, String type) {
    _openCloneInvoice(invoice, type);
  }

  Future<void> _openCloneInvoice(Invoice invoice, String type) async {
    if (_selectedIndex == 1 && !await _canLeaveInvoiceForm()) return;
    if (!mounted) return;
    setState(() {
      _selectedIndex = 1;
      _invoiceToEdit = null;
      _invoiceToClone = invoice;
      _cloneType = type;
    });
  }

  Widget _buildScreen() {
    switch (_selectedIndex) {
      case 0:
        return DashboardHome(
          onEditInvoice: _editInvoice,
          onCloneInvoice: _cloneInvoice,
          user: _currentUser,
        );
      case 1:
        final createInvoiceKey = ValueKey(
          'mobile_create_invoice_${_invoiceToEdit?.id ?? 'new'}_${_invoiceToClone?.id ?? ''}',
        );
        return CreateInvoiceScreenV2(
          key: createInvoiceKey,
          invoiceToEdit: _invoiceToEdit,
          cloneFrom: _invoiceToClone,
          cloneType: _invoiceToClone != null ? _cloneType : null,
          guard: _invoiceFormGuard,
          onCreateNewInvoice: () {
            if (!mounted) return;
            setState(() {
              _invoiceToEdit = null;
              _invoiceToClone = null;
            });
          },
        );
      case 2:
        return InvoiceManagementScreenV2(
          key: const ValueKey('mobile_invoice_list'),
          onEditInvoice: _editInvoice,
          onCloneInvoice: _cloneInvoice,
          user: _currentUser,
          filterType: 'Invoice',
        );
      case 3:
        return InvoiceManagementScreenV2(
          key: const ValueKey('mobile_quotation_list'),
          onEditInvoice: _editInvoice,
          onCloneInvoice: _cloneInvoice,
          user: _currentUser,
          filterType: 'Quotation',
        );
      case 4:
        return InvoiceManagementScreenV2(
          key: const ValueKey('mobile_receipt_list'),
          onEditInvoice: _editInvoice,
          onCloneInvoice: _cloneInvoice,
          user: _currentUser,
          filterType: 'Receipt',
        );
      case 5:
        return CustomerManagementScreenV2(
          user: _currentUser,
          onViewCustomerStatement: (customer) {
            setState(() {
              _pendingReportsStatementCustomerKey = CustomerIdentity.key(
                id: customer.id,
                name: customer.name,
              );
              _selectedIndex = 7;
            });
          },
        );
      case 6:
        return ProductManagementScreenV2(user: _currentUser);
      case 7:
        final statementCustomerKey = _pendingReportsStatementCustomerKey;
        _pendingReportsStatementCustomerKey = null;
        return ReportsScreen(
          initialStatementCustomerKey: statementCustomerKey,
        );
      case 8:
        return const ExpenseManagementScreen();
      case 9:
        return const PurchaseOrderScreen();
      case 10:
        return SettingsScreen(
          currentUser: _currentUser,
          openAccessibilityToken: _accessibilityJumpToken,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  int get _bottomIndex {
    return switch (_selectedIndex) {
      0 => 0,
      1 => 1,
      2 => 2,
      5 => 3,
      _ => 4,
    };
  }

  Future<void> _onBottomDestinationSelected(int index) async {
    switch (index) {
      case 0:
        await _selectTab(0);
        return;
      case 1:
        await _selectTab(1);
        return;
      case 2:
        await _selectTab(2);
        return;
      case 3:
        await _selectTab(5);
        return;
      case 4:
        _scaffoldKey.currentState?.openDrawer();
        return;
    }
  }

  Widget _drawerItem({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final selected = _selectedIndex == index;
    return ListTile(
      selected: selected,
      leading: Icon(icon),
      title: Text(label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onTap: () => _selectTab(index),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/images/logo_v_dark.png'
                          : 'assets/images/logo_v.png',
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentUser.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _currentUser.isAdmin()
                              ? l10n.dashboardRoleAdmin
                              : l10n.dashboardRoleUser,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    tooltip: l10n.actionClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(10),
                children: [
                  _drawerItem(
                    index: 0,
                    icon: Icons.dashboard_outlined,
                    label: l10n.navDashboard,
                  ),
                  _drawerItem(
                    index: 1,
                    icon: Icons.add_circle_outline,
                    label: l10n.navNewInvoice,
                  ),
                  _drawerItem(
                    index: 2,
                    icon: Icons.receipt_long_outlined,
                    label: l10n.navInvoices,
                  ),
                  _drawerItem(
                    index: 3,
                    icon: Icons.request_quote_outlined,
                    label: l10n.navQuotations,
                  ),
                  _drawerItem(
                    index: 4,
                    icon: Icons.point_of_sale_outlined,
                    label: l10n.navReceipts,
                  ),
                  _drawerItem(
                    index: 5,
                    icon: Icons.people_outline,
                    label: l10n.navCustomers,
                  ),
                  _drawerItem(
                    index: 6,
                    icon: Icons.inventory_2_outlined,
                    label: l10n.navProducts,
                  ),
                  _drawerItem(
                    index: 7,
                    icon: Icons.bar_chart_outlined,
                    label: l10n.navReports,
                  ),
                  _drawerItem(
                    index: 8,
                    icon: Icons.payments_outlined,
                    label: 'Expenses',
                  ),
                  _drawerItem(
                    index: 9,
                    icon: Icons.shopping_cart_outlined,
                    label: 'Purchase Orders',
                  ),
                  _drawerItem(
                    index: 10,
                    icon: Icons.settings_outlined,
                    label: l10n.navSettings,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(l10n.dashboardLogoutTooltip),
              onTap: _logout,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return GestureDetector(
      onTap: SessionManager.onUserActivity,
      onPanDown: (_) => SessionManager.onUserActivity(),
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildDrawer(context),
        body: _buildScreen(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _bottomIndex,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          onDestinationSelected: _onBottomDestinationSelected,
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.dashboard_outlined),
              selectedIcon: const Icon(Icons.dashboard),
              label: l10n.navDashboard,
            ),
            NavigationDestination(
              icon: const Icon(Icons.add_circle_outline),
              selectedIcon: const Icon(Icons.add_circle),
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
            const NavigationDestination(
              icon: Icon(Icons.menu),
              selectedIcon: Icon(Icons.menu_open),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
