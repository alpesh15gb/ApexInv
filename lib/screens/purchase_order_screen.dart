import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:apexbooks/database/purchase_order_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/purchase_order.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/screens/purchase_bill_screen.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/widgets/app/app.dart';
import 'package:apexbooks/widgets/document_editor_shell.dart';

class PurchaseOrderScreen extends ConsumerStatefulWidget {
  final User? user;
  const PurchaseOrderScreen({super.key, this.user});

  @override
  ConsumerState<PurchaseOrderScreen> createState() =>
      _PurchaseOrderScreenState();
}

class _PurchaseOrderScreenState extends ConsumerState<PurchaseOrderScreen> {
  List<PurchaseOrder> _orders = [];
  bool _isLoading = true;
  String? _filterStatus;
  int _currentPage = 0;
  final int _pageSize = 20;
  // Display-only total for the "Showing x–y of N" footer. The paginated
  // query in _loadData is unchanged.
  int _totalCount = 0;
  // Presentation-only state: search, date range, sorting and selection are
  // applied in-memory over the already-loaded page rows. Queries, totals,
  // stock and navigation are untouched.
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  DateTime? _fromDate;
  DateTime? _toDate;
  String _sortField = 'date'; // 'date' | 'vendor' | 'total'
  bool _sortAscending = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final orders = await PurchaseOrderService.getPurchaseOrdersPaginated(
      page: _currentPage,
      pageSize: _pageSize,
      status: _filterStatus,
    );
    final total = await PurchaseOrderService.getPurchaseOrderCount(
      status: _filterStatus,
    );
    if (mounted) {
      setState(() {
        _orders = orders;
        _totalCount = total;
        _isLoading = false;
        _selectedIds.removeWhere((id) => !_orders.any((o) => o.id == id));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < Breakpoints.compactMax;
    return Scaffold(
      appBar: AppBar(title: const Text('Purchase Orders')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < Breakpoints.compactMax;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _header(narrow),
              ),
              const SizedBox(height: 12),
              _statusChips(),
              _filterRow(narrow),
              if (_selectedIds.isNotEmpty) _selectionBar(),
              Expanded(
                child: _isLoading
                    ? const AppLoadingState()
                    : _orders.isEmpty
                        ? _emptyState()
                        : _visible.isEmpty
                            ? _noMatchState()
                            : narrow
                                ? _cardList()
                                : _table(),
              ),
              if (!_isLoading && _orders.isNotEmpty) _footer(),
            ],
          );
        },
      ),
      floatingActionButton: isNarrow
          ? FloatingActionButton.extended(
              onPressed: () => _showCreateOrderDialog(),
              icon: const Icon(Icons.add),
              label: const Text('New Order'),
            )
          : null,
    );
  }

  /// Title + subtitle + primary create button (top-right on wide screens;
  /// the button moves to the FAB on narrow screens).
  Widget _header(bool isNarrow) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Purchase Orders',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                'Track expected stock from vendors.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        if (!isNarrow) ...[
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () => _showCreateOrderDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Order'),
          ),
        ],
      ],
    );
  }

  /// Status filter chips with LIVE counts aggregated in-memory from the
  /// already-loaded rows. Selection still drives the existing
  /// server-side status query — counts never trigger extra queries.
  Widget _statusChips() {
    final counts = _statusCounts;
    final options = <(String, String?)>[
      ('All', null),
      ('Draft', 'draft'),
      ('Confirmed', 'confirmed'),
      ('Received', 'received'),
    ];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (label, status) = options[i];
          final count = status == null ? _orders.length : (counts[status] ?? 0);
          return FilterChip(
            label: Text('$label ($count)'),
            selected: _filterStatus == status,
            onSelected: (_) {
              if (_filterStatus == status) return;
              setState(() => _filterStatus = status);
              _currentPage = 0;
              _loadData();
            },
          );
        },
      ),
    );
  }

  Map<String, int> get _statusCounts {
    final counts = {'draft': 0, 'confirmed': 0, 'received': 0};
    for (final o in _orders) {
      if (counts.containsKey(o.status)) {
        counts[o.status] = counts[o.status]! + 1;
      }
    }
    return counts;
  }

  /// Search + date-range + Filter row. All controls filter/sort the loaded
  /// rows in-memory only.
  Widget _filterRow(bool isNarrow) {
    final search = AppSearchField(
      controller: _searchCtrl,
      hintText: 'Search vendor / order no',
      onChanged: (v) => setState(() => _search = v),
      onClear: () => setState(() {
        _searchCtrl.clear();
        _search = '';
      }),
    );
    final dateBtn = OutlinedButton.icon(
      onPressed: _pickRange,
      icon: const Icon(Icons.date_range, size: 18),
      label: Text(_rangeLabel(), overflow: TextOverflow.ellipsis),
    );
    final filterBtn = OutlinedButton.icon(
      onPressed: _showFilterDialog,
      icon: const Icon(Icons.filter_list, size: 18),
      label: Text(_filterActive ? 'Filter •' : 'Filter'),
    );
    if (isNarrow) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          children: [
            search,
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: dateBtn),
                const SizedBox(width: 8),
                filterBtn,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(flex: 3, child: search),
          const SizedBox(width: 8),
          dateBtn,
          const SizedBox(width: 8),
          filterBtn,
        ],
      ),
    );
  }

  bool get _filterActive =>
      _sortField != 'date' || _sortAscending || _hasLocalFilter;

  bool get _hasLocalFilter =>
      _search.trim().isNotEmpty || _fromDate != null || _toDate != null;

  String _rangeLabel() {
    final df = DateFormat('dd MMM yyyy');
    if (_fromDate == null && _toDate == null) return 'Date range';
    final from = _fromDate == null ? '…' : df.format(_fromDate!);
    final to = _toDate == null ? '…' : df.format(_toDate!);
    return '$from – $to';
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _fromDate != null && _toDate != null
          ? DateTimeRange(start: _fromDate!, end: _toDate!)
          : null,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fromDate = picked.start;
      _toDate = picked.end;
    });
  }

  String _sortLabel(String field) => switch (field) {
        'vendor' => 'Vendor name',
        'total' => 'Total amount',
        _ => 'Order date',
      };

  Future<void> _showFilterDialog() async {
    var field = _sortField;
    var asc = _sortAscending;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Sort & filter'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sort by'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in const ['date', 'vendor', 'total'])
                    ChoiceChip(
                      label: Text(_sortLabel(f)),
                      selected: field == f,
                      onSelected: (_) => setDialogState(() => field = f),
                    ),
                ],
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Ascending'),
                value: asc,
                onChanged: (v) => setDialogState(() => asc = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(_clearLocalFilters);
                Navigator.pop(ctx, false);
              },
              child: const Text('Clear all'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _sortField = field;
        _sortAscending = asc;
      });
    }
  }

  void _clearLocalFilters() {
    _searchCtrl.clear();
    _search = '';
    _fromDate = null;
    _toDate = null;
    _sortField = 'date';
    _sortAscending = false;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _matchesRange(DateTime d) {
    final day = _day(d);
    if (_fromDate != null && day.isBefore(_day(_fromDate!))) return false;
    if (_toDate != null && day.isAfter(_day(_toDate!))) return false;
    return true;
  }

  /// Presentation-only filtering/sorting over the loaded page rows.
  List<PurchaseOrder> get _visible {
    final q = _search.trim().toLowerCase();
    final rows = _orders.where((o) {
      if (q.isNotEmpty) {
        final num = (o.orderNumber ?? o.id).toLowerCase();
        if (!o.vendorName.toLowerCase().contains(q) && !num.contains(q)) {
          return false;
        }
      }
      return _matchesRange(o.date);
    }).toList();
    rows.sort((a, b) {
      final int c;
      switch (_sortField) {
        case 'vendor':
          c = a.vendorName.toLowerCase().compareTo(b.vendorName.toLowerCase());
          break;
        case 'total':
          c = a.totalAmount.compareTo(b.totalAmount);
          break;
        default:
          c = a.date.compareTo(b.date);
      }
      return _sortAscending ? c : -c;
    });
    return rows;
  }

  void _toggleSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == 'vendor';
      }
    });
  }

  Widget _sortHeader(String label, String field) {
    final theme = Theme.of(context);
    final active = _sortField == field;
    return InkWell(
      onTap: () => _toggleSort(field),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            active
                ? (_sortAscending ? Icons.arrow_upward : Icons.arrow_downward)
                : Icons.unfold_more,
            size: 14,
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Text(
            '${_selectedIds.length} selected',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _selectedIds.clear()),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  /// Wide sortable table with checkboxes, status pills and a ⋯ menu.
  /// Tapping a row opens the same detail dialog as the narrow cards.
  Widget _table() {
    final theme = Theme.of(context);
    final rows = _visible;
    final pageIds = rows.map((o) => o.id).toSet();
    final selInPage = _selectedIds.intersection(pageIds).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Checkbox(
                      tristate: true,
                      visualDensity: VisualDensity.compact,
                      value: rows.isEmpty
                          ? false
                          : (selInPage == rows.length
                              ? true
                              : (selInPage == 0 ? false : null)),
                      onChanged: (_) => setState(() {
                        if (selInPage == rows.length) {
                          _selectedIds.removeAll(pageIds);
                        } else {
                          _selectedIds.addAll(pageIds);
                        }
                      }),
                    ),
                    const SizedBox(
                      width: 150,
                      child: Text(
                        'ORDER',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(width: 104, child: _sortHeader('DATE', 'date')),
                    const SizedBox(
                      width: 64,
                      child: Text(
                        'ITEMS',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(width: 128, child: _sortHeader('TOTAL', 'total')),
                    const SizedBox(
                      width: 120,
                      child: Text(
                        'STATUS',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (final order in rows) ...[
                InkWell(
                  onTap: () => _showOrderDetail(order),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Checkbox(
                          visualDensity: VisualDensity.compact,
                          value: _selectedIds.contains(order.id),
                          onChanged: (_) => setState(() {
                            if (_selectedIds.contains(order.id)) {
                              _selectedIds.remove(order.id);
                            } else {
                              _selectedIds.add(order.id);
                            }
                          }),
                        ),
                        SizedBox(
                          width: 150,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'PO #${order.orderNumber ?? order.id}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              Text(
                                order.vendorName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 104,
                          child: Text(
                            DateFormat('dd MMM yyyy').format(order.date),
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                        SizedBox(
                          width: 64,
                          child: Text(
                            '${order.items.length}',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                        SizedBox(
                          width: 128,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppMoney(
                                order.totalAmount,
                                currencySymbol: order.currencySymbol,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              if (order.outstandingBalance > 0)
                                Text(
                                  'Due ${order.currencySymbol} ${order.outstandingBalance.toStringAsFixed(2)}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.orange),
                                ),
                            ],
                          ),
                        ),
                        SizedBox(width: 120, child: _statusPill(order.status)),
                        SizedBox(width: 48, child: _orderMenu(order)),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusPill(String status) {
    final (Color color, IconData icon) = switch (status) {
      'confirmed' => (Colors.blue, Icons.check_circle),
      'received' => (Colors.green, Icons.done_all),
      'cancelled' => (Colors.red, Icons.cancel),
      _ => (Colors.orange, Icons.edit_note),
    };
    final label = status[0].toUpperCase() + status.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Row ⋯ menu — the same actions as the detail dialog (confirm, receive,
  /// prefilled bill) so wide and narrow stay identical.
  Widget _orderMenu(PurchaseOrder order) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (v) => _orderAction(order, v),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'view', child: Text('View details')),
        if (order.status != 'cancelled')
          const PopupMenuItem(value: 'bill', child: Text('Create Bill')),
        if (order.status == 'draft')
          const PopupMenuItem(value: 'confirm', child: Text('Confirm')),
        if (order.status == 'confirmed')
          const PopupMenuItem(value: 'receive', child: Text('Mark Received')),
      ],
    );
  }

  Future<void> _orderAction(PurchaseOrder order, String action) async {
    switch (action) {
      case 'view':
        _showOrderDetail(order);
        break;
      case 'bill':
        _openPrefilledBill(order);
        break;
      case 'confirm':
        await PurchaseOrderService.updateStatus(order.id, 'confirmed');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Purchase order confirmed.'),
            backgroundColor: Colors.green,
          ),
        );
        _loadData();
        break;
      case 'receive':
        await PurchaseOrderService.markAsReceived(order.id);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Purchase order marked as received.'),
            backgroundColor: Colors.green,
          ),
        );
        _loadData();
        break;
    }
  }

  Widget _cardList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _visible.length,
      itemBuilder: (context, index) => _buildOrderCard(_visible[index]),
    );
  }

  /// "Showing x–y of N" pagination footer over the existing server-side
  /// paging. While a local search/date filter narrows the page rows, the
  /// footer reports the in-memory match instead.
  Widget _footer() {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rangeText = _hasLocalFilter
        ? 'Showing ${_visible.length} of ${_orders.length} on this page'
        : 'Showing ${_orders.isEmpty ? 0 : _currentPage * _pageSize + 1}–${_currentPage * _pageSize + _orders.length} of $_totalCount';
    final totalPages = (_totalCount / _pageSize).ceil().clamp(1, 1 << 30);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(rangeText,
                  overflow: TextOverflow.ellipsis, style: small),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed: _currentPage > 0
                ? () {
                    setState(() => _currentPage--);
                    _loadData();
                  }
                : null,
          ),
          Text('Page ${_currentPage + 1} of $totalPages', style: small),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: (_currentPage + 1) * _pageSize < _totalCount
                ? () {
                    setState(() => _currentPage++);
                    _loadData();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return AppEmptyState(
      icon: Icons.shopping_cart_outlined,
      title: _filterStatus == null
          ? 'No purchase orders yet.'
          : 'No purchase orders match this filter.',
      subtitle: 'Create an order to track expected stock.',
      action: FilledButton.tonal(
        onPressed: () => _showCreateOrderDialog(),
        child: const Text('New Purchase Order'),
      ),
    );
  }

  Widget _noMatchState() {
    return AppEmptyState(
      icon: Icons.search_off,
      title: 'No purchase orders match your filters.',
      subtitle: 'Try a different search or date range.',
      action: FilledButton.tonal(
        onPressed: () => setState(_clearLocalFilters),
        child: const Text('Clear filters'),
      ),
    );
  }

  Widget _buildOrderCard(PurchaseOrder order) {
    final colorScheme = Theme.of(context).colorScheme;
    final currencyFormat =
        NumberFormat.currency(symbol: order.currencySymbol, decimalDigits: 2);

    Color statusColor;
    IconData statusIcon;
    switch (order.status) {
      case 'confirmed':
        statusColor = Colors.blue;
        statusIcon = Icons.check_circle;
        break;
      case 'received':
        statusColor = Colors.green;
        statusIcon = Icons.done_all;
        break;
      case 'cancelled':
        statusColor = Colors.red;
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = Colors.orange;
        statusIcon = Icons.edit_note;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: () => _showOrderDetail(order),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 400;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PO #${order.orderNumber ?? order.id}',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            order.vendorName,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, size: 14, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            order.status[0].toUpperCase() +
                                order.status.substring(1),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (isWide)
                  Row(
                    children: [
                      _buildInfoChip(Icons.calendar_today,
                          DateFormat('dd MMM yyyy').format(order.date)),
                      const SizedBox(width: 12),
                      _buildInfoChip(
                          Icons.inventory_2, '${order.items.length} items'),
                      const Spacer(),
                      AppMoney(
                        order.totalAmount,
                        currencySymbol: order.currencySymbol,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                      ),
                    ],
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          _buildInfoChip(Icons.calendar_today,
                              DateFormat('dd MMM yyyy').format(order.date)),
                          _buildInfoChip(
                              Icons.inventory_2, '${order.items.length} items'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AppMoney(
                        order.totalAmount,
                        currencySymbol: order.currencySymbol,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                      ),
                    ],
                  ),
                if (order.outstandingBalance > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.warning_amber,
                          size: 14, color: Colors.orange),
                      const SizedBox(width: 4),
                      Text(
                        'Outstanding: ${currencyFormat.format(order.outstandingBalance)}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _purchaseContext(BuildContext context, PurchaseOrder? order,
      List<PurchaseOrderItem> items, String symbol) {
    final expected = items.fold<double>(0, (sum, item) => sum + item.quantity);
    final received = order?.status == 'received' ? expected : 0.0;
    final balance = order?.outstandingBalance ?? 0.0;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 24, runSpacing: 12, children: [
          _metric('Vendor', order?.vendorName ?? 'New vendor'),
          _metric('Currency', symbol),
          _metric('Expected qty', expected.toStringAsFixed(2)),
          _metric('Received qty', received.toStringAsFixed(2)),
          _metric('Outstanding qty', (expected - received).toStringAsFixed(2)),
          _metric('Vendor balance', '$symbol ${balance.toStringAsFixed(2)}'),
        ]),
      ),
    );
  }

  Widget _metric(String label, String value) => SizedBox(
        width: 165,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  void _showCreateOrderDialog() {
    _showOrderDialog();
  }

  Future<void> _showOrderDialog({PurchaseOrder? existingOrder}) async {
    final vendorController =
        TextEditingController(text: existingOrder?.vendorName ?? '');
    final notesController =
        TextEditingController(text: existingOrder?.notes ?? '');
    DateTime orderDate = existingOrder?.date ?? DateTime.now();
    DateTime? expectedDate = existingOrder?.expectedDate;
    String status = existingOrder?.status ?? 'draft';

    List<PurchaseOrderItem> items = List.from(existingOrder?.items ?? []);

    // Load products for selection
    final products = await ProductService.getAllProducts();
    final configuredCurrency = await SettingsService.getCurrency();
    final defaultPricesIncludeTax =
        await SettingsService.getDefaultPriceIncludesTax();
    final workspaceCurrency =
        existingOrder?.currencySymbol ?? configuredCurrency.symbol;
    // Document-level GST toggle: existing orders keep their stored flag,
    // new orders start from the global default. Applies to all lines.
    bool pricesIncludeTax =
        existingOrder?.priceIncludesTax ?? defaultPricesIncludeTax;

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
                title: Text(existingOrder == null
                    ? 'Create Purchase Order'
                    : 'Edit Purchase Order')),
            body: DocumentEditorShell(
              stateLabel:
                  existingOrder == null ? 'Draft workspace' : 'Editing draft',
              validationErrors: const [],
              editor: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _purchaseContext(
                            context, existingOrder, items, workspaceCurrency),
                        Text('Order details',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        TextField(
                          controller: vendorController,
                          decoration: const InputDecoration(
                            labelText: 'Vendor Name *',
                            hintText: 'e.g. ABC Suppliers',
                          ),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Order Date'),
                          subtitle:
                              Text(DateFormat('dd MMM yyyy').format(orderDate)),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: orderDate,
                              firstDate: DateTime(2020),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null)
                              setDialogState(() => orderDate = picked);
                          },
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Expected Date (optional)'),
                          subtitle: Text(expectedDate != null
                              ? DateFormat('dd MMM yyyy').format(expectedDate!)
                              : 'Not set'),
                          trailing: const Icon(Icons.calendar_today),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: expectedDate ??
                                  DateTime.now().add(const Duration(days: 7)),
                              firstDate: DateTime.now(),
                              lastDate:
                                  DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null)
                              setDialogState(() => expectedDate = picked);
                          },
                        ),
                        if (existingOrder != null) ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: status,
                            decoration:
                                const InputDecoration(labelText: 'Status'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'draft', child: Text('Draft')),
                              DropdownMenuItem(
                                  value: 'confirmed', child: Text('Confirmed')),
                              DropdownMenuItem(
                                  value: 'received', child: Text('Received')),
                              DropdownMenuItem(
                                  value: 'cancelled', child: Text('Cancelled')),
                            ],
                            onChanged: (v) =>
                                setDialogState(() => status = v ?? 'draft'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: notesController,
                          decoration: const InputDecoration(
                            labelText: 'Notes',
                            hintText: 'Any additional notes',
                          ),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 16),
                        const Divider(height: 32),
                        // Items section
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Items (${items.length})',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                final item = await _showAddItemDialog(
                                    products, workspaceCurrency);
                                if (item != null) {
                                  setDialogState(() => items.add(item));
                                }
                              },
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add Item'),
                            ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment<bool>(
                                  value: false, label: Text('Excl GST')),
                              ButtonSegment<bool>(
                                  value: true, label: Text('Incl GST')),
                            ],
                            selected: {pricesIncludeTax},
                            onSelectionChanged: (selection) => setDialogState(
                                () => pricesIncludeTax = selection.first),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (items.isNotEmpty)
                          ...items.asMap().entries.map((entry) {
                            final i = entry.key;
                            final item = entry.value;
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(item.productName),
                              subtitle: Text(
                                  '${item.quantity} × $workspaceCurrency${item.pricePerUnit.toStringAsFixed(2)}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '$workspaceCurrency${item.totalFor(pricesIncludeTax).toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () =>
                                        setDialogState(() => items.removeAt(i)),
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),
              ),
              actions: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (vendorController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Vendor name is required')),
                        );
                        return;
                      }
                      Navigator.pop(context, true);
                    },
                    child: Text(existingOrder == null ? 'Create' : 'Save'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );

    if (result == true) {
      // Trial/licence gate: new orders only; edits to existing stay allowed.
      if (existingOrder == null && !await LicenseGate.canCreate(context)) {
        return;
      }
      final totalAmount =
          items.fold(0.0, (sum, item) => sum + item.totalFor(pricesIncludeTax));
      final id =
          existingOrder?.id ?? await PurchaseOrderService.generateNextId();
      final orderNumber = existingOrder?.orderNumber ??
          await PurchaseOrderService.generateNextOrderNumber();

      final order = PurchaseOrder(
        id: id,
        orderNumber: orderNumber,
        vendorName: vendorController.text,
        items: items,
        date: orderDate,
        expectedDate: expectedDate,
        status: status,
        totalAmount: totalAmount,
        amountPaid: existingOrder?.amountPaid ?? 0,
        priceIncludesTax: pricesIncludeTax,
        notes: notesController.text,
        currencyCode: existingOrder?.currencyCode ?? configuredCurrency.code,
        currencySymbol:
            existingOrder?.currencySymbol ?? configuredCurrency.symbol,
      );

      if (existingOrder == null) {
        await PurchaseOrderService.insertPurchaseOrder(order, items);
      } else {
        await PurchaseOrderService.updatePurchaseOrder(order, items: items);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(existingOrder == null
              ? 'Purchase order created.'
              : 'Purchase order updated.'),
          backgroundColor: Colors.green,
        ),
      );
      _loadData();
    }
  }

  Future<PurchaseOrderItem?> _showAddItemDialog(
      List<Product> products, String currencySymbol) async {
    Product? selectedProduct;
    final qtyController = TextEditingController(text: '1');
    final priceController = TextEditingController();

    return showDialog<PurchaseOrderItem>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Item'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Product>(
                decoration: const InputDecoration(labelText: 'Product *'),
                items: products
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (p) {
                  selectedProduct = p;
                  if (p != null) {
                    priceController.text = p.purchasePrice > 0
                        ? p.purchasePrice.toStringAsFixed(2)
                        : p.price.toStringAsFixed(2);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qtyController,
                decoration: const InputDecoration(labelText: 'Quantity *'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                decoration: InputDecoration(
                  labelText: 'Price per Unit *',
                  prefixText: '$currencySymbol ',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (selectedProduct == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Select a product')),
                );
                return;
              }
              final qty = double.tryParse(qtyController.text) ?? 1;
              final price = double.tryParse(priceController.text) ?? 0;
              Navigator.pop(
                  context,
                  PurchaseOrderItem(
                    id: 'poi-${DateTime.now().millisecondsSinceEpoch}',
                    productId: selectedProduct!.id,
                    productName: selectedProduct!.name,
                    quantity: qty,
                    pricePerUnit: price,
                    taxRate: selectedProduct!.tax_rate.toDouble(),
                  ));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _showOrderDetail(PurchaseOrder order) async {
    final parentContext = context;
    final currencyFormat =
        NumberFormat.currency(symbol: order.currencySymbol, decimalDigits: 2);
    final expectedQty =
        order.items.fold<double>(0, (sum, item) => sum + item.quantity);
    final receivedQty = order.status == 'received' ? expectedQty : 0.0;

    await showDialog(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(title: Text('PO #${order.orderNumber ?? order.id}')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Vendor: ${order.vendorName}'),
                Text('Date: ${DateFormat('dd MMM yyyy').format(order.date)}'),
                if (order.expectedDate != null)
                  Text(
                      'Expected: ${DateFormat('dd MMM yyyy').format(order.expectedDate!)}'),
                Text(
                    'Status: ${order.status[0].toUpperCase()}${order.status.substring(1)}'),
                const SizedBox(height: 4),
                Text(
                  'Confirm the order, mark it received, then create a bill for the supplier invoice.',
                  style: Theme.of(parentContext).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(parentContext).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                _purchaseContext(
                    context, order, order.items, order.currencySymbol),
                Text('Expected quantity: ${expectedQty.toStringAsFixed(2)}'),
                Text('Received quantity: ${receivedQty.toStringAsFixed(2)}'),
                Text(
                    'Outstanding quantity: ${(expectedQty - receivedQty).toStringAsFixed(2)}'),
                const Divider(),
                ...order.items.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                              child: Text(
                                  '${item.productName} (${item.quantity})')),
                          Text(currencyFormat
                              .format(item.totalFor(order.priceIncludesTax))),
                        ],
                      ),
                    )),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Total:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(currencyFormat.format(order.totalAmount),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                if (order.amountPaid > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Paid:'),
                      Text(currencyFormat.format(order.amountPaid)),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Outstanding:',
                          style: TextStyle(color: Colors.orange)),
                      Text(
                        currencyFormat.format(order.outstandingBalance),
                        style: const TextStyle(
                            color: Colors.orange, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              if (order.status != 'cancelled')
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.pop(context);
                    _openPrefilledBill(order);
                  },
                  child: const Text('Create Bill'),
                ),
              if (order.status == 'draft')
                FilledButton(
                  onPressed: () async {
                    await PurchaseOrderService.updateStatus(
                        order.id, 'confirmed');
                    if (!parentContext.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      const SnackBar(
                        content: Text('Purchase order confirmed.'),
                        backgroundColor: Colors.green,
                      ),
                    );
                    _loadData();
                  },
                  child: const Text('Confirm'),
                ),
              if (order.status == 'confirmed')
                FilledButton(
                  onPressed: () async {
                    // Idempotent: the service re-checks status inside the same
                    // transaction that adds stock, so a double-tap (or a stale
                    // detail view) can never add stock twice. Bills booked
                    // separately for the same goods would still double-add —
                    // bills carry no po_id (no schema change, stays db v51).
                    await PurchaseOrderService.markAsReceived(order.id);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    if (!parentContext.mounted) return;
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      const SnackBar(
                        content: Text('Purchase order marked as received.'),
                        backgroundColor: Colors.green,
                      ),
                    );
                    _loadData();
                  },
                  child: const Text('Mark Received'),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _openPrefilledBill(PurchaseOrder order) async {
    final user = widget.user;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'To create a bill for this order, open Purchase Bills — supplier and items are ready to copy.'),
        ),
      );
      return;
    }
    // Prefill-only: supplier + items + currency. The bill form seeds its
    // controllers from this object and always saves via the insert path.
    final prefill = PurchaseBill(
      id: order.id,
      supplierName: order.vendorName,
      date: DateTime.now(),
      currencyCode: order.currencyCode,
      currencySymbol: order.currencySymbol,
      priceIncludesTax: order.priceIncludesTax,
      notes: order.notes ?? '',
      items: order.items
          .map((i) => PurchaseBillItem(
                id: i.id,
                purchaseBillId: order.id,
                productName: i.productName,
                quantity: i.quantity,
                rate: i.pricePerUnit,
                taxRate: i.taxRate,
                discount: i.discount,
              ))
          .toList(),
    );
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PurchaseBillFormScreen(user: user, prefill: prefill),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Purchase bill created from order.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
