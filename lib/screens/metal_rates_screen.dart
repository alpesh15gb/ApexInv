import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Daily gold/silver rates per gram (retail.md P1). Invoices freeze the rate
/// they bill with; this screen only records what the shop declares each day.
class MetalRatesScreen extends ConsumerStatefulWidget {
  const MetalRatesScreen({super.key});

  @override
  ConsumerState<MetalRatesScreen> createState() => _MetalRatesScreenState();
}

class _MetalRatesScreenState extends ConsumerState<MetalRatesScreen> {
  DateTime _day = DateTime.now();
  bool _isLoading = true;
  String? _loadError;
  List<MetalRate> _rates = [];
  DateTime? _latestDay;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _dayKey => '${_day.year.toString().padLeft(4, '0')}-'
      '${_day.month.toString().padLeft(2, '0')}-'
      '${_day.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final repo = ref.read(jewelleryRepositoryProvider);
      final results = await Future.wait([
        repo.getRatesForDate(_day),
        repo.getLatestRateDate(),
      ]);
      if (!mounted) return;
      setState(() {
        _rates = results[0] as List<MetalRate>;
        _latestDay = results[1] as DateTime?;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) return;
    setState(() => _day = DateTime(picked.year, picked.month, picked.day));
    await _load();
  }

  MetalRate? _rateFor(String metal, String purity) {
    for (final rate in _rates) {
      if (rate.metal == metal && rate.purity == purity) {
        return rate;
      }
    }
    return null;
  }

  Future<void> _saveRates(Map<String, _RateDraft> values) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(jewelleryRepositoryProvider);
      var savedCount = 0;
      for (final entry in values.entries) {
        final parts = entry.key.split('|');
        final sell = double.tryParse(entry.value.sell.trim());
        final buy = double.tryParse(entry.value.buy.trim());
        if (sell == null || sell <= 0 || buy == null || buy <= 0) continue;
        await repo.upsertMetalRate(MetalRate.create(
          metal: parts[0],
          purity: parts[1],
          sellRatePerGram: sell,
          buyRatePerGram: buy,
          effectiveDate: _day,
        ));
        savedCount++;
      }
      if (!mounted) return;
      if (savedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.metalRatesSavedMessage)));
        await _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                AppLocalizations.of(context)!.metalRatesNoCompletePairMessage),
            behavior: SnackBarBehavior.floating,
            showCloseIcon: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete(MetalRate rate) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.metalRatesDeleteTitle),
        content: Text(l10n.metalRatesDeleteBody(
            _dayKey, MetalRate.metalLabel(rate.metal), rate.purity)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(jewelleryRepositoryProvider).deleteMetalRate(rate.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.metalRatesDeletedMessage)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? null
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.metalRatesTitle),
            Text(
              l10n.metalRatesSubtitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        toolbarHeight: 72,
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionRefresh,
            onPressed: _isLoading ? null : _load,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const AppLoadingState()
          : SingleChildScrollView(
              padding: EdgeInsets.all(context.isCompact ? 16 : 28),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: AppLayout.maxWidthNarrow),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loadError != null)
                        AppListStateView(
                          state: AppListState.error,
                          errorMessage: _loadError,
                          onRetry: _load,
                          emptyState: const SizedBox.shrink(),
                          data: const SizedBox.shrink(),
                        )
                      else ...[
                        if (_latestDay != null &&
                            _latestDay!.isBefore(DateTime.now()
                                .subtract(const Duration(hours: 12)))) ...[
                          AppCard(
                            child: Row(
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    color: Theme.of(context).colorScheme.error),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.metalRatesMissingTodayTitle,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        l10n.metalRatesMissingTodaySubtitle,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        _RateEntryCard(
                          key: ValueKey(_dayKey),
                          day: _day,
                          dayKey: _dayKey,
                          existing: _rateFor,
                          saving: _saving,
                          onPickDay: _pickDay,
                          onSave: _saveRates,
                        ),
                        const SizedBox(height: 16),
                        if (_rates.isEmpty)
                          AppListStateView(
                            state: AppListState.empty,
                            emptyState: AppEmptyState(
                              icon: Icons.scale_outlined,
                              title: l10n.metalRatesEmptyTitle,
                              subtitle: l10n.metalRatesEmptySubtitle,
                            ),
                            data: const SizedBox.shrink(),
                          )
                        else
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (var i = 0; i < _rates.length; i++) ...[
                                  if (i > 0) const Divider(height: 1),
                                  ListTile(
                                    leading: Icon(
                                      _rates[i].metal == 'silver'
                                          ? Icons.circle_outlined
                                          : Icons.circle,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                    title: Text(
                                        '${MetalRate.metalLabel(_rates[i].metal)} ${_rates[i].purity}'),
                                    subtitle: Text(_rates[i].dateKey),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              l10n.metalRatesSellRateSummary(
                                                  _rates[i]
                                                      .sellRatePerGram
                                                      .toStringAsFixed(2)),
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                            Text(
                                              l10n.metalRatesBuyRateSummary(
                                                  _rates[i]
                                                      .buyRatePerGram
                                                      .toStringAsFixed(2)),
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant),
                                            ),
                                          ],
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline,
                                              size: 18),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error,
                                          onPressed: () =>
                                              _confirmDelete(_rates[i]),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _RateEntryCard extends StatefulWidget {
  final DateTime day;
  final String dayKey;
  final MetalRate? Function(String metal, String purity) existing;
  final bool saving;
  final VoidCallback onPickDay;
  final ValueChanged<Map<String, _RateDraft>> onSave;

  const _RateEntryCard({
    super.key,
    required this.day,
    required this.dayKey,
    required this.existing,
    required this.saving,
    required this.onPickDay,
    required this.onSave,
  });

  @override
  State<_RateEntryCard> createState() => _RateEntryCardState();
}

class _RateEntryCardState extends State<_RateEntryCard> {
  final _controllers = <String, TextEditingController>{};
  Set<String> _invalidRows = const {};

  static const _rows = [
    ('gold', '24K'),
    ('gold', '22K'),
    ('gold', '18K'),
    ('gold', '14K'),
    ('silver', '999'),
    ('silver', '925'),
  ];

  @override
  void initState() {
    super.initState();
    for (final row in _rows) {
      final key = '${row.$1}|${row.$2}';
      final rate = widget.existing(row.$1, row.$2);
      _controllers['$key|sell'] = TextEditingController(
          text: rate?.sellRatePerGram.toStringAsFixed(2) ?? '');
      _controllers['$key|buy'] = TextEditingController(
          text: rate?.buyRatePerGram.toStringAsFixed(2) ?? '');
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <String, _RateDraft>{};
    final invalidRows = <String>{};
    for (final row in _rows) {
      final key = '${row.$1}|${row.$2}';
      final sell = _controllers['$key|sell']!.text.trim();
      final buy = _controllers['$key|buy']!.text.trim();
      if (sell.isEmpty && buy.isEmpty) continue;
      final sellValue = double.tryParse(sell);
      final buyValue = double.tryParse(buy);
      if (sellValue == null ||
          sellValue <= 0 ||
          buyValue == null ||
          buyValue <= 0 ||
          buyValue > sellValue) {
        invalidRows.add(key);
        continue;
      }
      values[key] = _RateDraft(sell: sell, buy: buy);
    }
    setState(() => _invalidRows = invalidRows);
    if (invalidRows.isNotEmpty) return;
    widget.onSave(values);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.metalRatesAddTitle,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: widget.onPickDay,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(widget.dayKey),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.metalRatesPricingPolicyHint,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final row in _rows) ...[
            _rateRow(context, row, l10n),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: AppPrimaryButton(
              onPressed: widget.saving ? null : _submit,
              loading: widget.saving,
              label: Text(l10n.actionSave),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateRow(
      BuildContext context, (String, String) row, AppLocalizations l10n) {
    final key = '${row.$1}|${row.$2}';
    final invalid = _invalidRows.contains(key);
    Widget field(String side, String label) => Expanded(
          child: TextField(
            controller: _controllers['$key|$side']!,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: invalid && side == 'buy'
                  ? l10n.metalRatesCompletePairRequiredMessage
                  : null,
            ),
          ),
        );
    final fields = Row(
      children: [
        field('sell', l10n.metalRatesSellRateLabel),
        const SizedBox(width: 8),
        field('buy', l10n.metalRatesBuybackRateLabel),
      ],
    );
    final label = Text(
      '${MetalRate.metalLabel(row.$1)} ${row.$2}',
      style: const TextStyle(fontWeight: FontWeight.w600),
    );
    if (context.isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: 6),
          fields,
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 110, child: label),
        Expanded(child: fields),
      ],
    );
  }
}

class _RateDraft {
  final String sell;
  final String buy;

  const _RateDraft({required this.sell, required this.buy});
}
