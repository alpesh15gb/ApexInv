import 'package:flutter/material.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/widgets/app/app.dart';

class PaymentOutScreen extends StatefulWidget {
  const PaymentOutScreen({super.key});

  @override
  State<PaymentOutScreen> createState() => _PaymentOutScreenState();
}

class _PaymentOutScreenState extends State<PaymentOutScreen> {
  List<PurchaseBill> _bills = const [];
  List<FinancialAccount> _accounts = const [];
  final Map<String, TextEditingController> _allocations = {};
  String? _supplier;
  String _method = 'Bank Transfer';
  String? _accountId;
  final _notes = TextEditingController();
  final _chequeNumber = TextEditingController();
  DateTime _date = DateTime.now();
  DateTime _chequeDate = DateTime.now();
  bool _loading = true;
  bool _saving = false;
  // Presentation-only state: status chips, search, bill date range,
  // sorting, selection and paging are applied in-memory over the loaded
  // outstanding bills. Supplier filter, allocations, posting, navigation
  // and accounting logic are untouched.
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  String _statusFilter = 'all'; // 'all' | 'unpaid' | 'partial' | 'overdue'
  DateTime? _fromDate;
  DateTime? _toDate;
  String _sortField = 'date'; // 'date' | 'bill' | 'outstanding'
  bool _sortAscending = false;
  final Set<String> _selectedIds = {};
  int _currentPage = 0;
  final int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _allocations.values) {
      c.dispose();
    }
    _notes.dispose();
    _chequeNumber.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bills = (await PurchaseBillService.getBills())
        .where((b) => b.outstanding > 0.005)
        .toList();
    final accounts = await AccountingService.getAccounts();
    if (!mounted) return;
    for (final c in _allocations.values) {
      c.dispose();
    }
    _allocations.clear();
    for (final bill in bills) {
      _allocations[bill.id] = TextEditingController();
    }
    final suppliers = bills.map((b) => b.supplierName).toSet();
    setState(() {
      _bills = bills;
      _accounts = accounts;
      if (_supplier == null || !suppliers.contains(_supplier)) {
        _supplier = suppliers.isEmpty ? null : suppliers.first;
      }
      _chooseDefaultAccount();
      _loading = false;
      _selectedIds.removeWhere((id) => !_bills.any((b) => b.id == id));
      final maxPage = (_display.length / _pageSize).ceil().clamp(1, 1 << 30);
      if (_currentPage >= maxPage) _currentPage = maxPage - 1;
    });
  }

  void _chooseDefaultAccount() {
    final type = _method == 'Cash' ? 'cash' : 'bank';
    final matching = _accounts.where((a) => a.type == type).toList();
    if (matching.isNotEmpty && !matching.any((a) => a.id == _accountId)) {
      _accountId = matching.first.id;
    }
  }

  List<PurchaseBill> get _visible =>
      _bills.where((b) => b.supplierName == _supplier).toList();

  double get _allocated => _visible.fold(
      0,
      (sum, bill) =>
          sum +
          (double.tryParse(_allocations[bill.id]?.text.trim() ?? '') ?? 0));

  void _autoAllocate() {
    for (final bill in _visible) {
      _allocations[bill.id]?.text = bill.outstanding.toStringAsFixed(2);
    }
    setState(() {});
  }

  /// Bill payment status mirroring the row derivation below, so chips,
  /// pills and rows always agree.
  String _billStatus(PurchaseBill bill) {
    if (bill.dueDate != null && bill.dueDate!.isBefore(DateTime.now())) {
      return 'overdue';
    }
    if (bill.amountPaid > 0.005) return 'partial';
    return 'unpaid';
  }

  String _statusLabel(String status) => switch (status) {
        'partial' => 'Partially paid',
        'overdue' => 'Overdue',
        'unpaid' => 'Unpaid',
        _ => 'All',
      };

  /// LIVE chip counts aggregated in-memory from the loaded supplier bills.
  Map<String, int> get _statusCounts {
    final counts = {'unpaid': 0, 'partial': 0, 'overdue': 0};
    for (final bill in _visible) {
      final s = _billStatus(bill);
      counts[s] = counts[s]! + 1;
    }
    return counts;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _matchesRange(DateTime d) {
    final day = _day(d);
    if (_fromDate != null && day.isBefore(_day(_fromDate!))) return false;
    if (_toDate != null && day.isAfter(_day(_toDate!))) return false;
    return true;
  }

  bool get _hasLocalFilter =>
      _search.trim().isNotEmpty ||
      _fromDate != null ||
      _toDate != null ||
      _statusFilter != 'all';

  /// Presentation-only filtering/sorting over the supplier-filtered bills.
  /// [_visible] (and therefore allocations, totals and posting) is untouched.
  List<PurchaseBill> get _display {
    final q = _search.trim().toLowerCase();
    final rows = _visible.where((bill) {
      if (_statusFilter != 'all' && _billStatus(bill) != _statusFilter) {
        return false;
      }
      if (q.isNotEmpty) {
        final label = bill.billNumber?.isNotEmpty == true
            ? 'bill #${bill.billNumber}'
            : 'bill ${bill.id}';
        if (!label.toLowerCase().contains(q) &&
            !bill.supplierName.toLowerCase().contains(q)) {
          return false;
        }
      }
      return _matchesRange(bill.date);
    }).toList();
    rows.sort((a, b) {
      final int c;
      switch (_sortField) {
        case 'bill':
          c = (a.billNumber ?? a.id).compareTo(b.billNumber ?? b.id);
          break;
        case 'outstanding':
          c = a.outstanding.compareTo(b.outstanding);
          break;
        default:
          c = a.date.compareTo(b.date);
      }
      return _sortAscending ? c : -c;
    });
    return rows;
  }

  List<PurchaseBill> get _pageRows {
    final start = _currentPage * _pageSize;
    if (start >= _display.length) return const [];
    final end = (start + _pageSize).clamp(start, _display.length);
    return _display.sublist(start, end);
  }

  void _resetPage() => _currentPage = 0;

  void _clearLocalFilters() {
    _searchCtrl.clear();
    _search = '';
    _statusFilter = 'all';
    _fromDate = null;
    _toDate = null;
    _sortField = 'date';
    _sortAscending = false;
    _resetPage();
  }

  /// Per-row allocation shortcuts. These only edit the amount text fields —
  /// the posting path in _save is unchanged.
  void _allocateFull(PurchaseBill bill) {
    _allocations[bill.id]?.text = bill.outstanding.toStringAsFixed(2);
    setState(() {});
  }

  void _clearAllocation(PurchaseBill bill) {
    _allocations[bill.id]?.clear();
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    final raw = _visible
        .map((bill) => (
              bill: bill,
              amount:
                  double.tryParse(_allocations[bill.id]?.text.trim() ?? '') ?? 0
            ))
        .toList();
    if (raw.any((a) => !a.amount.isFinite)) {
      _error('Enter valid finite amounts for each bill.');
      return;
    }
    final selected = raw.where((a) => a.amount > 0).toList();
    if (selected.isEmpty) {
      _error('Enter an allocation for at least one bill.');
      return;
    }
    setState(() => _saving = true);
    try {
      if (_method == 'Check') {
        if (selected.length != 1) {
          throw StateError(
              'One cheque can be linked to one bill in this version');
        }
        await PurchaseBillService.recordPayment(
            selected.first.bill.id, selected.first.amount,
            datePaid: _date,
            paymentMethod: _method,
            accountId: _accountId,
            chequeNumber: _chequeNumber.text.trim(),
            chequeDate: _chequeDate,
            notes: _notes.text.trim());
      } else {
        await PurchaseBillService.recordPaymentBatch(
            allocations: selected,
            datePaid: _date,
            paymentMethod: _method,
            accountId: _accountId,
            notes: _notes.text.trim());
      }
      if (!mounted) return;
      final currencySymbol = selected.first.bill.currencySymbol;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Payment posted for ${selected.length} '
              'bill${selected.length == 1 ? '' : 's'}: $currencySymbol '
              '${_allocated.toStringAsFixed(2)}.'),
          backgroundColor: Colors.green));
      _notes.clear();
      _chequeNumber.clear();
      await _load();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('StateError: ', '')),
        backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = _bills.map((b) => b.supplierName).toSet().toList()
      ..sort();
    final accountType = _method == 'Cash' ? 'cash' : 'bank';
    final accountChoices =
        _accounts.where((a) => a.type == accountType).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Out'), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        const SizedBox(width: 8),
      ]),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < Breakpoints.compactMax;
          if (_loading) return const AppLoadingState();
          if (_bills.isEmpty) return _emptyState();
          return _content(narrow, suppliers, accountChoices);
        },
      ),
      floatingActionButton:
          MediaQuery.sizeOf(context).width < Breakpoints.compactMax &&
                  !_loading &&
                  _bills.isNotEmpty
              ? FloatingActionButton.extended(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(_saving ? 'Posting…' : 'Post'),
                )
              : null,
    );
  }

  Widget _emptyState() {
    return AppEmptyState(
      icon: Icons.receipt_long_outlined,
      title: 'No outstanding purchase bills.',
      subtitle:
          'All purchase bills are paid. New bills will appear here for payment.',
      action: FilledButton.tonal(
        onPressed: _load,
        child: const Text('Refresh'),
      ),
    );
  }

  /// Title + subtitle + primary post button (top-right on wide screens;
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
                'Payment Out',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                'Allocate an amount per bill, then post the payment.',
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
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.payments_outlined),
            label: Text(_saving ? 'Posting…' : 'Post payment'),
          ),
        ],
      ],
    );
  }

  /// Status filter chips with LIVE counts aggregated in-memory from the
  /// loaded supplier bills. Filtering itself is in-memory — no query change.
  Widget _statusChips() {
    final counts = _statusCounts;
    final options = ['all', 'unpaid', 'partial', 'overdue'];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final status = options[i];
          final count =
              status == 'all' ? _visible.length : (counts[status] ?? 0);
          return FilterChip(
            label: Text('${_statusLabel(status)} ($count)'),
            selected: _statusFilter == status,
            onSelected: (_) => setState(() {
              _statusFilter = status;
              _resetPage();
            }),
          );
        },
      ),
    );
  }

  /// Search + bill date-range + Filter row (all in-memory over loaded bills).
  Widget _paymentFilterRow() {
    final search = AppSearchField(
      controller: _searchCtrl,
      hintText: 'Search bill no',
      onChanged: (v) => setState(() {
        _search = v;
        _resetPage();
      }),
      onClear: () => setState(() {
        _searchCtrl.clear();
        _search = '';
        _resetPage();
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < Breakpoints.compactMax) {
            return Column(
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
            );
          }
          return Row(
            children: [
              Expanded(flex: 3, child: search),
              const SizedBox(width: 8),
              dateBtn,
              const SizedBox(width: 8),
              filterBtn,
            ],
          );
        },
      ),
    );
  }

  bool get _filterActive =>
      _sortField != 'date' || _sortAscending || _hasLocalFilter;

  String _rangeLabel() {
    if (_fromDate == null && _toDate == null) return 'Bill date range';
    String fmt(DateTime? d) =>
        d == null ? '…' : d.toLocal().toString().split(' ').first;
    return '${fmt(_fromDate)} – ${fmt(_toDate)}';
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
      _resetPage();
    });
  }

  String _sortLabel(String field) => switch (field) {
        'bill' => 'Bill number',
        'outstanding' => 'Outstanding',
        _ => 'Bill date',
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
                  for (final f in const ['date', 'bill', 'outstanding'])
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
        _resetPage();
      });
    }
  }

  void _toggleSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == 'bill';
      }
      _resetPage();
    });
  }

  Widget _sortHeader(String label, String field, {bool alignEnd = false}) {
    final theme = Theme.of(context);
    final active = _sortField == field;
    return InkWell(
      onTap: () => _toggleSort(field),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment:
            alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
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

  Widget _content(bool narrow, List<String> suppliers,
      List<FinancialAccount> accountChoices) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: _header(narrow),
      ),
      const SizedBox(height: 12),
      Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(builder: (context, constraints) {
            final fields = <Widget>[
              DropdownButtonFormField<String>(
                  value: _supplier,
                  decoration: const InputDecoration(
                      labelText: 'Supplier', border: OutlineInputBorder()),
                  items: suppliers
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) => setState(() => _supplier = v)),
              DropdownButtonFormField<String>(
                  value: _method,
                  decoration: const InputDecoration(
                      labelText: 'Method', border: OutlineInputBorder()),
                  items: const ['Cash', 'Bank Transfer', 'Online', 'Check']
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() {
                        _method = v!;
                        _chooseDefaultAccount();
                      })),
              DropdownButtonFormField<String>(
                  value: accountChoices.any((a) => a.id == _accountId)
                      ? _accountId
                      : null,
                  decoration: const InputDecoration(
                      labelText: 'Pay from', border: OutlineInputBorder()),
                  items: accountChoices
                      .map((a) =>
                          DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _accountId = v)),
              InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2000),
                        lastDate:
                            DateTime.now().add(const Duration(days: 365)));
                    if (picked != null) setState(() => _date = picked);
                  },
                  child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Payment date',
                          border: OutlineInputBorder()),
                      child:
                          Text(_date.toLocal().toString().split(' ').first))),
            ];
            if (constraints.maxWidth < Breakpoints.compactMax)
              return Column(
                  children: fields
                      .map((w) => Padding(
                          padding: const EdgeInsets.only(bottom: 10), child: w))
                      .toList());
            return Row(
                children: fields
                    .map((w) => Expanded(
                        child: Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: w)))
                    .toList());
          })),
      if (_method == 'Check')
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: _chequeNumber,
                      decoration: const InputDecoration(
                          labelText: 'Cheque number',
                          border: OutlineInputBorder()))),
              const SizedBox(width: 10),
              Expanded(
                  child: ListTile(
                      title: const Text('Cheque date'),
                      subtitle: Text(
                          _chequeDate.toLocal().toString().split(' ').first),
                      onTap: () async {
                        final picked = await showDatePicker(
                            context: context,
                            initialDate: _chequeDate,
                            firstDate: DateTime(2000),
                            lastDate:
                                DateTime.now().add(const Duration(days: 730)));
                        if (picked != null)
                          setState(() => _chequeDate = picked);
                      })),
            ])),
      _statusChips(),
      _paymentFilterRow(),
      if (_selectedIds.isNotEmpty) _selectionBar(),
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Text('Open bills for $_supplier (${_visible.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(
                onPressed: _autoAllocate, child: const Text('Allocate all')),
          ])),
      Expanded(
          child: _display.isEmpty
              ? _noMatchState()
              : narrow
                  ? _cardList()
                  : _table()),
      if (_display.isNotEmpty) _footer(),
      Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _notes,
                    decoration: const InputDecoration(
                        labelText: 'Reference / notes',
                        border: OutlineInputBorder()))),
            const SizedBox(width: 16),
            Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Allocated'),
                  AppMoney(_allocated,
                      currencySymbol:
                          _visible.isEmpty ? '' : _visible.first.currencySymbol,
                      bold: true),
                ]),
            const SizedBox(width: 16),
            FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.payments_outlined),
                label: Text(_saving ? 'Posting…' : 'Post payment')),
          ])),
    ]);
  }

  String _billTitle(PurchaseBill bill) => bill.billNumber?.isNotEmpty == true
      ? 'Bill #${bill.billNumber}'
      : 'Bill ${bill.id}';

  Widget _noMatchState() {
    return AppEmptyState(
      icon: Icons.search_off,
      title: 'No bills match your filters.',
      subtitle: 'Try a different search, status or date range.',
      action: FilledButton.tonal(
        onPressed: () => setState(_clearLocalFilters),
        child: const Text('Clear filters'),
      ),
    );
  }

  /// Narrow card layout reusing the existing row content (title, date +
  /// outstanding, status, per-bill Pay field) unchanged.
  Widget _cardList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _pageRows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final bill = _pageRows[index];
        final status = _billStatus(bill);
        final Color statusColor =
            status == 'overdue' ? Colors.red : Colors.orange;
        return AppCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            title: Text(_billTitle(bill)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${bill.date.toLocal().toString().split(' ').first} '
                    '• Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}'),
                const SizedBox(height: 2),
                Text(
                  _statusLabel(status),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: statusColor),
                ),
              ],
            ),
            trailing: _payField(bill, width: 150),
          ),
        );
      },
    );
  }

  /// Wide sortable table with checkboxes, status pills, per-bill Pay fields
  /// and a ⋯ menu. Posting still reads the same allocation controllers.
  Widget _table() {
    final theme = Theme.of(context);
    final rows = _pageRows;
    final pageIds = rows.map((b) => b.id).toSet();
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
                    const Expanded(
                      child: Text(
                        'BILL',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(
                        width: 130,
                        child: _sortHeader('OUTSTANDING', 'outstanding',
                            alignEnd: true)),
                    const SizedBox(
                      width: 120,
                      child: Text(
                        'STATUS',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(
                      width: 170,
                      child: Text(
                        'PAY',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (final bill in rows) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Checkbox(
                        visualDensity: VisualDensity.compact,
                        value: _selectedIds.contains(bill.id),
                        onChanged: (_) => setState(() {
                          if (_selectedIds.contains(bill.id)) {
                            _selectedIds.remove(bill.id);
                          } else {
                            _selectedIds.add(bill.id);
                          }
                        }),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _billTitle(bill),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                            Text(
                              '${bill.date.toLocal().toString().split(' ').first} '
                              '• ${bill.supplierName}',
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
                        width: 130,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AppMoney(
                            bill.outstanding,
                            currencySymbol: bill.currencySymbol,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ),
                      SizedBox(width: 120, child: _statusPill(bill)),
                      _payField(bill),
                      SizedBox(width: 48, child: _billMenu(bill)),
                    ],
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

  Widget _payField(PurchaseBill bill, {double width = 170}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: _allocations[bill.id],
        onChanged: (_) => setState(() {}),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Pay',
          prefixText: '${bill.currencySymbol} ',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _statusPill(PurchaseBill bill) {
    final status = _billStatus(bill);
    final Color color = status == 'overdue' ? Colors.red : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status == 'overdue' ? Icons.warning_amber : Icons.schedule,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _statusLabel(status),
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

  /// Row ⋯ menu — allocation shortcuts only. Posting still goes through
  /// the unchanged _save path.
  Widget _billMenu(PurchaseBill bill) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        if (v == 'full') _allocateFull(bill);
        if (v == 'clear') _clearAllocation(bill);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'full', child: Text('Allocate full amount')),
        PopupMenuItem(value: 'clear', child: Text('Clear allocation')),
      ],
    );
  }

  /// "Showing x–y of N" pagination footer over the in-memory filtered bills.
  Widget _footer() {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final total = _display.length;
    final start = total == 0 ? 0 : _currentPage * _pageSize + 1;
    final end = (_currentPage * _pageSize + _pageRows.length).clamp(0, total);
    final totalPages = (total / _pageSize).ceil().clamp(1, 1 << 30);
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
              child: Text('Showing $start–$end of $total',
                  overflow: TextOverflow.ellipsis, style: small),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed:
                _currentPage > 0 ? () => setState(() => _currentPage--) : null,
          ),
          Text('Page ${_currentPage + 1} of $totalPages', style: small),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: (_currentPage + 1) * _pageSize < total
                ? () => setState(() => _currentPage++)
                : null,
          ),
        ],
      ),
    );
  }
}
