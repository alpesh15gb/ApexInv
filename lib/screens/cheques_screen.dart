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
  // All rows are loaded once with the existing query; status / direction /
  // search / sort / pagination below are presentation-only in-memory views.
  // Postings, reversals and transitions still go through AccountingService.
  List<ChequeRecord> _cheques = const [];
  String? _filter;
  String _direction = 'all'; // all | received | issued
  String _searchQuery = '';
  String _sortField = 'date'; // date | amount | party
  bool _sortAscending = false;
  int _currentPage = 0;
  static const int _pageSize = 10;
  bool _loading = true;
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
    final rows = await AccountingService.getCheques();
    if (mounted) {
      setState(() {
        _cheques = rows;
        _loading = false;
      });
    }
  }

  Map<String, int> get _statusCounts {
    final counts = <String, int>{
      'pending': 0,
      'deposited': 0,
      'cleared': 0,
      'bounced': 0,
      'cancelled': 0,
    };
    for (final c in _cheques) {
      counts[c.status] = (counts[c.status] ?? 0) + 1;
    }
    return counts;
  }

  List<ChequeRecord> get _filtered {
    final q = _searchQuery.trim().toLowerCase();
    return _cheques.where((c) {
      if (_filter != null && c.status != _filter) return false;
      if (_direction != 'all' && c.direction != _direction) return false;
      if (q.isNotEmpty &&
          !c.partyName.toLowerCase().contains(q) &&
          !c.chequeNumber.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  List<ChequeRecord> get _visible {
    final rows = _filtered;
    rows.sort((a, b) {
      int result;
      switch (_sortField) {
        case 'amount':
          result = a.amount.compareTo(b.amount);
          break;
        case 'party':
          result = a.partyName.toLowerCase().compareTo(
                b.partyName.toLowerCase(),
              );
          break;
        default:
          result = a.chequeDate.compareTo(b.chequeDate);
      }
      return _sortAscending ? result : -result;
    });
    return rows;
  }

  List<ChequeRecord> get _pageRows {
    final rows = _visible;
    final start = _currentPage * _pageSize;
    if (start >= rows.length) return const [];
    final end = (start + _pageSize).clamp(0, rows.length);
    return rows.sublist(start, end);
  }

  int get _totalPages => (_visible.length / _pageSize).ceil().clamp(1, 1 << 30);

  void _resetPage() => _currentPage = 0;

  void _onSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAscending = !_sortAscending;
      } else {
        _sortField = field;
        _sortAscending = field == 'party';
      }
      _resetPage();
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _filter = null;
      _direction = 'all';
      _searchQuery = '';
      _resetPage();
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
                                if (picked != null) {
                                  setDialogState(() => chequeDate = picked);
                                }
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
        number.text.trim().isEmpty) {
      return;
    }
    try {
      await AccountingService.addManualCheque(
          direction: direction,
          partyName: party.text.trim(),
          amount: value,
          chequeNumber: number.text.trim(),
          chequeDate: chequeDate,
          notes: notes.text.trim());
      _resetPage();
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cheques'), actions: [
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
              _filterRow(context, wide),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const AppLoadingState()
                    : _cheques.isEmpty
                        ? AppEmptyState(
                            icon: Icons.receipt_long_outlined,
                            title: 'No cheques yet.',
                            subtitle:
                                'Record a received or issued cheque to track it.',
                            action: AppPrimaryButton(
                              onPressed: _create,
                              label: const Text('Record cheque'),
                            ),
                          )
                        : _visible.isEmpty
                            ? Center(
                                child: AppEmptyState(
                                  icon: Icons.search_off,
                                  title: 'No cheques in this view.',
                                  subtitle:
                                      'Try a different status, direction or search.',
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
              if (!_loading && _cheques.isNotEmpty) _paginationFooter(context),
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
            tooltip: 'Record cheque',
            child: const Icon(Icons.add),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, bool wide) {
    final theme = Theme.of(context);
    final counts = _statusCounts;
    final pending = counts['pending'] ?? 0;
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
                  'Cheques',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Track received and issued cheques from pending to cleared.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_cheques.length} cheques · $pending pending',
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
              label: const Text('Record cheque'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChips() {
    final counts = _statusCounts;
    const statuses = [
      null,
      'pending',
      'deposited',
      'cleared',
      'bounced',
      'cancelled',
    ];
    return SizedBox(
      height: 52,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        scrollDirection: Axis.horizontal,
        children: [
          for (final status in statuses)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _filter == status,
                label: Text(status == null
                    ? 'All · ${_cheques.length}'
                    : '${status[0].toUpperCase()}${status.substring(1)} · ${counts[status] ?? 0}'),
                onSelected: (_) => setState(() {
                  _filter = status;
                  _resetPage();
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterRow(BuildContext context, bool wide) {
    final search = AppSearchField(
      controller: _searchController,
      hintText: 'Search party or cheque no...',
      onChanged: (value) => setState(() {
        _searchQuery = value;
        _resetPage();
      }),
      onClear: _searchController.text.isEmpty ? null : () => _clearFilters(),
    );
    final direction = DropdownButtonFormField<String>(
      value: _direction,
      isDense: true,
      decoration: InputDecoration(
        hintText: 'Direction',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      items: const [
        DropdownMenuItem(value: 'all', child: Text('All directions')),
        DropdownMenuItem(value: 'received', child: Text('Received')),
        DropdownMenuItem(value: 'issued', child: Text('Issued')),
      ],
      onChanged: (value) => setState(() {
        _direction = value ?? 'all';
        _resetPage();
      }),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            Expanded(flex: 3, child: search),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: direction),
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
          direction,
        ],
      ),
    );
  }

  Widget _table(BuildContext context) {
    int? sortIndex;
    switch (_sortField) {
      case 'party':
        sortIndex = 0;
        break;
      case 'date':
        sortIndex = 2;
        break;
      case 'amount':
        sortIndex = 3;
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
              col('Cheque', 'party'),
              const DataColumn(
                label: Text(
                  'Direction',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              col('Date', 'date'),
              col('Amount', 'amount', numeric: true),
              const DataColumn(
                label: Text(
                  'Status',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const DataColumn(label: Text('')),
            ],
            rows: [
              for (final cheque in _pageRows)
                DataRow(cells: [
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${cheque.partyName} • ${cheque.chequeNumber}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (cheque.notes.isNotEmpty)
                            Text(
                              cheque.notes,
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
                    Text(
                        cheque.direction == 'received' ? 'Received' : 'Issued'),
                  ),
                  DataCell(Text(
                      cheque.chequeDate.toLocal().toString().split(' ').first)),
                  DataCell(
                    AppMoney(
                      cheque.amount,
                      currencySymbol: cheque.currencySymbol,
                      bold: true,
                    ),
                  ),
                  DataCell(_statusPill(cheque.status)),
                  DataCell(_rowMenu(cheque)),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cards() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 90),
      itemCount: _pageRows.length,
      itemBuilder: (context, index) => _tile(_pageRows[index]),
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
    final color = switch (status) {
      'cleared' => Colors.green,
      'bounced' || 'cancelled' => Colors.red,
      'deposited' => Colors.blue,
      _ => Colors.orange,
    };
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

  Widget _rowMenu(ChequeRecord cheque) {
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
      actions.add(const PopupMenuItem(
          value: 'cancelled', child: Text('Mark cancelled')));
    } else if (cheque.status == 'cleared') {
      actions.add(
          const PopupMenuItem(value: 'bounced', child: Text('Mark bounced')));
    }
    if (actions.isEmpty) return const SizedBox(width: 24);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      itemBuilder: (_) => actions,
      onSelected: (status) => _transition(cheque, status),
    );
  }

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
      actions.add(const PopupMenuItem(
          value: 'cancelled', child: Text('Mark cancelled')));
    } else if (cheque.status == 'cleared') {
      actions.add(
          const PopupMenuItem(value: 'bounced', child: Text('Mark bounced')));
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
                '${cheque.chequeDate.toLocal().toString().split(' ').first} • ${cheque.status.isEmpty ? '' : '${cheque.status[0].toUpperCase()}${cheque.status.substring(1)}'}'),
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
