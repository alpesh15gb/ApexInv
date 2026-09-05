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

  String get _title =>
      widget.accountType == 'bank' ? 'Bank Accounts' : 'Cash In Hand';

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _select(String id) async {
    setState(() => _selectedId = id);
    final rows = await AccountingService.getTransactions(id);
    if (mounted && _selectedId == id) setState(() => _transactions = rows);
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
          FilledButton.icon(
              onPressed: () => _editAccount(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New')),
          const SizedBox(width: 8),
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
              final list = _accountList();
              final register = _register(selected);
              if (constraints.maxWidth < 800) {
                return Column(children: [
                  SizedBox(height: 210, child: list),
                  const Divider(height: 1),
                  Expanded(child: register),
                ]);
              }
              return Row(children: [
                SizedBox(width: 340, child: list),
                const VerticalDivider(width: 1),
                Expanded(child: register),
              ]);
            }),
    );
  }

  Widget _accountList() => _accounts.isEmpty
      ? AppEmptyState(
          icon: widget.accountType == 'bank'
              ? Icons.account_balance
              : Icons.account_balance_wallet,
          title: 'No ${widget.accountType} accounts yet.')
      : ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _accounts.length,
          itemBuilder: (context, index) {
            final account = _accounts[index];
            final selected = account.id == _selectedId;
            return ListTile(
              selected: selected,
              leading: AppRowIcon(widget.accountType == 'bank'
                  ? Icons.account_balance
                  : Icons.account_balance_wallet),
              title: Text(account.name),
              subtitle: Text(account.active
                  ? account.institution
                  : 'Inactive • ${account.institution}'),
              trailing: AppMoney((_balances[account.id] ?? 0),
                  currencySymbol: account.currencySymbol, bold: true),
              onTap: () => _select(account.id),
            );
          });

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
                onPressed: () async {
                  try {
                    await AccountingService.setAccountActive(
                        account.id, !account.active);
                    await _load(select: account.id);
                  } catch (e) {
                    _error(e);
                  }
                },
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
                title: 'No account movements yet.')
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
