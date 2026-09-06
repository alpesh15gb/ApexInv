import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/widgets/app/app.dart';

class LoanAccountsScreen extends StatefulWidget {
  const LoanAccountsScreen({super.key});

  @override
  State<LoanAccountsScreen> createState() => _LoanAccountsScreenState();
}

class _LoanAccountsScreenState extends State<LoanAccountsScreen> {
  List<LoanAccount> _loans = const [];
  Map<String, double> _outstanding = const {};
  bool _loading = true;

  // ── Presentation-only state (in-memory over already-loaded rows) ──
  // _load still fetches every loan + its outstanding via the existing
  // service calls; status / search / sort / pagination below only
  // re-arrange those rows. Repay/history dialogs are untouched.
  String? _status; // null = all | active | closed
  String _searchQuery = '';
  String _sortField = 'start'; // start | name | outstanding
  bool _sortAscending = false;
  int _currentPage = 0;
  static const int _pageSize = 10;
  final TextEditingController _searchController = TextEditingController();

  static const double _wideBreakpoint = 800;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final loans = await AccountingService.getLoans();
    final outstanding = <String, double>{};
    for (final loan in loans) {
      outstanding[loan.id] =
          await AccountingService.getLoanOutstanding(loan.id);
    }
    if (mounted) {
      setState(() {
        _loans = loans;
        _outstanding = outstanding;
        _loading = false;
      });
    }
  }

  Map<String, int> get _statusCounts {
    var active = 0, closed = 0;
    for (final loan in _loans) {
      if (loan.status == 'closed') {
        closed++;
      } else {
        active++;
      }
    }
    return {'all': _loans.length, 'active': active, 'closed': closed};
  }

  double get _totalOutstanding =>
      _outstanding.values.fold<double>(0, (sum, value) => sum + value);

  List<LoanAccount> get _filtered {
    final q = _searchQuery.trim().toLowerCase();
    return _loans.where((loan) {
      if (_status == 'active' && loan.status == 'closed') return false;
      if (_status == 'closed' && loan.status != 'closed') return false;
      if (q.isNotEmpty &&
          !loan.name.toLowerCase().contains(q) &&
          !loan.lender.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  List<LoanAccount> get _visible {
    final rows = _filtered;
    rows.sort((a, b) {
      int result;
      switch (_sortField) {
        case 'name':
          result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case 'outstanding':
          result = (_outstanding[a.id] ?? 0).compareTo(_outstanding[b.id] ?? 0);
          break;
        default:
          result = a.startDate.compareTo(b.startDate);
      }
      return _sortAscending ? result : -result;
    });
    return rows;
  }

  List<LoanAccount> get _pageRows {
    final rows = _visible;
    final start = _currentPage * _pageSize;
    if (start >= rows.length) return const [];
    final end = (start + _pageSize).clamp(0, rows.length);
    return rows.sublist(start, end);
  }

  int get _totalPages => (_visible.length / _pageSize).ceil().clamp(1, 1 << 30);

  void _onSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == 'name';
      }
      _currentPage = 0;
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _status = null;
      _searchQuery = '';
      _currentPage = 0;
    });
  }

  Future<void> _create() async {
    final accounts = await AccountingService.getAccounts();
    if (!mounted) return;
    if (accounts.isEmpty) {
      _error('Create a cash or bank account first.');
      return;
    }
    final name = TextEditingController();
    final lender = TextEditingController();
    final principal = TextEditingController();
    final rate = TextEditingController(text: '0');
    final notes = TextEditingController();
    String accountId = accounts.first.id;
    DateTime startDate = DateTime.now();
    DateTime? maturityDate;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
                  title: const Text('New borrowed loan'),
                  content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            controller: name,
                            autofocus: true,
                            decoration:
                                const InputDecoration(labelText: 'Loan name')),
                        TextField(
                            controller: lender,
                            decoration:
                                const InputDecoration(labelText: 'Lender')),
                        TextField(
                            controller: principal,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Principal received')),
                        TextField(
                            controller: rate,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Annual interest rate (%)')),
                        DropdownButtonFormField<String>(
                            value: accountId,
                            decoration: const InputDecoration(
                                labelText: 'Receive into'),
                            items: accounts
                                .map((a) => DropdownMenuItem(
                                    value: a.id, child: Text(a.name)))
                                .toList(),
                            onChanged: (v) => accountId = v!),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Start date'),
                            trailing: TextButton(
                                child: Text(startDate
                                    .toLocal()
                                    .toString()
                                    .split(' ')
                                    .first),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                      context: ctx,
                                      initialDate: startDate,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365)));
                                  if (picked != null) {
                                    setDialogState(() => startDate = picked);
                                  }
                                })),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Maturity date (optional)'),
                            trailing: TextButton(
                                child: Text(maturityDate == null
                                    ? 'Set'
                                    : maturityDate!
                                        .toLocal()
                                        .toString()
                                        .split(' ')
                                        .first),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                      context: ctx,
                                      initialDate: maturityDate ??
                                          startDate
                                              .add(const Duration(days: 365)),
                                      firstDate: startDate,
                                      lastDate: startDate
                                          .add(const Duration(days: 36500)));
                                  if (picked != null) {
                                    setDialogState(() => maturityDate = picked);
                                  }
                                })),
                        TextField(
                            controller: notes,
                            maxLines: 2,
                            decoration:
                                const InputDecoration(labelText: 'Notes')),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Create')),
                  ],
                )));
    final principalValue = double.tryParse(principal.text.trim());
    final rateValue = double.tryParse(rate.text.trim()) ?? 0;
    if (ok != true ||
        principalValue == null ||
        principalValue <= 0 ||
        name.text.trim().isEmpty ||
        lender.text.trim().isEmpty) {
      return;
    }
    try {
      await AccountingService.createLoan(LoanAccount(
          id: const Uuid().v4(),
          name: name.text.trim(),
          lender: lender.text.trim(),
          originalPrincipal: principalValue,
          annualInterestRate: rateValue,
          startDate: startDate,
          maturityDate: maturityDate,
          disbursementAccountId: accountId,
          notes: notes.text.trim()));
      await _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _repay(LoanAccount loan) async {
    final accounts = await AccountingService.getAccounts();
    if (!mounted || accounts.isEmpty) return;
    final principal = TextEditingController();
    final interest = TextEditingController(text: '0');
    final fees = TextEditingController(text: '0');
    final reference = TextEditingController();
    final notes = TextEditingController();
    String accountId = accounts.first.id;
    DateTime date = DateTime.now();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
                  title: Text('Repay ${loan.name}'),
                  content: SizedBox(
                      width: 500,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                                'Outstanding principal: ${loan.currencySymbol} ${(_outstanding[loan.id] ?? 0).toStringAsFixed(2)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                        TextField(
                            controller: principal,
                            autofocus: true,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Principal component')),
                        TextField(
                            controller: interest,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Interest expense')),
                        TextField(
                            controller: fees,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration:
                                const InputDecoration(labelText: 'Fees')),
                        DropdownButtonFormField<String>(
                            value: accountId,
                            decoration:
                                const InputDecoration(labelText: 'Pay from'),
                            items: accounts
                                .map((a) => DropdownMenuItem(
                                    value: a.id, child: Text(a.name)))
                                .toList(),
                            onChanged: (v) => accountId = v!),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Payment date'),
                            trailing: TextButton(
                                child: Text(
                                    date.toLocal().toString().split(' ').first),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                      context: ctx,
                                      initialDate: date,
                                      firstDate: loan.startDate,
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365)));
                                  if (picked != null) {
                                    setDialogState(() => date = picked);
                                  }
                                })),
                        TextField(
                            controller: reference,
                            decoration:
                                const InputDecoration(labelText: 'Reference')),
                        TextField(
                            controller: notes,
                            decoration:
                                const InputDecoration(labelText: 'Notes')),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Post repayment')),
                  ],
                )));
    if (ok != true) return;
    try {
      await AccountingService.recordLoanRepayment(
          loanId: loan.id,
          accountId: accountId,
          principal: double.tryParse(principal.text.trim()) ?? 0,
          interest: double.tryParse(interest.text.trim()) ?? 0,
          fees: double.tryParse(fees.text.trim()) ?? 0,
          date: date,
          reference: reference.text.trim(),
          notes: notes.text.trim());
      await _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _history(LoanAccount loan) async {
    final rows = await AccountingService.getLoanMovements(loan.id);
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('${loan.name} history'),
              content: SizedBox(
                  width: 620,
                  height: 420,
                  child: rows.isEmpty
                      ? const AppEmptyState(
                          icon: Icons.history,
                          title: 'No movements yet.',
                          subtitle: 'Repayments will appear here.')
                      : ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, index) {
                            final row = rows[index];
                            final total = row.principalAmount +
                                row.interestAmount +
                                row.feeAmount;
                            return ListTile(
                                title: Text(row.type),
                                subtitle: Text(
                                    '${row.date.toLocal().toString().split(' ').first} '
                                    '• principal ${row.principalAmount.toStringAsFixed(2)} '
                                    '• interest ${row.interestAmount.toStringAsFixed(2)}'),
                                trailing: Text(
                                    '${loan.currencySymbol} ${total.toStringAsFixed(2)}'));
                          })),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              ],
            ));
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('StateError: ', '')),
        backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Loan Accounts'), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        const SizedBox(width: 8),
      ]),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideBreakpoint;
          return Column(
            children: [
              _header(context, wide),
              _statusChips(),
              _searchRow(),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const AppLoadingState()
                    : _loans.isEmpty
                        ? AppEmptyState(
                            icon: Icons.request_quote_outlined,
                            title: 'No loan accounts yet.',
                            subtitle:
                                'Record a borrowed loan to track outstanding amounts.',
                            action: AppPrimaryButton(
                              onPressed: _create,
                              label: const Text('Record first loan'),
                            ),
                          )
                        : _visible.isEmpty
                            ? Center(
                                child: AppEmptyState(
                                  icon: Icons.search_off,
                                  title: 'No loans in this view.',
                                  subtitle: 'Try a different status or search.',
                                  action: OutlinedButton.icon(
                                    onPressed: _clearFilters,
                                    icon: const Icon(Icons.clear_all, size: 18),
                                    label: const Text('Clear filters'),
                                  ),
                                ),
                              )
                            : wide
                                ? _table(context)
                                : _cards(),
              ),
              if (!_loading && _loans.isNotEmpty) _paginationFooter(context),
            ],
          );
        },
      ),
      floatingActionButton: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _wideBreakpoint) {
            return const SizedBox();
          }
          return FloatingActionButton(
            onPressed: _create,
            tooltip: 'New Loan',
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, bool wide) {
    final theme = Theme.of(context);
    final counts = _statusCounts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Loan Accounts',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Track borrowed loans and outstanding principal.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${counts['active'] ?? 0} active · '
                  'Outstanding ${_totalOutstanding.toStringAsFixed(2)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (wide) ...[
            const SizedBox(width: 12),
            AppPrimaryButton(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Loan'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChips() {
    final counts = _statusCounts;
    final options = <(String?, String)>[
      (null, 'All'),
      ('active', 'Active'),
      ('closed', 'Closed'),
    ];
    return SizedBox(
      height: 52,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        scrollDirection: Axis.horizontal,
        children: [
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _status == option.$1,
                label: Text(
                  '${option.$2} · ${option.$1 == null ? counts['all'] ?? 0 : counts[option.$1] ?? 0}',
                ),
                onSelected: (_) => setState(() {
                  _status = option.$1;
                  _currentPage = 0;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: AppSearchField(
        controller: _searchController,
        hintText: 'Search loan or lender...',
        onChanged: (value) => setState(() {
          _searchQuery = value;
          _currentPage = 0;
        }),
        onClear: _searchController.text.isEmpty ? null : () => _clearFilters(),
      ),
    );
  }

  Widget _table(BuildContext context) {
    int? sortIndex;
    switch (_sortField) {
      case 'name':
        sortIndex = 0;
        break;
      case 'start':
        sortIndex = 1;
        break;
      case 'outstanding':
        sortIndex = 4;
        break;
    }
    DataColumn col(String label, String field, {bool numeric = false}) =>
        DataColumn(
          label: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          numeric: numeric,
          onSort: (_, __) => _onSort(field),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: sortIndex,
            sortAscending: _sortAscending,
            columns: [
              col('Loan', 'name'),
              col('Start', 'start'),
              const DataColumn(
                label: Text(
                  'Rate',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                numeric: true,
              ),
              const DataColumn(
                label: Text(
                  'Status',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              col('Outstanding', 'outstanding', numeric: true),
              const DataColumn(label: Text('')),
            ],
            rows: [
              for (final loan in _pageRows)
                DataRow(cells: [
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loan.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            loan.lender,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DataCell(Text(
                      loan.startDate.toLocal().toString().split(' ').first)),
                  DataCell(
                      Text('${loan.annualInterestRate.toStringAsFixed(2)}%')),
                  DataCell(_statusPill(loan.status)),
                  DataCell(
                    AppMoney(
                      _outstanding[loan.id] ?? 0,
                      currencySymbol: loan.currencySymbol,
                      bold: true,
                    ),
                  ),
                  DataCell(_rowMenu(loan)),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cards() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _pageRows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _loanSummary();
        final loan = _pageRows[index - 1];
        final outstanding = _outstanding[loan.id] ?? 0;
        final progress = loan.originalPrincipal <= 0
            ? 0.0
            : (1 - outstanding / loan.originalPrincipal).clamp(0, 1).toDouble();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  const AppRowIcon(Icons.request_quote_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(loan.name,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(
                            '${loan.lender} • ${loan.annualInterestRate.toStringAsFixed(2)}% p.a.')
                      ])),
                  _statusPill(loan.status),
                ]),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text(
                    'Outstanding ${loan.currencySymbol} ${outstanding.toStringAsFixed(2)} '
                    'of ${loan.originalPrincipal.toStringAsFixed(2)}'),
                const SizedBox(height: 12),
                _loanLifecycle(loan, outstanding),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton.icon(
                      onPressed: () => _history(loan),
                      icon: const Icon(Icons.history),
                      label: const Text('History')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                      onPressed:
                          loan.status == 'closed' ? null : () => _repay(loan),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Repay')),
                ]),
              ])),
        );
      },
    );
  }

  Widget _paginationFooter(BuildContext context) {
    final total = _visible.length;
    if (total == 0) return const SizedBox();
    final start = _currentPage * _pageSize + 1;
    final end = ((_currentPage + 1) * _pageSize).clamp(0, total);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Showing $start–$end of $total',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed:
                _currentPage > 0 ? () => setState(() => _currentPage--) : null,
          ),
          Text(
            'Page ${_currentPage + 1} of $_totalPages',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
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

  Widget _statusPill(String status) {
    final closed = status == 'closed';
    final color = closed ? Colors.grey : Colors.green;
    final label = status.isEmpty
        ? status
        : '${status[0].toUpperCase()}${status.substring(1)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _rowMenu(LoanAccount loan) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) {
        if (value == 'history') _history(loan);
        if (value == 'repay') _repay(loan);
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'history', child: Text('History')),
        PopupMenuItem(
          value: 'repay',
          enabled: loan.status != 'closed',
          child: const Text('Repay'),
        ),
      ],
    );
  }

  Widget _loanSummary() {
    final counts = _statusCounts;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
          child: Wrap(spacing: 32, runSpacing: 12, children: [
        _metric('Active loans', '${counts['active'] ?? 0}'),
        _metric('Total outstanding', _totalOutstanding.toStringAsFixed(2)),
        _metric('Closed', '${counts['closed'] ?? 0}'),
      ])),
    );
  }

  Widget _metric(String label, String value) => SizedBox(
      width: 150,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
      ]));

  Widget _loanLifecycle(LoanAccount loan, double outstanding) {
    final now = DateTime.now();
    final maturity = loan.maturityDate;
    final maturityLabel = maturity == null
        ? 'No maturity date'
        : 'Maturity ${maturity.toLocal().toString().split(' ').first}';
    final due = maturity != null && maturity.isBefore(now) && outstanding > 0;
    return Row(children: [
      Icon(due ? Icons.warning_amber_rounded : Icons.event_available_outlined,
          size: 18,
          color: due
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary),
      const SizedBox(width: 8),
      Text('Started ${loan.startDate.toLocal().toString().split(' ').first}'),
      const SizedBox(width: 12),
      Expanded(child: Text(maturityLabel, overflow: TextOverflow.ellipsis)),
      if (due)
        Text('Past due',
            style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600)),
    ]);
  }
}
