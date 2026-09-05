import 'package:flutter/material.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/widgets/app/app.dart';

class ChequesScreen extends StatefulWidget {
  const ChequesScreen({super.key});

  @override
  State<ChequesScreen> createState() => _ChequesScreenState();
}

class _ChequesScreenState extends State<ChequesScreen> {
  List<ChequeRecord> _cheques = const [];
  String? _filter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AccountingService.getCheques(status: _filter);
    if (mounted)
      setState(() {
        _cheques = rows;
        _loading = false;
      });
  }

  Future<void> _create() async {
    String direction = 'received';
    final party = TextEditingController();
    final amount = TextEditingController();
    final number = TextEditingController();
    final notes = TextEditingController();
    DateTime chequeDate = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
                title: const Text('Add cheque'),
                content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: 'received', label: Text('Received')),
                          ButtonSegment(value: 'issued', label: Text('Issued')),
                        ],
                        selected: {direction},
                        onSelectionChanged: (v) =>
                            setDialogState(() => direction = v.first),
                      ),
                      TextField(
                          controller: party,
                          autofocus: true,
                          decoration:
                              const InputDecoration(labelText: 'Party')),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Amount')),
                      TextField(
                          controller: number,
                          decoration: const InputDecoration(
                              labelText: 'Cheque number')),
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Cheque date'),
                          trailing: TextButton(
                              child: Text(chequeDate
                                  .toLocal()
                                  .toString()
                                  .split(' ')
                                  .first),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: chequeDate,
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime.now()
                                        .add(const Duration(days: 730)));
                                if (picked != null)
                                  setDialogState(() => chequeDate = picked);
                              })),
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
                      child: const Text('Save')),
                ],
              )),
    );
    final value = double.tryParse(amount.text.trim());
    if (ok != true ||
        value == null ||
        value <= 0 ||
        party.text.trim().isEmpty ||
        number.text.trim().isEmpty) return;
    try {
      await AccountingService.addManualCheque(
          direction: direction,
          partyName: party.text.trim(),
          amount: value,
          chequeNumber: number.text.trim(),
          chequeDate: chequeDate,
          notes: notes.text.trim());
      await _load();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _transition(ChequeRecord cheque, String status) async {
    String? bankId = cheque.bankAccountId;
    if (status == 'deposited' || status == 'cleared') {
      final banks = await AccountingService.getAccounts(type: 'bank');
      if (!mounted) return;
      if (banks.isEmpty) {
        _error('Create a bank account first.');
        return;
      }
      bankId ??= banks.first.id;
      bankId = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(status == 'cleared' ? 'Clear cheque' : 'Deposit cheque'),
          content: SizedBox(
              width: 420,
              child: DropdownButtonFormField<String>(
                value: bankId,
                decoration: const InputDecoration(labelText: 'Bank account'),
                items: banks
                    .map((a) =>
                        DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (v) => bankId = v,
              )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, bankId),
                child: Text(status == 'cleared' ? 'Clear' : 'Deposit')),
          ],
        ),
      );
      if (bankId == null) return;
    }
    try {
      await AccountingService.transitionCheque(
          chequeId: cheque.id, status: status, bankAccountId: bankId);
      await _load();
    } catch (e) {
      _error(e);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('StateError: ', '')),
        backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Cheques'), actions: [
          FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add')),
          const SizedBox(width: 8),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
        ]),
        body: Column(children: [
          SizedBox(
              height: 58,
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                scrollDirection: Axis.horizontal,
                children: [
                  null,
                  'pending',
                  'deposited',
                  'cleared',
                  'bounced',
                  'cancelled'
                ]
                    .map((status) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          selected: _filter == status,
                          label: Text(status == null
                              ? 'All'
                              : '${status[0].toUpperCase()}${status.substring(1)}'),
                          onSelected: (_) {
                            setState(() => _filter = status);
                            _load();
                          },
                        )))
                    .toList(),
              )),
          const Divider(height: 1),
          Expanded(
              child: _loading
                  ? const AppLoadingState()
                  : _cheques.isEmpty
                      ? const AppEmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No cheques in this view.')
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _cheques.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) =>
                              _tile(_cheques[index]))),
        ]),
      );

  Widget _tile(ChequeRecord cheque) {
    final actions = <PopupMenuEntry<String>>[];
    if (cheque.status == 'pending' && cheque.direction == 'received') {
      actions.add(const PopupMenuItem(
          value: 'deposited', child: Text('Mark deposited')));
    }
    if (cheque.status == 'pending' || cheque.status == 'deposited') {
      actions.add(
          const PopupMenuItem(value: 'cleared', child: Text('Mark cleared')));
      actions.add(
          const PopupMenuItem(value: 'bounced', child: Text('Mark bounced')));
      actions
          .add(const PopupMenuItem(value: 'cancelled', child: Text('Cancel')));
    } else if (cheque.status == 'cleared') {
      actions.add(
          const PopupMenuItem(value: 'bounced', child: Text('Record bounce')));
    }
    final color = switch (cheque.status) {
      'cleared' => Colors.green,
      'bounced' || 'cancelled' => Colors.red,
      'deposited' => Colors.blue,
      _ => Colors.orange,
    };
    final stage = _stageFor(cheque.status);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            leading: AppRowIcon(
                cheque.direction == 'received'
                    ? Icons.call_received
                    : Icons.call_made,
                color: color),
            title: Text('${cheque.partyName} • ${cheque.chequeNumber}'),
            subtitle: Text(
                '${cheque.direction == 'received' ? 'Received' : 'Issued'} • '
                '${cheque.chequeDate.toLocal().toString().split(' ').first} • ${cheque.status}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              AppMoney(cheque.amount,
                  currencySymbol: cheque.currencySymbol, bold: true),
              if (actions.isNotEmpty)
                PopupMenuButton<String>(
                    itemBuilder: (_) => actions,
                    onSelected: (status) => _transition(cheque, status)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(children: [
              for (var i = 0; i < 4; i++) ...[
                _stageDot(
                    i,
                    stage,
                    cheque.status == 'bounced' || cheque.status == 'cancelled'
                        ? ['Received', 'Deposited', 'Cleared', 'Returned'][i]
                        : ['Received', 'Deposited', 'Cleared', 'Closed'][i],
                    terminal: cheque.status == 'bounced' ||
                        cheque.status == 'cancelled'),
                if (i < 3)
                  Expanded(
                      child: Container(
                          height: 2,
                          color: i < stage
                              ? color
                              : Theme.of(context).colorScheme.outlineVariant)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  int _stageFor(String status) => switch (status) {
        'deposited' => 1,
        'cleared' => 2,
        // A returned cheque is terminal, not evidence that it was deposited
        // or cleared. Keep the preceding lifecycle steps inactive.
        'bounced' || 'cancelled' => 0,
        _ => 0,
      };

  Widget _stageDot(int index, int current, String label,
      {bool terminal = false}) {
    final active = terminal ? index == 3 || index <= current : index <= current;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(active ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline),
      const SizedBox(height: 3),
      Text(label, style: const TextStyle(fontSize: 10)),
    ]);
  }
}
