import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/verticals.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/widgets/adaptive/status_chip.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Karigar job-work ledger (retail.md P3): metal issued to a karigar and
/// received back, with the weight that never returned shown as wastage.
/// Pure weight ledger — no money postings.
class JobWorkScreen extends ConsumerStatefulWidget {
  const JobWorkScreen({super.key});

  @override
  ConsumerState<JobWorkScreen> createState() => _JobWorkScreenState();
}

class _JobWorkScreenState extends ConsumerState<JobWorkScreen> {
  bool _loading = true;
  String? _loadError;
  List<JobWorkOrder> _orders = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final orders =
          await ref.read(jewelleryRepositoryProvider).getJobWorkOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openForm([JobWorkOrder? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _JobWorkDialog(existing: existing),
    );
    if (saved != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.jobWorkSavedMessage)));
    await _load();
  }

  Future<void> _receive(JobWorkOrder order) async {
    final receivedCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.jobWorkReceive),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${AppLocalizations.of(context)!.jobWorkIssuedNet}: ${order.issuedNet.toStringAsFixed(2)} g',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: receivedCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.jobWorkReceivedNet,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.actionCancel),
          ),
          FilledButton(
            onPressed: () async {
              final net = double.tryParse(receivedCtrl.text.trim());
              if (net == null || net < 0) return;
              if (net > order.issuedNet) {
                final proceed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Excess Weight Received'),
                    content: Text(
                        'Received ${net.toStringAsFixed(3)}g exceeds issued ${order.issuedNet.toStringAsFixed(3)}g. '
                        'This will result in negative wastage. Continue?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange),
                        child: const Text('Confirm Excess'),
                      ),
                    ],
                  ),
                );
                if (proceed != true) return;
              }
              Navigator.pop(context, true);
            },
            child: Text(AppLocalizations.of(context)!.actionSave),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final net = double.tryParse(receivedCtrl.text.trim()) ?? 0.0;
    final issued = order.issuedNet;
    final wastage =
        issued <= 0 ? 0.0 : ((issued - net) / issued * 100).clamp(0.0, 100.0);
    await ref.read(jewelleryRepositoryProvider).upsertJobWorkOrder(
        order.copyWith(
            status: 'received',
            receivedNet: net,
            wastagePercent: wastage,
            receivedDate: DateTime.now()));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.jobWorkTitle),
            Text(l10n.jobWorkSubtitle,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
        toolbarHeight: 72,
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: Text(l10n.jobWorkAdd),
      ),
      body: _loading
          ? const AppLoadingState()
          : _loadError != null
              ? AppListStateView(
                  state: AppListState.error,
                  errorMessage: _loadError,
                  onRetry: _load,
                  emptyState: const SizedBox.shrink(),
                  data: const SizedBox.shrink(),
                )
              : _orders.isEmpty
                  ? AppListStateView(
                      state: AppListState.empty,
                      emptyState: AppEmptyState(
                        icon: Icons.handyman_outlined,
                        title: l10n.jobWorkEmpty,
                        subtitle: l10n.jobWorkSubtitle,
                      ),
                      data: const SizedBox.shrink(),
                    )
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxWidth: AppLayout.maxWidthNarrow),
                        child: ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _orders.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final order = _orders[index];
                            final open = order.isOpen;
                            return ListTile(
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${order.karigar} · ${MetalRate.metalLabel(order.metal)} ${order.purity}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  StatusChip(
                                    label: open
                                        ? l10n.jobWorkStatusOpen
                                        : l10n.jobWorkStatusReceived,
                                    tone: open
                                        ? StatusTone.warning
                                        : StatusTone.success,
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                open
                                    ? '${order.issuedNet.toStringAsFixed(2)} g issued'
                                        '${order.issuedDate != null ? ' · ${DateFormat('dd MMM yy').format(order.issuedDate!)}' : ''}'
                                        '${order.description.isNotEmpty ? ' · ${order.description}' : ''}'
                                    : '${order.issuedNet.toStringAsFixed(2)} g → ${order.receivedNet.toStringAsFixed(2)} g · '
                                        '${l10n.jewelleryWastageLabel.replaceFirst(' %', '')} ${order.wastagePercent.toStringAsFixed(1)}%',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: open
                                  ? IconButton(
                                      icon: const Icon(Icons.download_done,
                                          size: 20),
                                      tooltip: l10n.jobWorkReceive,
                                      onPressed: () => _receive(order),
                                    )
                                  : null,
                            );
                          },
                        ),
                      ),
                    ),
    );
  }
}

class _JobWorkDialog extends ConsumerStatefulWidget {
  final JobWorkOrder? existing;

  const _JobWorkDialog({this.existing});

  @override
  ConsumerState<_JobWorkDialog> createState() => _JobWorkDialogState();
}

class _JobWorkDialogState extends ConsumerState<_JobWorkDialog> {
  late final TextEditingController _karigar;
  late final TextEditingController _description;
  late final TextEditingController _gross;
  late final TextEditingController _stone;
  String _metal = 'gold';
  String _purity = '22K';
  DateTime _issuedDate = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final order = widget.existing;
    _karigar = TextEditingController(text: order?.karigar ?? '');
    _description = TextEditingController(text: order?.description ?? '');
    _gross = TextEditingController(
        text: order != null && order.issuedGross > 0
            ? order.issuedGross.toString()
            : '');
    _stone = TextEditingController(
        text: order != null && order.issuedStone > 0
            ? order.issuedStone.toString()
            : '');
    if (order != null) {
      _metal = order.metal;
      _purity = order.purity.isEmpty ? '22K' : order.purity;
      if (order.issuedDate != null) _issuedDate = order.issuedDate!;
    }
  }

  @override
  void dispose() {
    _karigar.dispose();
    _description.dispose();
    _gross.dispose();
    _stone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final karigar = _karigar.text.trim();
    if (karigar.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final existing = widget.existing;
      await ref.read(jewelleryRepositoryProvider).upsertJobWorkOrder(
            JobWorkOrder(
              id: existing?.id ?? const Uuid().v4(),
              karigar: karigar,
              metal: _metal,
              purity: _purity,
              description: _description.text.trim(),
              issuedGross: double.tryParse(_gross.text.trim()) ?? 0.0,
              issuedStone: double.tryParse(_stone.text.trim()) ?? 0.0,
              issuedDate: _issuedDate,
              status: existing?.status ?? 'open',
              receivedNet: existing?.receivedNet ?? 0.0,
              wastagePercent: existing?.wastagePercent ?? 0.0,
              receivedDate: existing?.receivedDate,
            ),
          );
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.jobWorkAdd,
          style: const TextStyle(fontSize: AppFontSize.xlarge)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _karigar,
                autofocus: true,
                decoration: InputDecoration(
                    labelText: l10n.jobWorkKarigar,
                    isDense: true,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _metal,
                      isDense: true,
                      decoration: InputDecoration(
                          labelText: l10n.jewelleryMetalLabel,
                          isDense: true,
                          border: const OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'gold', child: Text('Gold')),
                        DropdownMenuItem(
                            value: 'silver', child: Text('Silver')),
                      ],
                      onChanged: (v) => setState(() => _metal = v ?? 'gold'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _purity,
                      isDense: true,
                      decoration: InputDecoration(
                          labelText: l10n.jewelleryPurityLabel,
                          isDense: true,
                          border: const OutlineInputBorder()),
                      items: [
                        for (final p in MetalRate.purities)
                          DropdownMenuItem(value: p, child: Text(p)),
                      ],
                      onChanged: (v) => setState(() => _purity = v ?? '22K'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _gross,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: l10n.jewelleryGrossWeightLabel,
                          isDense: true,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _stone,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: l10n.jewelleryStoneWeightLabel,
                          isDense: true,
                          border: const OutlineInputBorder()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                decoration: InputDecoration(
                    labelText: l10n.jobWorkDescription,
                    isDense: true,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _issuedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (picked != null) {
                    setState(() => _issuedDate = picked);
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                      labelText: l10n.metalRatesDateLabel,
                      isDense: true,
                      border: const OutlineInputBorder()),
                  child: Text(DateFormat('dd MMM yyyy').format(_issuedDate)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.actionCancel),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.actionSave),
        ),
      ],
    );
  }
}
