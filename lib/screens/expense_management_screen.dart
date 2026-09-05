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

  @override
  void initState() {
    super.initState();
    _loadData();
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          FilledButton.icon(
            onPressed: () => _showAddExpenseDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Create'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Stats card
          Container(
            padding: const EdgeInsets.all(16),
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useRow = constraints.maxWidth > 400;
                if (useRow) {
                  return Row(
                    children: [
                      _buildStatChip(
                        'Total Expenses',
                        currencyFormat.format(_totalAmount),
                        Icons.receipt,
                        colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      _buildStatChip(
                        'Count',
                        _totalCount.toString(),
                        Icons.numbers,
                        colorScheme.secondary,
                      ),
                    ],
                  );
                }
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _buildStatChip(
                      'Total Expenses',
                      currencyFormat.format(_totalAmount),
                      Icons.receipt,
                      colorScheme.primary,
                    ),
                    _buildStatChip(
                      'Count',
                      _totalCount.toString(),
                      Icons.numbers,
                      colorScheme.secondary,
                    ),
                  ],
                );
              },
            ),
          ),

          // Search and filter bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 400) {
                  return Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Search expenses...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: (value) {
                            _searchQuery = value;
                            _currentPage = 0;
                            _loadData();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String?>(
                          value: _selectedCategoryId,
                          isDense: true,
                          decoration: InputDecoration(
                            hintText: 'Category',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
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
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search expenses...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onChanged: (value) {
                        _searchQuery = value;
                        _currentPage = 0;
                        _loadData();
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      value: _selectedCategoryId,
                      isDense: true,
                      decoration: InputDecoration(
                        hintText: 'Category',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
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
                    ),
                  ],
                );
              },
            ),
          ),

          // Expense list
          Expanded(
            child: _isLoading
                ? const AppLoadingState()
                : _expenses.isEmpty
                    ? Center(
                        child: AppEmptyState(
                          icon: Icons.receipt_long,
                          title: 'No expenses found',
                          action: FilledButton.tonal(
                            onPressed: _showAddExpenseDialog,
                            child: const Text('Add First Expense'),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _expenses.length,
                        itemBuilder: (context, index) {
                          final expense = _expenses[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: AppListRow(
                              leading: AppRowIcon(Icons.receipt,
                                  color: colorScheme.primary),
                              title: expense.description,
                              subtitle:
                                  '${expense.categoryName ?? expense.categoryId} • ${DateFormat('dd MMM yyyy').format(expense.date)}',
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppMoney(expense.amount,
                                      currencySymbol: '₹',
                                      bold: true,
                                      style:
                                          TextStyle(color: colorScheme.error)),
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
                                            Icon(Icons.delete,
                                                size: 18, color: Colors.red),
                                            SizedBox(width: 8),
                                            Text('Delete',
                                                style: TextStyle(
                                                    color: Colors.red)),
                                          ],
                                        ),
                                      ),
                                    ],
                                    onSelected: (action) {
                                      if (action == 'edit')
                                        _showEditExpenseDialog(expense);
                                      if (action == 'delete')
                                        _deleteExpense(expense);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),

          // Pagination
          if (_totalCount > _pageSize)
            Container(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _currentPage > 0
                        ? () {
                            _currentPage--;
                            _loadData();
                          }
                        : null,
                  ),
                  Text(
                    'Page ${_currentPage + 1} of ${(_totalCount / _pageSize).ceil()}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: (_currentPage + 1) * _pageSize < _totalCount
                        ? () {
                            _currentPage++;
                            _loadData();
                          }
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatChip(
      String label, String value, IconData icon, Color color) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: color),
                ),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                ),
              ],
            ),
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
          title: Text(expense == null ? 'Add Expense' : 'Edit Expense'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description *',
                    hintText: 'e.g. Office rent',
                  ),
                ),
                const SizedBox(height: 12),
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
                  decoration: const InputDecoration(labelText: 'Pay from'),
                  items: accountChoices()
                      .map((a) => DropdownMenuItem<String>(
                            value: a.id,
                            child: Text(a.name),
                          ))
                      .toList(),
                  onChanged: (v) => setDialogState(() => accountId = v),
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
                    if (picked != null)
                      setDialogState(() => selectedDate = picked);
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
              child: Text(expense == null ? 'Add' : 'Save'),
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
