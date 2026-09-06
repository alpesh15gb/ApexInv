import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:apexbooks/database/expense_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/expense.dart';
import 'package:apexbooks/models/expense_category.dart';
import 'package:apexbooks/widgets/app/app.dart';

class ExpenseManagementScreen extends ConsumerStatefulWidget {
  const ExpenseManagementScreen({super.key});

  @override
  ConsumerState<ExpenseManagementScreen> createState() =>
      _ExpenseManagementScreenState();
}

class _ExpenseManagementScreenState
    extends ConsumerState<ExpenseManagementScreen> {
  List<Expense> _expenses = [];
  List<ExpenseCategory> _categories = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedCategoryId;
  int _currentPage = 0;
  final int _pageSize = 50;
  int _totalCount = 0;
  double _totalAmount = 0.0;

  // ── Presentation-only state (in-memory over the already-loaded page) ──
  // The server query in _loadData is untouched: search + category still
  // filter server-side with pagination. [_view] and sorting below only
  // re-arrange the rows already fetched for this page.
  final TextEditingController _searchController = TextEditingController();
  String _view = 'all'; // all | month | cash | bank
  String _sortField = 'date'; // date | amount | description
  bool _sortAscending = false;

  static const double _wideBreakpoint = 800;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final categories = await ExpenseService.getAllCategories();
    final expenses = await ExpenseService.getExpensesPaginated(
      offset: _currentPage * _pageSize,
      limit: _pageSize,
      query: _searchQuery,
      categoryId: _selectedCategoryId,
    );
    final count = await ExpenseService.getExpenseCount(
      query: _searchQuery,
      categoryId: _selectedCategoryId,
    );
    final total = await ExpenseService.getTotalExpenses();
    if (mounted) {
      setState(() {
        _categories = categories;
        _expenses = expenses;
        _totalCount = count;
        _totalAmount = total;
        _isLoading = false;
      });
    }
  }

  // ── In-memory aggregation over already-loaded rows ──────────────────────

  Map<String, int> get _viewCounts {
    final now = DateTime.now();
    var month = 0, cash = 0, bank = 0;
    for (final e in _expenses) {
      if (e.date.year == now.year && e.date.month == now.month) month++;
      if ((e.paymentMethod ?? '') == 'Cash') {
        cash++;
      } else if ((e.paymentMethod ?? '') == 'Bank Transfer' ||
          (e.paymentMethod ?? '') == 'Online') {
        bank++;
      }
    }
    return {
      'all': _expenses.length,
      'month': month,
      'cash': cash,
      'bank': bank,
    };
  }

  List<Expense> get _visible {
    final now = DateTime.now();
    final filtered = _expenses.where((e) {
      switch (_view) {
        case 'month':
          return e.date.year == now.year && e.date.month == now.month;
        case 'cash':
          return (e.paymentMethod ?? '') == 'Cash';
        case 'bank':
          return (e.paymentMethod ?? '') == 'Bank Transfer' ||
              (e.paymentMethod ?? '') == 'Online';
        default:
          return true;
      }
    }).toList();
    filtered.sort((a, b) {
      int result;
      switch (_sortField) {
        case 'amount':
          result = a.amount.compareTo(b.amount);
          break;
        case 'description':
          result = a.description.toLowerCase().compareTo(
                b.description.toLowerCase(),
              );
          break;
        default:
          result = a.date.compareTo(b.date);
      }
      return _sortAscending ? result : -result;
    });
    return filtered;
  }

  void _onSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == 'description';
      }
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _selectedCategoryId = null;
      _view = 'all';
      _currentPage = 0;
    });
    _loadData();
  }

  String _categoryName(Expense e) =>
      (e.categoryName == null || e.categoryName!.isEmpty)
          ? e.categoryId
          : e.categoryName!;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadData,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideBreakpoint;
          return Column(
            children: [
              _header(context, wide, currencyFormat),
              _viewChips(),
              _filterRow(context, wide),
              const Divider(height: 1),
              Expanded(
                child: _isLoading
                    ? const AppLoadingState()
                    : _expenses.isEmpty
                        ? Center(
                            child: AppEmptyState(
                              icon: Icons.receipt_long,
                              title: 'No expenses yet.',
                              subtitle:
                                  'Record business spending to track costs.',
                              action: AppPrimaryButton(
                                onPressed: _showAddExpenseDialog,
                                label: const Text('Record expense'),
                              ),
                            ),
                          )
                        : _visible.isEmpty
                            ? Center(
                                child: AppEmptyState(
                                  icon: Icons.search_off,
                                  title: 'No expenses match this view.',
                                  subtitle:
                                      'Try a different view, search or category.',
                                  action: OutlinedButton.icon(
                                    onPressed: _clearFilters,
                                    icon: const Icon(Icons.clear_all, size: 18),
                                    label: const Text('Clear filters'),
                                  ),
                                ),
                              )
                            : wide
                                ? _table(context, colorScheme)
                                : _cards(context, colorScheme),
              ),
              _paginationFooter(context),
            ],
          );
        },
      ),
      floatingActionButton: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _wideBreakpoint) return const SizedBox();
          return FloatingActionButton(
            onPressed: _showAddExpenseDialog,
            tooltip: 'New Expense',
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, bool wide, NumberFormat currencyFormat) {
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
                  'Expenses',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Record business spending to track costs.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_totalCount records · Total ${currencyFormat.format(_totalAmount)}',
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
              onPressed: _showAddExpenseDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Expense'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _viewChips() {
    final counts = _viewCounts;
    final views = <(String, String)>[
      ('all', 'All'),
      ('month', 'This month'),
      ('cash', 'Cash'),
      ('bank', 'Bank/Online'),
    ];
    return SizedBox(
      height: 52,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        scrollDirection: Axis.horizontal,
        children: [
          for (final view in views)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _view == view.$1,
                label: Text('${view.$2} · ${counts[view.$1] ?? 0}'),
                onSelected: (_) => setState(() => _view = view.$1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterRow(BuildContext context, bool wide) {
    final search = AppSearchField(
      controller: _searchController,
      hintText: 'Search expenses...',
      onChanged: (value) {
        _searchQuery = value;
        _currentPage = 0;
        _loadData();
      },
      onClear: _searchController.text.isEmpty ? null : _clearFilters,
    );
    final category = DropdownButtonFormField<String?>(
      value: _selectedCategoryId,
      isDense: true,
      decoration: InputDecoration(
        hintText: 'Category',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      items: [
        const DropdownMenuItem(
          value: null,
          child: Text('All Categories'),
        ),
        ..._categories.map((c) => DropdownMenuItem(
              value: c.id,
              child: Text(c.name),
            )),
      ],
      onChanged: (value) {
        _selectedCategoryId = value;
        _currentPage = 0;
        _loadData();
      },
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            Expanded(flex: 3, child: search),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: category),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        children: [
          search,
          const SizedBox(height: 8),
          category,
        ],
      ),
    );
  }

  Widget _table(BuildContext context, ColorScheme colorScheme) {
    int? sortIndex;
    switch (_sortField) {
      case 'description':
        sortIndex = 0;
        break;
      case 'date':
        sortIndex = 2;
        break;
      case 'amount':
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
              col('Expense', 'description'),
              const DataColumn(
                label: Text(
                  'Category',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              col('Date', 'date'),
              const DataColumn(
                label: Text(
                  'Method',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              col('Amount', 'amount', numeric: true),
              const DataColumn(label: Text('')),
            ],
            rows: [
              for (final expense in _visible)
                DataRow(cells: [
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            expense.description,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if ((expense.notes ?? '').isNotEmpty)
                            Text(
                              expense.notes!,
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
                  DataCell(Text(_categoryName(expense))),
                  DataCell(
                      Text(DateFormat('dd MMM yyyy').format(expense.date))),
                  DataCell(Text(expense.paymentMethod ?? '—')),
                  DataCell(
                    AppMoney(
                      expense.amount,
                      currencySymbol: '₹',
                      bold: true,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ),
                  DataCell(
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, size: 20),
                      onSelected: (action) {
                        if (action == 'edit') {
                          _showEditExpenseDialog(expense);
                        }
                        if (action == 'delete') _deleteExpense(expense);
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('Edit'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Delete',
                                  style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cards(BuildContext context, ColorScheme colorScheme) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _visible.length,
      itemBuilder: (context, index) {
        final expense = _visible[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AppListRow(
            leading: AppRowIcon(Icons.receipt, color: colorScheme.primary),
            title: expense.description,
            subtitle:
                '${_categoryName(expense)} • ${DateFormat('dd MMM yyyy').format(expense.date)}',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppMoney(expense.amount,
                    currencySymbol: '₹',
                    bold: true,
                    style: TextStyle(color: colorScheme.error)),
                PopupMenuButton<String>(
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 18),
                          SizedBox(width: 8),
                          Text('Edit'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 18, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (action) {
                    if (action == 'edit') _showEditExpenseDialog(expense);
                    if (action == 'delete') _deleteExpense(expense);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _paginationFooter(BuildContext context) {
    if (_totalCount <= 0) return const SizedBox();
    final totalPages = (_totalCount / _pageSize).ceil().clamp(1, 1 << 30);
    final start = _totalCount == 0 ? 0 : _currentPage * _pageSize + 1;
    final end = ((_currentPage + 1) * _pageSize).clamp(0, _totalCount);
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
              'Showing $start–$end of $_totalCount',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed: _currentPage > 0
                ? () {
                    _currentPage--;
                    _loadData();
                  }
                : null,
          ),
          Text(
            'Page ${_currentPage + 1} of $totalPages',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: (_currentPage + 1) * _pageSize < _totalCount
                ? () {
                    _currentPage++;
                    _loadData();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  void _showAddExpenseDialog() {
    _showExpenseDialog();
  }

  void _showEditExpenseDialog(Expense expense) {
    _showExpenseDialog(expense: expense);
  }

  Future<void> _showExpenseDialog({Expense? expense}) async {
    final accounts = await AccountingService.getAccounts();
    if (!mounted) return;
    final descriptionController =
        TextEditingController(text: expense?.description ?? '');
    final amountController = TextEditingController(
      text: expense != null ? expense.amount.toStringAsFixed(2) : '',
    );
    final notesController = TextEditingController(text: expense?.notes ?? '');
    String selectedCategoryId = expense?.categoryId ??
        (_categories.isNotEmpty ? _categories.first.id : '');
    DateTime selectedDate = expense?.date ?? DateTime.now();
    String paymentMethod = expense?.paymentMethod ?? 'Cash';
    String? accountId = expense?.accountId;
    List<FinancialAccount> accountChoices() => accounts
        .where((a) => a.type == (paymentMethod == 'Cash' ? 'cash' : 'bank'))
        .toList();
    final initialChoices = accountChoices();
    if (accountId == null && initialChoices.isNotEmpty) {
      accountId = initialChoices.first.id;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(expense == null ? 'New Expense' : 'Edit Expense'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionHeader('1 · Expense details'),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description *',
                    hintText: 'e.g. Office rent',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedCategoryId,
                  decoration: const InputDecoration(labelText: 'Category *'),
                  items: _categories
                      .map((c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(c.name),
                          ))
                      .toList(),
                  onChanged: (v) =>
                      setDialogState(() => selectedCategoryId = v ?? ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  decoration: const InputDecoration(
                    labelText: 'Amount *',
                    hintText: '0.00',
                    prefixText: '₹ ',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const AppSectionHeader('2 · Payment'),
                DropdownButtonFormField<String>(
                  value: paymentMethod,
                  decoration:
                      const InputDecoration(labelText: 'Payment method'),
                  items: const ['Cash', 'Bank Transfer', 'Online', 'Other']
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setDialogState(() {
                    paymentMethod = v ?? 'Cash';
                    final choices = accountChoices();
                    accountId = choices.isEmpty ? null : choices.first.id;
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: accountChoices().any((a) => a.id == accountId)
                      ? accountId
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Pay from',
                    helperText: 'Pick the cash or bank account used.',
                  ),
                  items: accountChoices()
                      .map((a) => DropdownMenuItem<String>(
                            value: a.id,
                            child: Text(a.name),
                          ))
                      .toList(),
                  onChanged: (v) => setDialogState(() => accountId = v),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date'),
                  subtitle:
                      Text(DateFormat('dd MMM yyyy').format(selectedDate)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedDate = picked);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'Any additional notes',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (descriptionController.text.isEmpty ||
                    amountController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Description and amount are required')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(expense == null ? 'Save expense' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final amount = double.tryParse(amountController.text) ?? 0;
      if (amount <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Amount must be greater than 0')),
          );
        }
        return;
      }

      final wasNew = expense == null;
      if (expense == null) {
        // Trial/licence gate: new expenses only; edits stay allowed.
        if (!await LicenseGate.canCreate(context)) return;
        final id = 'exp-${DateTime.now().millisecondsSinceEpoch}';
        await ExpenseService.insertExpense(Expense(
          id: id,
          description: descriptionController.text,
          amount: amount,
          date: selectedDate,
          categoryId: selectedCategoryId,
          paymentMethod: paymentMethod,
          notes: notesController.text,
          accountId: accountId,
        ));
      } else {
        await ExpenseService.updateExpense(expense.copyWith(
          description: descriptionController.text,
          amount: amount,
          date: selectedDate,
          categoryId: selectedCategoryId,
          paymentMethod: paymentMethod,
          notes: notesController.text,
          accountId: accountId,
        ));
      }
      _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasNew ? 'Expense recorded.' : 'Expense updated.'),
          backgroundColor: Colors.green,
        ));
      }
    }
  }

  Future<void> _deleteExpense(Expense expense) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Expense'),
        content:
            Text('Are you sure you want to delete "${expense.description}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ExpenseService.deleteExpense(expense.id);
      _loadData();
    }
  }
}
