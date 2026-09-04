import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/services/reminder_service.dart';

/// Payment reminders: overdue invoices with WhatsApp / SMS / copy actions
/// and a UPI payment link baked into the message.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  List<OverdueInvoice> _overdue = [];
  String? _upiId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final overdue = await ReminderService.getOverdue();
    final upiId =
        await ref.read(settingsRepositoryProvider).getSetting(SettingKey.upiId);
    if (!mounted) return;
    setState(() {
      _overdue = overdue;
      _upiId = upiId;
      _isLoading = false;
    });
  }

  double get _totalOverdue => _overdue.fold(0, (s, i) => s + i.outstanding);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM yyyy');
    return Scaffold(
      backgroundColor:
          theme.brightness == Brightness.dark ? null : Colors.grey[50],
      appBar: AppBar(
        title: const Text('Payment Reminders'),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.notifications_active_outlined,
                          color: theme.colorScheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_overdue.length} overdue invoice${_overdue.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            Text(
                              'Total outstanding: $_currencySymbol ${_totalOverdue.toStringAsFixed(2)}',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _overdue.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.celebration_outlined,
                                  size: 64,
                                  color: theme.colorScheme.outlineVariant),
                              const SizedBox(height: 12),
                              const Text('Nothing overdue. Great job!'),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemCount: _overdue.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 2),
                          itemBuilder: (context, i) {
                            final inv = _overdue[i];
                            final overdueDays = inv.dueDate == null
                                ? 0
                                : DateTime.now()
                                    .difference(inv.dueDate!)
                                    .inDays;
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                title: Text(
                                  '#${inv.invoiceNumber} · ${inv.customerName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  inv.dueDate == null
                                      ? ''
                                      : 'Due ${df.format(inv.dueDate!)}'
                                          '  ·  $overdueDays day${overdueDays == 1 ? '' : 's'} over',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                ),
                                trailing: Text(
                                  '${inv.currencySymbol} ${inv.outstanding.toStringAsFixed(2)}',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.red[700]),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: _overdue.isEmpty
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant)),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final inv in _overdue.take(1)) ...[
                      FilledButton.icon(
                        onPressed: () =>
                            ReminderService.openWhatsApp(inv, upiId: _upiId),
                        icon: const Icon(Icons.chat_outlined, size: 16),
                        label: const Text('WhatsApp latest'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final url =
                              ReminderService.whatsappUrl(inv, upiId: _upiId);
                          await Clipboard.setData(ClipboardData(
                              text: Uri.parse(url).queryParameters['text'] ??
                                  ''));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Reminder message copied — paste it anywhere')));
                          }
                        },
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: const Text('Copy message'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  String get _currencySymbol =>
      _overdue.isEmpty ? '₹' : _overdue.first.currencySymbol;
}
