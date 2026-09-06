import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/widgets/app/app.dart';

class FinancialAccountsScreen extends StatefulWidget {
  final String accountType; // cash | bank

  const FinancialAccountsScreen({
    super.key,
    required this.accountType,
  });

  @override
  State<FinancialAccountsScreen> createState() =>
      _FinancialAccountsScreenState();
}

class _FinancialAccountsScreenState extends State<FinancialAccountsScreen> {
  List<FinancialAccount> _accounts = const [];
  Map<String, double> _balances = const {};
  List<FinancialTransaction> _transactions = const [];
  String? _selectedId;
  bool _loading = true;

  // ── Presentation-only state (in-memory over already-loaded rows) ──
  // _load still uses the existing getAccounts / getBalances /
  // getTransactions calls; search / filter / sort / pagination below only
  // re-arrange the loaded accounts. Transfer/adjust/edit/postings untouched.
  String _searchQuery = '';
  String _activeFilter = 'all'; // all | active | inactive
  String _sortField = 'name'; // name | balance
  bool _sortAscending = true;
  int _currentPage = 0;
  static const int _pageSize = 10;
  final TextEditingController _searchController = TextEditingController();

  static const double _wideBreakpoint = 800;

  String get _title =>
      widget.accountType == 'bank' ? 'Bank Accounts' : 'Cash In Hand';

  String get _subtitle => widget.accountType == 'bank'
      ? 'Manage bank balances, transfers and adjustments.'
      : 'Manage cash balances, transfers and adjustments.';

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

  Future<void> _load({String? select}) async {
    if (mounted) setState(() => _loading = true);
    final accounts = await AccountingService.getAccounts(
        type: widget.accountType, activeOnly: false);
    final balances = await AccountingService.getBalances(accounts);
    final selected = select ??
        (_selectedId != null && accounts.any((a) => a.id == _selectedId)
            ? _selectedId
            : accounts.isEmpty
                ? null
                : accounts.first.id);
    final transactions = selected == null
        ? <FinancialTransaction>[]
        : await AccountingService.getTransactions(selected);
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _balances = balances;
      _selectedId = selected;
      _transactions = transactions;
      _loading = false;
    });
  }

  Map<String, int> get _statusCounts {
    var active = 0, inactive = 0;
    for (final a in _accounts) {
      if (a.active) {
        active++;
      } else {
        inactive++;
      }
    }
    return {'all': _accounts.length, 'active': active, 'inactive': inactive};
  }

  double get _totalBalance =>
      _accounts.fold(0, (sum, a) => sum + (_balances[a.id] ?? 0));

  String get _currencySymbol =>
      _accounts.isEmpty ? '₹' : _accounts.first.currencySymbol;

  List<FinancialAccount> get _filtered {
    final q = _searchQuery.trim().toLowerCase();
    return _accounts.where((a) {
      if (_activeFilter == 'active' && !a.active) return false;
      if (_activeFilter == 'inactive' && a.active) return false;
      if (q.isNotEmpty &&
          !a.name.toLowerCase().contains(q) &&
          !a.institution.toLowerCase().contains(q) &&
          !a.accountNumberMasked.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  List<FinancialAccount> get _visible {
    final rows = _filtered;
    rows.sort((a, b) {
      int result;
      switch (_sortField) {
        case 'balance':
          result = (_balances[a.id] ?? 0).compareTo(_balances[b.id] ?? 0);
          break;
        default:
          result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAscending ? result : -result;
    });
    return rows;
  }

  List<FinancialAccount> get _pageRows {
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
        _sortAscending = true;
      }
      _currentPage = 0;
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _activeFilter = 'all';
      _currentPage = 0;
    });
  }

  Future<void> _select(String id) async {
    setState(() => _selectedId = id);
    final rows = await AccountingService.getTransactions(id);
    if (mounted && _selectedId == id) setState(() => _transactions = rows);
  }

  Future<void> _toggleActive(FinancialAccount account) async {
    try {
      await AccountingService.setAccountActive(account.id, !account.active);
      await _load(select: account.id);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _editAccount([FinancialAccount? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final institution =
        TextEditingController(text: existing?.institution ?? '');
    final number =
        TextEditingController(text: existing?.accountNumberMasked ?? '');
    final ifsc = TextEditingController(text: existing?.ifsc ?? '');
    final opening = TextEditingController(
        text: existing == null ? '0' : existing.openingBalance.toString());
    final notes = TextEditingController(text: existing?.notes ?? '');
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New $_title Account' : 'Edit Account'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Account name'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                ),
                if (widget.accountType == 'bank') ...[
                  TextField(
                      controller: institution,
                      decoration:
                          const InputDecoration(labelText: 'Bank name')),
                  TextField(
                      controller: number,
                      decoration: const InputDecoration(
                          labelText: 'Account number (masked)',
                          hintText: 'e.g. •••• 1234')),
                  TextField(
                      controller: ifsc,
                      decoration: const InputDecoration(labelText: 'IFSC')),
                ],
                if (existing == null)
                  TextFormField(
                    controller: opening,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Opening balance'),
                    validator: (v) => double.tryParse(v ?? '') == null
                        ? 'Enter a number'
                        : null,
                  ),
                TextField(
                    controller: notes,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes')),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final account = existing == null
        ? FinancialAccount(
            id: const Uuid().v4(),
            name: name.text.trim(),
            type: widget.accountType,
            institution: institution.text.trim(),
            accountNumberMasked: number.text.trim(),
            ifsc: ifsc.text.trim(),
            openingBalance: double.parse(opening.text),
            openingDate: DateTime.now(),
            notes: notes.text.trim(),
          )
        : existing.copyWith(
            name: name.text.trim(),
            institution: institution.text.trim(),
            accountNumberMasked: number.text.trim(),
            ifsc: ifsc.text.trim(),
            notes: notes.text.trim(),
          );
    try {
      await AccountingService.saveAccount(account);
      await _load(select: account.id);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _adjust() async {
    if (_selectedId == null) return;
    final amount = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Balance adjustment'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Signed amount',
                  helperText: 'Positive adds funds; negative removes funds'),
            ),
            TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Reason')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Post')),
        ],
      ),
    );
    final value = double.tryParse(amount.text.trim());
    if (ok != true || value == null || value == 0) return;
    try {
      await AccountingService.adjustBalance(
          accountId: _selectedId!,
          amount: value,
          date: DateTime.now(),
          reason: reason.text.trim());
      await _load(select: _selectedId);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _transfer() async {
    final all = await AccountingService.getAccounts();
    if (!mounted || all.length < 2) {
      _error('Create another cash or bank account first.');
      return;
    }
    String from = _selectedId ?? all.first.id;
    String to = all.firstWhere((a) => a.id != from).id;
    final amount = TextEditingController();
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Transfer funds'),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                  value: from,
                  decoration: const InputDecoration(labelText: 'From'),
                  items: all
                      .map((a) =>
                          DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) => setDialogState(() {
                        from = v!;
                        if (to == from) {
                          to = all.firstWhere((a) => a.id != from).id;
                        }
                      })),
              DropdownButtonFormField<String>(
                  value: to,
                  decoration: const InputDecoration(labelText: 'To'),
                  items: all
                      .where((a) => a.id != from)
                      .map((a) =>
                          DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => to = v!)),
              TextField(
                  controller: amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount')),
              TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Notes')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Transfer')),
          ],
        ),
      ),
    );
    final value = double.tryParse(amount.text.trim());
    if (ok != true || value == null || value <= 0) return;
    try {
      await AccountingService.transfer(
          fromAccountId: from,
          toAccountId: to,
          amount: value,
          date: DateTime.now(),
          notes: notes.text.trim());
      await _load(select: from);
    } catch (e) {
      _error(e);
    }
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString().replaceFirst('StateError: ', '')),
        backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    FinancialAccount? selected;
    for (final account in _accounts) {
      if (account.id == _selectedId) {
        selected = account;
        break;
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
              onPressed: _transfer,
              tooltip: 'Transfer',
              icon: const Icon(Icons.swap_horiz)),
          IconButton(
              onPressed: _selectedId == null ? null : _adjust,
              tooltip: 'Adjust balance',
              icon: const Icon(Icons.tune)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const AppLoadingState()
          : LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= _wideBreakpoint;
              final list = _accountPane(context, wide);
              final register = _register(selected);
              if (!wide) {
                return Column(children: [
                  _header(context, false),
                  _statusChips(),
                  _searchRow(),
                  const Divider(height: 1),
                  SizedBox(height: 300, child: list),
                  const Divider(height: 1),
                  Expanded(child: register),
                ]);
              }
              return Column(children: [
                _header(context, true),
                _statusChips(),
                _searchRow(),
                const Divider(height: 1),
                Expanded(
                  child: Row(children: [
                    SizedBox(width: 420, child: list),
                    const VerticalDivider(width: 1),
                    Expanded(child: register),
                  ]),
                ),
              ]);
            }),
      floatingActionButton: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _wideBreakpoint) {
            return const SizedBox();
          }
          return FloatingActionButton(
            onPressed: () => _editAccount(),
            tooltip: 'New Account',
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, bool wide) {
    final theme = Theme.of(context);
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
                  _title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_accounts.length} accounts · '
                  'Total $_currencySymbol ${_totalBalance.toStringAsFixed(2)}',
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
              onPressed: () => _editAccount(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Account'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChips() {
    final counts = _statusCounts;
    final options = <(String, String)>[
      ('all', 'All'),
      ('active', 'Active'),
      ('inactive', 'Inactive'),
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
                selected: _activeFilter == option.$1,
                label: Text('${option.$2} · ${counts[option.$1] ?? 0}'),
                onSelected: (_) => setState(() {
                  _activeFilter = option.$1;
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
        hintText: 'Search accounts...',
        onChanged: (value) => setState(() {
          _searchQuery = value;
          _currentPage = 0;
        }),
        onClear: _searchController.text.isEmpty ? null : () => _clearFilters(),
      ),
    );
  }

  Widget _accountPane(BuildContext context, bool wide) {
    if (_accounts.isEmpty) {
      return AppEmptyState(
          icon: widget.accountType == 'bank'
              ? Icons.account_balance
              : Icons.account_balance_wallet,
          title: 'No ${widget.accountType} accounts yet.',
          subtitle: 'Create your first account to track balances.',
          action: AppPrimaryButton(
            onPressed: () => _editAccount(),
            label: const Text('Create account'),
          ));
    }
    if (_visible.isEmpty) {
      return Center(
        child: AppEmptyState(
          icon: Icons.search_off,
          title: 'No accounts match this view.',
          subtitle: 'Try a different status or search.',
          action: OutlinedButton.icon(
            onPressed: _clearFilters,
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('Clear filters'),
          ),
        ),
      );
    }
    return Column(children: [
      Expanded(
        child: wide ? _accountsTable(context) : _accountsCards(),
      ),
      _accountsFooter(context),
    ]);
  }

  Widget _accountsTable(BuildContext context) {
    int? sortIndex;
    switch (_sortField) {
      case 'name':
        sortIndex = 0;
        break;
      case 'balance':
        sortIndex = 1;
        break;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: sortIndex,
            sortAscending: _sortAscending,
            showCheckboxColumn: false,
            columns: [
              DataColumn(
                label: const Text(
                  'Account',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onSort: (_, __) => _onSort('name'),
              ),
              DataColumn(
                label: const Text(
                  'Balance',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                numeric: true,
                onSort: (_, __) => _onSort('balance'),
              ),
              const DataColumn(
                label: Text(
                  'Status',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const DataColumn(label: Text('')),
            ],
            rows: [
              for (final account in _pageRows)
                DataRow(
                  selected: account.id == _selectedId,
                  onSelectChanged: (_) => _select(account.id),
                  cells: [
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              account.name,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (account.institution.isNotEmpty)
                              Text(
                                account.institution,
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
                    DataCell(
                      AppMoney(
                        _balances[account.id] ?? 0,
                        currencySymbol: account.currencySymbol,
                        bold: true,
                      ),
                    ),
                    DataCell(_statusPill(account.active)),
                    DataCell(_rowMenu(account)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountsCards() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: _pageRows.length,
      itemBuilder: (context, index) {
        final account = _pageRows[index];
        final selected = account.id == _selectedId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AppListRow(
            leading: AppRowIcon(widget.accountType == 'bank'
                ? Icons.account_balance
                : Icons.account_balance_wallet),
            title: account.name,
            subtitle: account.active
                ? (account.institution.isEmpty
                    ? 'Active'
                    : 'Active • ${account.institution}')
                : 'Inactive • ${account.institution}',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppMoney(
                  _balances[account.id] ?? 0,
                  currencySymbol: account.currencySymbol,
                  bold: true,
                ),
                _rowMenu(account),
              ],
            ),
            onTap: selected ? null : () => _select(account.id),
          ),
        );
      },
    );
  }

  Widget _accountsFooter(BuildContext context) {
    final total = _visible.length;
    if (total <= _pageSize) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          '$total of ${_accounts.length} accounts',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final start = _currentPage * _pageSize + 1;
    final end = ((_currentPage + 1) * _pageSize).clamp(0, total);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

  Widget _statusPill(bool active) {
    final color = active ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        active ? 'Active' : 'Inactive',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _rowMenu(FinancialAccount account) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) {
        switch (value) {
          case 'open':
            _select(account.id);
            break;
          case 'edit':
            _editAccount(account);
            break;
          case 'toggle':
            _toggleActive(account);
            break;
          case 'transfer':
            _transfer();
            break;
          case 'adjust':
            _select(account.id);
            _adjust();
            break;
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (account.id != 'cash-default')
          PopupMenuItem(
            value: 'toggle',
            child: Text(account.active ? 'Disable' : 'Enable'),
          ),
        const PopupMenuItem(value: 'transfer', child: Text('Transfer')),
        const PopupMenuItem(value: 'adjust', child: Text('Adjust balance')),
      ],
    );
  }

  Widget _register(FinancialAccount? account) {
    if (account == null) {
      return const AppEmptyState(
          icon: Icons.account_balance, title: 'Select an account');
    }
    final balance = _balances[account.id] ?? 0;
    final movementTotal =
        _transactions.fold<double>(0, (sum, tx) => sum + tx.amount);
    return Column(children: [
      ListTile(
        title:
            Text(account.name, style: Theme.of(context).textTheme.titleLarge),
        subtitle: Text(
            'Opening ${account.currencySymbol} ${account.openingBalance.toStringAsFixed(2)}'),
        trailing: Wrap(spacing: 4, children: [
          IconButton(
              onPressed: () => _editAccount(account),
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined)),
          if (account.id != 'cash-default')
            IconButton(
                onPressed: () => _toggleActive(account),
                tooltip: account.active ? 'Disable' : 'Enable',
                icon: Icon(account.active
                    ? Icons.block_outlined
                    : Icons.check_circle_outline)),
        ]),
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: .35),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _accountMetric('Current balance',
                '${account.currencySymbol} ${balance.toStringAsFixed(2)}'),
            _accountMetric('Opening balance',
                '${account.currencySymbol} ${account.openingBalance.toStringAsFixed(2)}'),
            _accountMetric('Movement total',
                '${movementTotal >= 0 ? '+' : ''}${account.currencySymbol} ${movementTotal.toStringAsFixed(2)}'),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(children: [
          Icon(Icons.fact_check_outlined,
              size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Expanded(
              child: Text('Account timeline',
                  style: TextStyle(fontWeight: FontWeight.w700))),
          Text('${_transactions.length} movements',
              style: Theme.of(context).textTheme.labelMedium),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _transactions.isEmpty
            ? const AppEmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No account movements yet.',
                subtitle: 'New transactions will appear here.')
            : ListView.separated(
                itemCount: _transactions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final tx = _transactions[index];
                  return ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                    leading: AppRowIcon(
                        tx.amount >= 0 ? Icons.south_west : Icons.north_east,
                        color: tx.amount >= 0 ? Colors.green : Colors.red),
                    title: Text(tx.reference.isEmpty ? tx.kind : tx.reference),
                    subtitle: Text(
                        '${tx.date.toLocal().toString().split(' ').first}${tx.notes.isEmpty ? '' : ' • ${tx.notes}'}'),
                    trailing: Text(
                        '${tx.amount >= 0 ? '+' : ''}${account.currencySymbol} ${tx.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: tx.amount >= 0 ? Colors.green : Colors.red)),
                  );
                }),
      ),
    ]);
  }

  Widget _accountMetric(String label, String value) => SizedBox(
        width: 175,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}
