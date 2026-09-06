import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/utils/gstin_validator.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Inward supplies (purchase bills) — feeds ITC reporting and GSTR-2.
class PurchaseBillScreen extends ConsumerStatefulWidget {
  final User user;
  const PurchaseBillScreen({super.key, required this.user});

  @override
  ConsumerState<PurchaseBillScreen> createState() => _PurchaseBillScreenState();
}

class _PurchaseBillScreenState extends ConsumerState<PurchaseBillScreen> {
  List<PurchaseBill> _bills = [];
  bool _isLoading = true;
  String _search = '';
  // Presentation-only state: status, date range, sorting, selection and
  // paging are applied in-memory over the already-loaded bills. The
  // getBills query, totals, payments and navigation are untouched.
  final TextEditingController _searchCtrl = TextEditingController();
  String _statusFilter =
      'all'; // 'all' | 'paid' | 'partial' | 'unpaid' | 'overdue'
  DateTime? _fromDate;
  DateTime? _toDate;
  String _sortField = 'date'; // 'date' | 'supplier' | 'total'
  bool _sortAscending = false;
  final Set<String> _selectedIds = {};
  int _currentPage = 0;
  final int _pageSize = 20;
  // E3c: synchronously-checked flags so a double-tap on Pay cannot stack
  // two dialogs or double-record. Service-side race is covered separately;
  // this is the UI guard.
  bool _payDialogOpen = false;
  bool _paySaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final bills = await PurchaseBillService.getBills();
    if (!mounted) return;
    setState(() {
      _bills = bills;
      _isLoading = false;
      _selectedIds.removeWhere((id) => !_bills.any((b) => b.id == id));
      final maxPage = (_visible.length / _pageSize).ceil().clamp(1, 1 << 30);
      if (_currentPage >= maxPage) _currentPage = maxPage - 1;
    });
  }

  List<PurchaseBill> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _bills;
    return _bills.where((b) {
      return b.supplierName.toLowerCase().contains(q) ||
          (b.billNumber ?? '').toLowerCase().contains(q) ||
          b.supplierGstin.toLowerCase().contains(q);
    }).toList();
  }

  /// Payment status mirroring the derivation in _billCard below, so chips,
  /// pills and cards always agree.
  String _billStatus(PurchaseBill b) {
    if (b.outstanding <= 0.005) return 'paid';
    if (b.dueDate != null && b.dueDate!.isBefore(DateTime.now())) {
      return 'overdue';
    }
    if (b.amountPaid > 0.005) return 'partial';
    return 'unpaid';
  }

  String _statusLabel(String status) => switch (status) {
        'paid' => 'Paid',
        'partial' => 'Partially paid',
        'unpaid' => 'Unpaid',
        'overdue' => 'Overdue',
        _ => 'All',
      };

  /// LIVE chip counts aggregated in-memory from the already-loaded bills.
  Map<String, int> get _statusCounts {
    final counts = {'paid': 0, 'partial': 0, 'unpaid': 0, 'overdue': 0};
    for (final b in _bills) {
      final s = _billStatus(b);
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

  /// Presentation-only filtering/sorting over the loaded bills.
  List<PurchaseBill> get _visible {
    final rows = _filtered.where((b) {
      if (_statusFilter != 'all' && _billStatus(b) != _statusFilter) {
        return false;
      }
      return _matchesRange(b.date);
    }).toList();
    rows.sort((a, b) {
      final int c;
      switch (_sortField) {
        case 'supplier':
          c = a.supplierName
              .toLowerCase()
              .compareTo(b.supplierName.toLowerCase());
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

  List<PurchaseBill> get _pageRows {
    final start = _currentPage * _pageSize;
    if (start >= _visible.length) return const [];
    final end = (start + _pageSize).clamp(start, _visible.length);
    return _visible.sublist(start, end);
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

  Future<void> _openForm([PurchaseBill? existing]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PurchaseBillFormScreen(
          user: widget.user,
          existing: existing,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _recordPayment(PurchaseBill bill) async {
    // E3c: prevent stacking two Pay dialogs via double-tap.
    if (_payDialogOpen || _paySaving) return;
    _payDialogOpen = true;
    final controller = TextEditingController();
    final notesController = TextEditingController();
    DateTime paymentDate = DateTime.now();
    String? method;
    // E3c: in-dialog saving guard — disables Save after the first tap.
    bool dialogSaving = false;
    String? dialogError;
    final payments = await PurchaseBillService.getPayments(bill.id);
    final l10n = AppLocalizations.of(context)!;
    bool? ok;
    try {
      ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text('Pay ${bill.supplierName}'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (payments.isNotEmpty) ...[
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Payment history',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    for (final p in payments)
                      ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                              '${p.datePaid.toLocal().toString().split(' ').first}  ${p.paymentMethod ?? 'Other'}'),
                          trailing: Text(
                              '${bill.currencySymbol} ${p.amountPaid.toStringAsFixed(2)}')),
                    const Divider(),
                  ],
                  TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: l10n.fieldTotalLabel,
                          prefixText: '${bill.currencySymbol} ',
                          hintText: bill.outstanding.toStringAsFixed(2))),
                  if (dialogError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(dialogError!,
                            style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error,
                                fontSize: 12)),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                      value: method,
                      decoration:
                          const InputDecoration(labelText: 'Payment method'),
                      items: const [
                        DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                        DropdownMenuItem(
                            value: 'Bank Transfer',
                            child: Text('Bank Transfer')),
                        DropdownMenuItem(
                            value: 'Online', child: Text('Online')),
                        DropdownMenuItem(value: 'Other', child: Text('Other'))
                      ],
                      onChanged: (v) => setDialogState(() => method = v)),
                  TextField(
                      controller: notesController,
                      decoration:
                          const InputDecoration(labelText: 'Notes (optional)')),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Payment date'),
                      trailing: TextButton(
                          child: Text(paymentDate
                              .toLocal()
                              .toString()
                              .split(' ')
                              .first),
                          onPressed: () async {
                            final picked = await showDatePicker(
                                context: ctx,
                                initialDate: paymentDate,
                                firstDate: DateTime(2000),
                                lastDate: DateTime.now()
                                    .add(const Duration(days: 365)));
                            if (picked != null)
                              setDialogState(() => paymentDate = picked);
                          })),
                ],
              )),
            ),
            actions: [
              TextButton(
                  onPressed:
                      dialogSaving ? null : () => Navigator.pop(ctx, false),
                  child: Text(l10n.actionCancel)),
              FilledButton(
                  onPressed: dialogSaving
                      ? null
                      : () {
                          // Synchronous guard + validation BEFORE popping —
                          // the old code popped true unconditionally (:159)
                          // and validated outside, allowing stale/double
                          // writes.
                          if (dialogSaving) return;
                          final amount =
                              double.tryParse(controller.text.trim());
                          if (amount == null ||
                              !amount.isFinite ||
                              amount <= 0) {
                            setDialogState(() => dialogError =
                                'Enter a valid amount greater than zero.');
                            return;
                          }
                          if (amount > bill.outstanding + 0.005) {
                            setDialogState(() => dialogError =
                                'Amount exceeds the outstanding balance.');
                            return;
                          }
                          dialogSaving = true;
                          setDialogState(() {});
                          Navigator.pop(ctx, true);
                        },
                  child: Text(dialogSaving ? 'Saving…' : l10n.actionSave)),
            ],
          ),
        ),
      );
    } finally {
      _payDialogOpen = false;
    }
    if (ok != true) {
      controller.dispose();
      notesController.dispose();
      return;
    }
    // E3c: post-dialog saving guard for the async service call.
    if (_paySaving) {
      controller.dispose();
      notesController.dispose();
      return;
    }
    _paySaving = true;
    try {
      final amount = double.tryParse(controller.text.trim());
      if (amount == null || !amount.isFinite || amount <= 0) return;
      await PurchaseBillService.recordPayment(bill.id, amount,
          datePaid: paymentDate,
          paymentMethod: method,
          notes: notesController.text.trim().isEmpty
              ? null
              : notesController.text.trim(),
          actor: widget.user.username);
      controller.dispose();
      notesController.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Payment of ${bill.currencySymbol} ${amount.toStringAsFixed(2)} recorded for ${bill.supplierName}.'),
        backgroundColor: Colors.green,
      ));
      _load();
    } finally {
      _paySaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.sizeOf(context).width < Breakpoints.compactMax;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Purchase Bills'),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionRefresh,
          ),
          const SizedBox(width: 8),
        ],
      ),
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
              _listFilterRow(narrow),
              if (_selectedIds.isNotEmpty) _selectionBar(),
              Expanded(child: _listBody(narrow)),
              if (!_isLoading && _visible.isNotEmpty) _footer(),
            ],
          );
        },
      ),
      floatingActionButton: isNarrow
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('New Bill'),
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
                'Purchase Bills',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                'Record inward supplies to track ITC.',
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
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Bill'),
          ),
        ],
      ],
    );
  }

  /// Status filter chips with LIVE counts aggregated in-memory from the
  /// already-loaded bills. Filtering itself is in-memory — no query change.
  Widget _statusChips() {
    final counts = _statusCounts;
    final options = ['all', 'paid', 'partial', 'unpaid', 'overdue'];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final status = options[i];
          final count = status == 'all' ? _bills.length : (counts[status] ?? 0);
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

  /// Search + date-range + Filter row (all in-memory over loaded bills).
  Widget _listFilterRow(bool isNarrow) {
    final search = AppSearchField(
      controller: _searchCtrl,
      hintText: 'Search supplier / bill no / GSTIN',
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
      _resetPage();
    });
  }

  String _sortLabel(String field) => switch (field) {
        'supplier' => 'Supplier name',
        'total' => 'Total amount',
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
                  for (final f in const ['date', 'supplier', 'total'])
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
        _sortAscending = field == 'supplier';
      }
      _resetPage();
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

  Widget _listBody(bool isNarrow) {
    if (_isLoading) return const AppLoadingState();
    if (_bills.isEmpty) {
      return AppEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No purchase bills yet.',
        subtitle: 'Record inward supplies to track ITC.',
        action: FilledButton.tonal(
          onPressed: () => _openForm(),
          child: const Text('New Bill'),
        ),
      );
    }
    if (_filtered.isEmpty) {
      return AppEmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No bills match your search.',
        subtitle: 'Try a different supplier, bill number or GSTIN.',
        action: FilledButton.tonal(
          onPressed: () => _openForm(),
          child: const Text('New Bill'),
        ),
      );
    }
    if (_visible.isEmpty) {
      return AppEmptyState(
        icon: Icons.search_off,
        title: 'No bills match your filters.',
        subtitle: 'Try a different status or date range.',
        action: FilledButton.tonal(
          onPressed: () => setState(_clearLocalFilters),
          child: const Text('Clear filters'),
        ),
      );
    }
    if (isNarrow) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
        itemCount: _pageRows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (context, i) => _billCard(_pageRows[i], true),
      );
    }
    return _table();
  }

  /// Wide sortable table with checkboxes, status pills and a ⋯ menu.
  /// Menu actions reuse the exact pay / edit / delete paths as the cards.
  Widget _table() {
    final theme = Theme.of(context);
    final rows = _pageRows;
    final pageIds = rows.map((b) => b.id).toSet();
    final selInPage = _selectedIds.intersection(pageIds).length;
    final df = DateFormat('dd MMM yyyy');
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
                        'SUPPLIER / BILL',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(width: 104, child: _sortHeader('DATE', 'date')),
                    SizedBox(width: 128, child: _sortHeader('TOTAL', 'total')),
                    const SizedBox(
                      width: 132,
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
                              bill.supplierName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                            Text(
                              [
                                if ((bill.billNumber ?? '').isNotEmpty)
                                  'Bill #${bill.billNumber}',
                                df.format(bill.date),
                                if (bill.supplierGstin.isNotEmpty)
                                  bill.supplierGstin,
                              ].join('  ·  '),
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
                          df.format(bill.date),
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      SizedBox(
                        width: 128,
                        child: AppMoney(
                          bill.totalAmount,
                          currencySymbol: bill.currencySymbol,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: theme.primaryColor,
                          ),
                        ),
                      ),
                      SizedBox(width: 132, child: _billStatusPill(bill)),
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

  Widget _billStatusPill(PurchaseBill bill) {
    final status = _billStatus(bill);
    final Color color = switch (status) {
      'paid' => Colors.green,
      'overdue' => Colors.red,
      _ => Colors.orange,
    };
    final label = status == 'paid'
        ? 'Paid'
        : status == 'overdue'
            ? 'Overdue'
            : status == 'partial'
                ? 'Partially paid'
                : 'Unpaid';
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
            status == 'paid'
                ? Icons.check_circle
                : status == 'overdue'
                    ? Icons.warning_amber
                    : Icons.schedule,
            size: 14,
            color: color,
          ),
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

  /// Row ⋯ menu — the same pay / edit / delete paths as the narrow cards.
  Widget _billMenu(PurchaseBill bill) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'pay':
            _recordPayment(bill);
            break;
          case 'edit':
            _openForm(bill);
            break;
          case 'delete':
            _deleteBill(bill);
            break;
        }
      },
      itemBuilder: (_) => [
        if (bill.outstanding > 0.005)
          const PopupMenuItem(value: 'pay', child: Text('Record payment')),
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (widget.user.isAdmin())
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  Future<void> _deleteBill(PurchaseBill bill) async {
    await PurchaseBillService.softDeleteBill(bill.id,
        actor: widget.user.username);
    _load();
  }

  /// "Showing x–y of N" pagination footer over the in-memory filtered bills.
  Widget _footer() {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final total = _visible.length;
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

  Widget _billCard(PurchaseBill bill, bool isCompact) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM yyyy');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(bill.supplierName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: bill.itcEligible
                        ? Colors.green.withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(bill.itcEligible ? 'ITC' : 'No ITC',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: bill.itcEligible
                              ? Colors.green
                              : theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if ((bill.billNumber ?? '').isNotEmpty)
                  'Bill #${bill.billNumber}',
                df.format(bill.date),
                if (bill.supplierGstin.isNotEmpty) bill.supplierGstin,
              ].join('  ·  '),
              style: TextStyle(
                  fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Taxable + Tax',
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant)),
                      Text(
                        '${bill.currencySymbol} ${bill.taxableTotal.toStringAsFixed(2)} + ${bill.currencySymbol} ${bill.totalTax.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Total',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                    AppMoney(
                      bill.totalAmount,
                      currencySymbol: bill.currencySymbol,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: theme.primaryColor),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.payments_outlined,
                    size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Builder(builder: (context) {
                  final isPaid = bill.outstanding <= 0.005;
                  final isOverdue = !isPaid &&
                      bill.dueDate != null &&
                      bill.dueDate!.isBefore(DateTime.now());
                  final isPartial =
                      !isPaid && !isOverdue && bill.amountPaid > 0.005;
                  final String label;
                  final Color statusColor;
                  if (isPaid) {
                    label = 'Paid';
                    statusColor = Colors.green;
                  } else if (isOverdue) {
                    label =
                        'Overdue · Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}';
                    statusColor = Colors.red;
                  } else if (isPartial) {
                    label =
                        'Partially paid · Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}';
                    statusColor = Colors.orange;
                  } else {
                    label =
                        'Unpaid · Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}';
                    statusColor = Colors.orange;
                  }
                  return Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: statusColor,
                          fontWeight: FontWeight.w600),
                    ),
                  );
                }),
                const Spacer(),
                if (bill.outstanding > 0.005)
                  IconButton(
                    icon: const Icon(Icons.payments_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Record payment',
                    onPressed: () => _recordPayment(bill),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openForm(bill),
                  tooltip: AppLocalizations.of(context)!.actionEdit,
                ),
                if (widget.user.isAdmin())
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    visualDensity: VisualDensity.compact,
                    color: theme.colorScheme.error,
                    tooltip: AppLocalizations.of(context)!.actionDelete,
                    onPressed: () => _deleteBill(bill),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Add / edit form — full-screen so it works on every width.
class PurchaseBillFormScreen extends ConsumerStatefulWidget {
  final User user;
  final PurchaseBill? existing;
  final PurchaseBill? prefill;
  const PurchaseBillFormScreen(
      {super.key, required this.user, this.existing, this.prefill});

  @override
  ConsumerState<PurchaseBillFormScreen> createState() =>
      _PurchaseBillFormScreenState();
}

class _PurchaseBillFormScreenState
    extends ConsumerState<PurchaseBillFormScreen> {
  late final List<_ItemDraft> _items;
  late String _billId;
  final _supplierCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _billNoCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  bool _itcEligible = true;
  bool _reverseCharge = false;
  bool _interState = false;
  // Document-level GST toggle: true → typed rates include GST.
  // Applies to every line, existing and subsequently added.
  bool _pricesIncludeTax = false;
  bool _isSaving = false;
  String _currencySymbol = '₹';
  String _currencyCode = 'INR';

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final seed = e ?? widget.prefill;
    // Prefill seeds controllers only; _isEdit stays (existing != null) so
    // saving a prefilled form always goes through the insert (create) path.
    // A fresh id is always generated for non-edits to avoid PK collisions.
    _billId = e?.id ?? const Uuid().v4();
    _items = seed == null
        ? [_ItemDraft()]
        : seed.items
            .map((i) => _ItemDraft(
                  name: i.productName,
                  hsn: i.hsnCode,
                  qty: i.quantity,
                  rate: i.rate,
                  taxRate: i.taxRate,
                  discount: i.discount,
                ))
            .toList();
    if (e != null) {
      _supplierCtrl.text = e.supplierName;
      _gstinCtrl.text = e.supplierGstin;
      _phoneCtrl.text = e.supplierPhone;
      _emailCtrl.text = e.supplierEmail;
      _addressCtrl.text = e.supplierAddress;
      _currencySymbol = e.currencySymbol;
      _currencyCode = e.currencyCode;
      _billNoCtrl.text = e.billNumber ?? '';
      _notesCtrl.text = e.notes;
      _date = e.date;
      _dueDate = e.dueDate;
      _itcEligible = e.itcEligible;
      _reverseCharge = e.reverseCharge;
      _interState = e.igstTotal > 0;
      _pricesIncludeTax = e.priceIncludesTax;
    } else if (widget.prefill != null) {
      // PO → Bill prefill: supplier + items + currency only. Bill number,
      // dates, GSTIN details and payment state stay fresh for the new bill.
      final p = widget.prefill!;
      _supplierCtrl.text = p.supplierName;
      _currencySymbol = p.currencySymbol;
      _currencyCode = p.currencyCode;
      _pricesIncludeTax = p.priceIncludesTax;
    } else {
      _loadConfiguredCurrency();
    }
  }

  Future<void> _loadConfiguredCurrency() async {
    final results = await Future.wait([
      SettingsService.getCurrency(),
      SettingsService.getDefaultPriceIncludesTax(),
    ]);
    if (!mounted) return;
    setState(() {
      final currency = results[0] as dynamic;
      _currencyCode = currency.code as String;
      _currencySymbol = currency.symbol as String;
      _pricesIncludeTax = results[1] as bool;
    });
  }

  @override
  void dispose() {
    _supplierCtrl.dispose();
    _gstinCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _billNoCtrl.dispose();
    _notesCtrl.dispose();
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  List<PurchaseBillItem> get _computedItems {
    final id = _billId;
    return _items
        .where((d) => d.name.text.trim().isNotEmpty)
        .map((d) => PurchaseBillItem.compute(
              id: d.id,
              purchaseBillId: id,
              productName: d.name.text.trim(),
              hsnCode: d.hsn.text.trim(),
              quantity: double.tryParse(d.qty.text.trim()) ?? double.nan,
              rate: double.tryParse(d.rate.text.trim()) ?? double.nan,
              taxRate: double.tryParse(d.tax.text.trim()) ?? double.nan,
              discount: double.tryParse(d.discount.text.trim()) ?? double.nan,
              interState: _interState || _reverseCharge,
              priceIncludesTax: _pricesIncludeTax,
            ))
        .toList();
  }

  /// Validates raw drafts before save; returns an error message or null.
  /// Throws nothing — callers show the message and abort the save.
  String? _validateDrafts() {
    var hasNamed = false;
    for (final d in _items) {
      if (d.name.text.trim().isEmpty) continue;
      hasNamed = true;
      final qty = double.tryParse(d.qty.text.trim());
      final rate = double.tryParse(d.rate.text.trim());
      final tax = double.tryParse(d.tax.text.trim());
      final discount = double.tryParse(d.discount.text.trim());
      if (qty == null ||
          rate == null ||
          tax == null ||
          discount == null ||
          !qty.isFinite ||
          !rate.isFinite ||
          !tax.isFinite ||
          !discount.isFinite) {
        return 'Item "${d.name.text.trim()}": quantity, rate, tax and discount must be valid finite numbers';
      }
      if (qty <= 0) {
        return 'Item "${d.name.text.trim()}": quantity must be greater than zero';
      }
      if (rate < 0) {
        return 'Item "${d.name.text.trim()}": rate cannot be negative';
      }
      if (tax < 0) {
        return 'Item "${d.name.text.trim()}": tax cannot be negative';
      }
      if (discount < 0) {
        return 'Item "${d.name.text.trim()}": discount cannot be negative';
      }
      final gross = qty * rate;
      if (!gross.isFinite) {
        return 'Item "${d.name.text.trim()}": quantity × rate is not finite';
      }
      if (discount > gross) {
        return 'Item "${d.name.text.trim()}": discount cannot exceed quantity × rate';
      }
    }
    if (!hasNamed) return null;
    return null;
  }

  double _safeFold(double Function() compute) {
    try {
      final v = compute();
      return v.isFinite ? v : 0;
    } catch (_) {
      return 0;
    }
  }

  double get _totalTaxable =>
      _safeFold(() => _computedItems.fold(0, (s, i) => s + i.taxableValue));
  double get _totalTax => _safeFold(
      () => _computedItems.fold(0, (s, i) => s + i.amount - i.taxableValue));
  double get _grandTotal =>
      _safeFold(() => _computedItems.fold(0, (s, i) => s + i.amount));

  Future<void> _save() async {
    // E3b: synchronous re-entrancy guard before the first await — a
    // double-tap on Save must not stack two inserts.
    if (_isSaving) return;
    _isSaving = true;
    // Trial/licence gate: new bills only; edits to existing stay allowed.
    if (!_isEdit && !await LicenseGate.canCreate(context)) {
      _isSaving = false;
      return;
    }
    final lineError = _validateDrafts();
    if (lineError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(lineError)));
      _isSaving = false;
      return;
    }
    late final List<PurchaseBillItem> computed;
    try {
      computed = _computedItems;
    } on ArgumentError catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message.toString())));
      _isSaving = false;
      return;
    }
    if (_supplierCtrl.text.trim().isEmpty || computed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Supplier name and at least one item are required')));
      _isSaving = false;
      return;
    }
    // Warn-only GSTIN check: never block saving real bills.
    final supplierGstinRaw = _gstinCtrl.text.trim();
    if (supplierGstinRaw.isNotEmpty && !isValidGstin(supplierGstinRaw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GSTIN looks invalid')),
      );
    }
    setState(() => _isSaving = true);
    // Single source of truth: new bills reuse the init-time _billId that
    // _computedItems already stamped on every line, so header id always
    // equals item purchaseBillId. Regenerate after save to avoid reuse.
    try {
      final id = widget.existing?.id ?? _billId;
      final bill = PurchaseBill(
        id: id,
        billNumber: _billNoCtrl.text.trim(),
        supplierName: _supplierCtrl.text.trim(),
        supplierGstin: _gstinCtrl.text.trim().toUpperCase(),
        supplierPhone: _phoneCtrl.text.trim(),
        supplierEmail: _emailCtrl.text.trim(),
        supplierAddress: _addressCtrl.text.trim(),
        date: _date,
        dueDate: _dueDate,
        totalAmount: _grandTotal,
        totalTax: _totalTax,
        amountPaid: widget.existing?.amountPaid ?? 0,
        itcEligible: _itcEligible,
        reverseCharge: _reverseCharge,
        priceIncludesTax: _pricesIncludeTax,
        notes: _notesCtrl.text.trim(),
        currencyCode: _currencyCode,
        currencySymbol: _currencySymbol,
        items: computed,
      );
      if (_isEdit) {
        await PurchaseBillService.updateBill(bill, actor: widget.user.username);
      } else {
        await PurchaseBillService.insertBill(bill, actor: widget.user.username);
      }
      if (!_isEdit) _billId = const Uuid().v4();
      if (!mounted) return;
      if (mounted) setState(() => _isSaving = false);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _pickDate({required bool due}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: due ? (_dueDate ?? _date) : _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (due) {
        _dueDate = picked;
      } else {
        _date = picked;
      }
    });
  }

  BoxDecoration _flatCard(BuildContext context) => BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      );

  InputDecoration _fieldDec(String label, {Widget? suffixIcon}) =>
      InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  Widget _responsiveGrid(List<Widget> fields) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= Breakpoints.compactMax) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: fields[i]),
              ],
            ],
          );
        }
        const gap = 12.0;
        final w = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final f in fields) SizedBox(width: w, child: f)],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final df = DateFormat('dd MMM yyyy');
    final title = _isEdit ? 'Edit Purchase Bill' : 'New Purchase Bill';
    return Scaffold(
      backgroundColor:
          theme.brightness == Brightness.dark ? null : Colors.grey[50],
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, c) {
            final compact = c.maxWidth < 640;
            if (compact) {
              return Text(title, overflow: TextOverflow.ellipsis, maxLines: 1);
            }
            return Row(
              children: [
                Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis, maxLines: 1)),
                if (_billNoCtrl.text.trim().isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('#${_billNoCtrl.text.trim()}',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ],
            );
          },
        ),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: theme.scaffoldBackgroundColor,
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            if (widget.prefill != null && !_isEdit)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: theme.colorScheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Prefilled from purchase order — review supplier and items, then save as a new bill.',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  const wide = 980.0;
                  final isWide = c.maxWidth >= wide;
                  final supplierCard = Container(
                    decoration: _flatCard(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                          child: Row(
                            children: [
                              Icon(Icons.storefront_outlined,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              const Text('SUPPLIER DETAILS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _responsiveGrid([
                                TextField(
                                    controller: _supplierCtrl,
                                    decoration: _fieldDec('Supplier Name *')),
                                TextField(
                                    controller: _gstinCtrl,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    decoration: _fieldDec('Supplier GSTIN')),
                                TextField(
                                    controller: _phoneCtrl,
                                    decoration: _fieldDec('Phone'),
                                    keyboardType: TextInputType.phone),
                              ]),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: _billNoCtrl,
                                  decoration: _fieldDec('Supplier Invoice No')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                  final billCard = Container(
                    decoration: _flatCard(context),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.receipt_long_outlined,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              const Text('BILL DETAILS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 12),
                          _responsiveGrid([
                            InkWell(
                              onTap: () => _pickDate(due: false),
                              child: InputDecorator(
                                decoration: _fieldDec('Bill Date'),
                                child: Text(df.format(_date)),
                              ),
                            ),
                            InkWell(
                              onTap: () => _pickDate(due: true),
                              child: InputDecorator(
                                decoration: _fieldDec('Due Date'),
                                child: Text(_dueDate == null
                                    ? '—'
                                    : df.format(_dueDate!)),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilterChip(
                                selected: _interState,
                                label: const Text('Inter-state (IGST)'),
                                onSelected: (v) =>
                                    setState(() => _interState = v),
                              ),
                              FilterChip(
                                selected: _reverseCharge,
                                label: const Text('Reverse charge'),
                                onSelected: (v) =>
                                    setState(() => _reverseCharge = v),
                              ),
                              FilterChip(
                                selected: _itcEligible,
                                label: const Text('ITC eligible'),
                                onSelected: (v) =>
                                    setState(() => _itcEligible = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                  final itemsCard = Container(
                    decoration: _flatCard(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: Row(
                            children: [
                              const Text('ITEMS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color:
                                      theme.primaryColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text('${_items.length}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: theme.primaryColor)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._items
                            .asMap()
                            .entries
                            .map((e) => _itemEditor(e.key, e.value)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                setState(() => _items.add(_ItemDraft())),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add item'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                  final summaryCard = Container(
                    decoration: _flatCard(context),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SUMMARY',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6)),
                        const SizedBox(height: 12),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                                value: false, label: Text('Excl GST')),
                            ButtonSegment<bool>(
                                value: true, label: Text('Incl GST')),
                          ],
                          selected: {_pricesIncludeTax},
                          onSelectionChanged: (selection) {
                            if (!mounted) return;
                            setState(() => _pricesIncludeTax = selection.first);
                          },
                        ),
                        const SizedBox(height: 12),
                        _totalRow('Taxable', _totalTaxable),
                        _totalRow('Tax', _totalTax),
                        const Divider(),
                        _totalRow('Total', _grandTotal, bold: true),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _notesCtrl,
                          maxLines: 2,
                          decoration: _fieldDec('Notes'),
                        ),
                      ],
                    ),
                  );
                  if (isWide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              supplierCard,
                              const SizedBox(height: 12),
                              billCard,
                              const SizedBox(height: 12),
                              Expanded(child: itemsCard),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 360,
                          child: SingleChildScrollView(child: summaryCard),
                        ),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        supplierCard,
                        const SizedBox(height: 12),
                        billCard,
                        const SizedBox(height: 12),
                        itemsCard,
                        const SizedBox(height: 12),
                        summaryCard,
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant)),
                  color: theme.colorScheme.surface,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.fieldTotalLabel,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurfaceVariant)),
                          Text(
                            '$_currencySymbol ${_grandTotal.toStringAsFixed(2)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: theme.primaryColor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: Text(_isEdit ? 'Update Bill' : 'Save Bill'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemEditor(int index, _ItemDraft d) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
                child: TextField(
                    controller: d.name, decoration: _dec('Item / service *'))),
            IconButton(
                onPressed: () => setState(() => _items.removeAt(index)),
                icon: const Icon(Icons.remove_circle_outline,
                    color: Colors.redAccent)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(controller: d.hsn, decoration: _dec('HSN'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.qty,
                    decoration: _dec('Qty'),
                    keyboardType: TextInputType.number)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: d.rate,
                    decoration: _dec('Rate'),
                    keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.tax,
                    decoration: _dec('GST %'),
                    keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.discount,
                    decoration: _dec('Discount'),
                    keyboardType: TextInputType.number)),
          ]),
        ]),
      ),
    );
  }

  Widget _totalRow(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label,
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        Text('$_currencySymbol ${value.toStringAsFixed(2)}',
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}

class _ItemDraft {
  final id = const Uuid().v4();
  final name = TextEditingController();
  final hsn = TextEditingController();
  final qty = TextEditingController(text: '1');
  final rate = TextEditingController();
  final tax = TextEditingController(text: '18');
  final discount = TextEditingController(text: '0');

  _ItemDraft(
      {String name = '',
      String hsn = '',
      double qty = 1,
      double rate = 0,
      double taxRate = 18,
      double discount = 0}) {
    this.name.text = name;
    this.hsn.text = hsn;
    this.qty.text = qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 2);
    this.rate.text = rate.toStringAsFixed(2);
    tax.text = taxRate.toStringAsFixed(0);
    this.discount.text = discount.toStringAsFixed(2);
  }

  void dispose() {
    name.dispose();
    hsn.dispose();
    qty.dispose();
    rate.dispose();
    tax.dispose();
    discount.dispose();
  }
}
