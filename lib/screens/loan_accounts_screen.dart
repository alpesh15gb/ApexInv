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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final loans = await AccountingService.getLoans();
    final outstanding = <String, double>{};
    for (final loan in loans) {
      outstanding[loan.id] =
          await AccountingService.getLoanOutstanding(loan.id);
    }
    if (mounted)
      setState(() {
        _loans = loans;
        _outstanding = outstanding;
        _loading = false;
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
                                  if (picked != null)
                                    setDialogState(() => startDate = picked);
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
                                  if (picked != null)
                                    setDialogState(() => maturityDate = picked);
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
        lender.text.trim().isEmpty) return;
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
                                  if (picked != null)
                                    setDialogState(() => date = picked);
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
                          icon: Icons.history, title: 'No movements')
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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Loan Accounts'), actions: [
          FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New Loan')),
          const SizedBox(width: 8),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
        ]),
        body: _loading
            ? const AppLoadingState()
            : _loans.isEmpty
                ? const AppEmptyState(
                    icon: Icons.request_quote_outlined,
                    title: 'No loan accounts yet.')
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _loans.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      if (index == 0) return _loanSummary();
                      final loan = _loans[index - 1];
                      final outstanding = _outstanding[loan.id] ?? 0;
                      final progress = loan.originalPrincipal <= 0
                          ? 0.0
                          : (1 - outstanding / loan.originalPrincipal)
                              .clamp(0, 1)
                              .toDouble();
                      return AppCard(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Row(children: [
                              const AppRowIcon(Icons.request_quote_outlined),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(loan.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    Text(
                                        '${loan.lender} • ${loan.annualInterestRate.toStringAsFixed(2)}% p.a.')
                                  ])),
                              Chip(label: Text(loan.status)),
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
                            Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                      onPressed: () => _history(loan),
                                      icon: const Icon(Icons.history),
                                      label: const Text('History')),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                      onPressed: loan.status == 'closed'
                                          ? null
                                          : () => _repay(loan),
                                      icon: const Icon(Icons.payments_outlined),
                                      label: const Text('Repay')),
                                ]),
                          ]));
                    }),
      );

  Widget _loanSummary() {
    final total =
        _outstanding.values.fold<double>(0, (sum, value) => sum + value);
    return AppCard(
        child: Wrap(spacing: 32, runSpacing: 12, children: [
      _metric('Active loans',
          '${_loans.where((l) => l.status != 'closed').length}'),
      _metric('Total outstanding', total.toStringAsFixed(2)),
      _metric('Closed', '${_loans.where((l) => l.status == 'closed').length}'),
    ]));
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
