import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Admin-only audit trail viewer: newest writes first, searchable.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<Map<String, dynamic>> _entries = [];
  bool _isLoading = true;
  String _search = '';
  String _eventFilter = 'all';
  final _searchController = TextEditingController();

  static const _filters = <String, String>{
    'all': 'All events',
    'invoice': 'Invoices',
    'payment': 'Sales payments',
    'purchase_bill': 'Purchase bills',
    'purchase_payment': 'Purchase payments',
    'expense': 'Expenses',
    'cheque': 'Cheques',
    'loan': 'Loans',
    'transfer': 'Transfers',
    'adjustment': 'Adjustments',
    'period': 'Period locks',
    'license': 'Licenses',
  };

  bool _matchesFilter(Map<String, dynamic> e) {
    if (_eventFilter == 'all') return true;
    final action = (e['action'] as String? ?? '').toLowerCase();
    final entity = (e['entity'] as String? ?? '').toLowerCase();
    switch (_eventFilter) {
      case 'invoice':
        return action.startsWith('invoice_');
      case 'payment':
        return action == 'payment_add' || action == 'payment_delete';
      case 'purchase_bill':
        return action == 'purchase_bill_create' ||
            action == 'purchase_bill_update' ||
            action == 'purchase_bill_delete';
      case 'purchase_payment':
        return action == 'purchase_payment_add' ||
            action == 'purchase_payment_delete' ||
            action == 'purchase_payment';
      case 'expense':
        return action.startsWith('expense_');
      case 'cheque':
        return action.startsWith('cheque_');
      case 'loan':
        return action.startsWith('loan_');
      case 'transfer':
        return action == 'transfer' || entity == 'transfers';
      case 'adjustment':
        return action == 'adjustment' || entity == 'adjustments';
      case 'period':
        return action.startsWith('period_');
      case 'license':
        return action.startsWith('license_');
      default:
        return true;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final db = await DatabaseHelper().database;
    return db.query('audit_log', orderBy: 'created_at DESC', limit: 1000);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    final entries = await _load();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM yyyy, HH:mm');
    final q = _search.trim().toLowerCase();
    final byFilter = _entries.where(_matchesFilter).toList();
    final filtered = q.isEmpty
        ? byFilter
        : byFilter.where((e) {
            return (e['username'] as String? ?? '').toLowerCase().contains(q) ||
                (e['action'] as String? ?? '').toLowerCase().contains(q) ||
                (e['entity'] as String? ?? '').toLowerCase().contains(q) ||
                (e['details'] as String? ?? '').toLowerCase().contains(q);
          }).toList();

    return Scaffold(
      backgroundColor:
          theme.brightness == Brightness.dark ? null : Colors.grey[50],
      appBar: AppBar(
        title: const Text('Audit Log'),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(children: [
              _healthStat(Icons.history, '${_entries.length}', 'Loaded events'),
              const SizedBox(width: 10),
              _healthStat(
                  Icons.person_outline,
                  '${_entries.map((e) => e['username']).toSet().length}',
                  'Actors'),
              const SizedBox(width: 10),
              _healthStat(Icons.schedule_outlined,
                  _entries.isEmpty ? '—' : 'Live', 'Audit health'),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: DropdownButtonFormField<String>(
              value: _eventFilter,
              decoration: const InputDecoration(
                labelText: 'Event type',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: _filters.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _eventFilter = v ?? 'all'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: AppSearchField(
              controller: _searchController,
              hintText: 'Search user / action / entity / details',
              onChanged: (v) => setState(() => _search = v),
              onClear: () => setState(() {
                _searchController.clear();
                _search = '';
              }),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const AppLoadingState()
                : filtered.isEmpty
                    ? const AppEmptyState(
                        icon: Icons.history_outlined,
                        title: 'No audit entries',
                        subtitle: 'Actions will appear here as they happen',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 2),
                        itemBuilder: (context, i) {
                          final e = filtered[i];
                          final created = DateTime.tryParse(
                                  e['created_at'] as String? ?? '') ??
                              DateTime.now();
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: AppCard(
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                dense: true,
                                leading: Icon(
                                  _iconFor(e['action'] as String? ?? ''),
                                  size: 20,
                                  color: theme.primaryColor,
                                ),
                                title: Text(
                                  '${e['action'] ?? ''} — ${e['details'] ?? ''}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                                subtitle: Text(
                                  '${e['username'] ?? 'system'} · ${e['entity'] ?? ''}${(e['entity_id'] as String?)?.isNotEmpty ?? false ? ' ${e['entity_id']}' : ''} · ${df.format(created)}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                ),
                                onLongPress: () {
                                  Clipboard.setData(ClipboardData(
                                      text:
                                          '${e['action']} | ${e['username']} | ${e['entity']} ${e['entity_id']} | ${e['details']} | ${df.format(created)}'));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Copied to clipboard')),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String action) {
    if (action.contains('delete')) return Icons.delete_outline;
    if (action.contains('create')) return Icons.add_circle_outline;
    if (action.contains('update')) return Icons.edit_outlined;
    if (action.contains('payment')) return Icons.payments_outlined;
    if (action.contains('restore')) return Icons.restore_outlined;
    if (action.contains('transfer')) return Icons.swap_horiz_outlined;
    if (action.contains('adjustment')) return Icons.tune_outlined;
    if (action.contains('cheque')) return Icons.receipt_long_outlined;
    if (action.contains('loan')) return Icons.account_balance_outlined;
    if (action.contains('expense')) return Icons.shopping_bag_outlined;
    if (action.contains('period')) return Icons.lock_outline;
    if (action.contains('license')) return Icons.verified_outlined;
    return Icons.history;
  }

  Widget _healthStat(IconData icon, String value, String label) => Expanded(
        child: AppCard(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(icon,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(value,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(label, style: Theme.of(context).textTheme.labelSmall),
                  ])),
            ])),
      );
}
