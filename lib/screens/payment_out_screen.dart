import 'package:flutter/material.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/purchase_bill.dart';

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

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    for (final c in _allocations.values) { c.dispose(); }
    _notes.dispose(); _chequeNumber.dispose(); super.dispose();
  }

  Future<void> _load() async {
    final bills = (await PurchaseBillService.getBills())
        .where((b) => b.outstanding > 0.005).toList();
    final accounts = await AccountingService.getAccounts();
    if (!mounted) return;
    for (final c in _allocations.values) { c.dispose(); }
    _allocations.clear();
    for (final bill in bills) { _allocations[bill.id] = TextEditingController(); }
    final suppliers = bills.map((b) => b.supplierName).toSet();
    setState(() {
      _bills = bills; _accounts = accounts;
      if (_supplier == null || !suppliers.contains(_supplier)) {
        _supplier = suppliers.isEmpty ? null : suppliers.first;
      }
      _chooseDefaultAccount();
      _loading = false;
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

  double get _allocated => _visible.fold(0, (sum, bill) =>
      sum + (double.tryParse(_allocations[bill.id]?.text.trim() ?? '') ?? 0));

  void _autoAllocate() {
    for (final bill in _visible) {
      _allocations[bill.id]?.text = bill.outstanding.toStringAsFixed(2);
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    final selected = _visible.map((bill) => (bill: bill,
      amount: double.tryParse(_allocations[bill.id]?.text.trim() ?? '') ?? 0))
      .where((a) => a.amount > 0).toList();
    if (selected.isEmpty) { _error('Enter an allocation for at least one bill.'); return; }
    setState(() => _saving = true);
    try {
      if (_method == 'Check') {
        if (selected.length != 1) {
          throw StateError('One cheque can be linked to one bill in this version');
        }
        await PurchaseBillService.recordPayment(selected.first.bill.id,
          selected.first.amount, datePaid: _date, paymentMethod: _method,
          accountId: _accountId, chequeNumber: _chequeNumber.text.trim(),
          chequeDate: _chequeDate, notes: _notes.text.trim());
      } else {
        await PurchaseBillService.recordPaymentBatch(
          allocations: selected, datePaid: _date, paymentMethod: _method,
          accountId: _accountId, notes: _notes.text.trim());
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Payment of ${selected.first.bill.currencySymbol} '
          '${_allocated.toStringAsFixed(2)} posted.'), backgroundColor: Colors.green));
      _notes.clear(); _chequeNumber.clear();
      await _load();
    } catch (e) { _error(e); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(e.toString().replaceFirst('StateError: ', '')),
      backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = _bills.map((b) => b.supplierName).toSet().toList()..sort();
    final accountType = _method == 'Cash' ? 'cash' : 'bank';
    final accountChoices = _accounts.where((a) => a.type == accountType).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Out'), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        const SizedBox(width: 8),
      ]),
      body: _loading ? const Center(child: CircularProgressIndicator()) :
        _bills.isEmpty ? const Center(child: Text('There are no outstanding purchase bills.')) :
        Column(children: [
          Padding(padding: const EdgeInsets.all(16), child: LayoutBuilder(
            builder: (context, constraints) {
              final fields = <Widget>[
                DropdownButtonFormField<String>(value: _supplier,
                  decoration: const InputDecoration(labelText: 'Supplier', border: OutlineInputBorder()),
                  items: suppliers.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) => setState(() => _supplier = v)),
                DropdownButtonFormField<String>(value: _method,
                  decoration: const InputDecoration(labelText: 'Method', border: OutlineInputBorder()),
                  items: const ['Cash', 'Bank Transfer', 'Online', 'Check']
                    .map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                  onChanged: (v) => setState(() { _method = v!; _chooseDefaultAccount(); })),
                DropdownButtonFormField<String>(value: accountChoices.any((a) => a.id == _accountId) ? _accountId : null,
                  decoration: const InputDecoration(labelText: 'Pay from', border: OutlineInputBorder()),
                  items: accountChoices.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(),
                  onChanged: (v) => setState(() => _accountId = v)),
                InkWell(onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: _date,
                    firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (picked != null) setState(() => _date = picked);
                }, child: InputDecorator(decoration: const InputDecoration(
                    labelText: 'Payment date', border: OutlineInputBorder()),
                  child: Text(_date.toLocal().toString().split(' ').first))),
              ];
              if (constraints.maxWidth < 760) return Column(children: fields
                .map((w) => Padding(padding: const EdgeInsets.only(bottom: 10), child: w)).toList());
              return Row(children: fields.map((w) => Expanded(child: Padding(
                padding: const EdgeInsets.only(right: 10), child: w))).toList());
            })),
          if (_method == 'Check') Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: TextField(controller: _chequeNumber,
                decoration: const InputDecoration(labelText: 'Cheque number', border: OutlineInputBorder()))),
              const SizedBox(width: 10),
              Expanded(child: ListTile(title: const Text('Cheque date'),
                subtitle: Text(_chequeDate.toLocal().toString().split(' ').first),
                onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: _chequeDate,
                    firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 730)));
                  if (picked != null) setState(() => _chequeDate = picked);
                })),
            ])),
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: Row(children: [
            Text('Open bills for $_supplier', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(), TextButton(onPressed: _autoAllocate, child: const Text('Allocate all')),
          ])),
          Expanded(child: ListView.separated(itemCount: _visible.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final bill = _visible[index];
              return ListTile(
                title: Text(bill.billNumber ?? bill.id),
                subtitle: Text('${bill.date.toLocal().toString().split(' ').first} '
                  '• Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}'),
                trailing: SizedBox(width: 180, child: TextField(
                  controller: _allocations[bill.id],
                  onChanged: (_) => setState(() {}),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Pay', prefixText: '${bill.currencySymbol} ',
                    border: const OutlineInputBorder(), isDense: true))),
              );
            })),
          Container(padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer),
            child: Row(children: [
              Expanded(child: TextField(controller: _notes,
                decoration: const InputDecoration(labelText: 'Reference / notes', border: OutlineInputBorder()))),
              const SizedBox(width: 16),
              Text('Allocated ${_visible.isEmpty ? '' : _visible.first.currencySymbol} ${_allocated.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 16),
              FilledButton.icon(onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.payments_outlined),
                label: Text(_saving ? 'Posting…' : 'Post payment')),
            ])),
        ]),
    );
  }
}
