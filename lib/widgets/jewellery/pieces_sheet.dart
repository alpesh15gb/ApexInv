import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/jewellery_piece.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/widgets/adaptive/status_chip.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Manage the tagged pieces of one jewellery product (retail.md P2).
/// Pieces carry tag no, weights, HUID and a lifecycle status; invoices move
/// pieces in and out of `sold` automatically — this sheet only tags stock.
Future<void> showJewelleryPiecesSheet(
  BuildContext context, {
  required String productId,
  required String productName,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _PiecesSheetBody(
      productId: productId,
      productName: productName,
    ),
  );
}

class _PiecesSheetBody extends ConsumerStatefulWidget {
  final String productId;
  final String productName;

  const _PiecesSheetBody({
    required this.productId,
    required this.productName,
  });

  @override
  ConsumerState<_PiecesSheetBody> createState() => _PiecesSheetBodyState();
}

class _PiecesSheetBodyState extends ConsumerState<_PiecesSheetBody> {
  bool _loading = true;
  String? _error;
  List<JewelleryPiece> _pieces = [];
  JewelleryAttributes? _attributes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(jewelleryRepositoryProvider);
      final results = await Future.wait([
        repo.getPiecesForProduct(widget.productId),
        repo.getAttributes(widget.productId),
      ]);
      if (!mounted) return;
      setState(() {
        _pieces = results[0] as List<JewelleryPiece>;
        _attributes = results[1] as JewelleryAttributes?;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  (String, StatusTone) _statusOf(JewelleryPiece piece, AppLocalizations l10n) {
    switch (piece.status) {
      case 'sold':
        return (l10n.piecesStatusSold, StatusTone.danger);
      case 'exchanged':
        return (l10n.piecesStatusExchanged, StatusTone.warning);
      case 'job_work':
        return (l10n.piecesStatusJobWork, StatusTone.info);
      default:
        return (l10n.piecesStatusInStock, StatusTone.success);
    }
  }

  Future<void> _addOrEdit([JewelleryPiece? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PieceFormSheet(
        productId: widget.productId,
        existing: existing,
        attributes: _attributes,
      ),
    );
    if (saved == true) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.piecesSavedMessage)));
    }
  }

  Future<void> _confirmDelete(JewelleryPiece piece) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.actionDelete),
        content: Text(l10n.piecesDeleteConfirm(piece.tagNo)),
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
    await ref.read(jewelleryRepositoryProvider).deletePiece(piece.id);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.piecesDeletedMessage)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.piecesTitle,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.productName} · ${l10n.piecesCountLabel(_pieces.length)}',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                AppPrimaryButton(
                  onPressed: _addOrEdit,
                  icon: const Icon(Icons.style_outlined, size: 16),
                  label: Text(l10n.piecesAdd),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              )
            else if (_pieces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(l10n.piecesEmpty,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _pieces.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final piece = _pieces[index];
                    final (statusLabel, tone) = _statusOf(piece, l10n);
                    final net = piece.netWeight > 0
                        ? piece.netWeight
                        : (piece.grossWeight - piece.stoneWeight)
                            .clamp(0.0, double.infinity);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          Expanded(
                            child: Text('#${piece.tagNo}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                          StatusChip(label: statusLabel, tone: tone),
                        ],
                      ),
                      subtitle: Text(
                        '${net.toStringAsFixed(2)} g net'
                        '${piece.huid.isNotEmpty ? ' · ${piece.huid}' : ''}'
                        '${piece.status == 'sold' && piece.soldInvoiceId != null ? ' · ${l10n.piecesSoldOn(piece.soldInvoiceId!)}' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: piece.isInStock
                          ? IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _addOrEdit(piece),
                            )
                          : null,
                      onLongPress:
                          piece.isInStock ? () => _confirmDelete(piece) : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PieceFormSheet extends ConsumerStatefulWidget {
  final String productId;
  final JewelleryPiece? existing;
  final JewelleryAttributes? attributes;

  const _PieceFormSheet({
    required this.productId,
    this.existing,
    this.attributes,
  });

  @override
  ConsumerState<_PieceFormSheet> createState() => _PieceFormSheetState();
}

class _PieceFormSheetState extends ConsumerState<_PieceFormSheet> {
  late final TextEditingController _tagNo;
  late final TextEditingController _huid;
  late final TextEditingController _gross;
  late final TextEditingController _stone;
  late final TextEditingController _net;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final piece = widget.existing;
    _tagNo = TextEditingController(text: piece?.tagNo ?? '');
    _huid = TextEditingController(text: piece?.huid ?? '');
    _gross = TextEditingController(
        text: piece != null && piece.grossWeight > 0
            ? piece.grossWeight.toString()
            : '');
    _stone = TextEditingController(
        text: piece != null && piece.stoneWeight > 0
            ? piece.stoneWeight.toString()
            : '');
    _net = TextEditingController(
        text: piece != null && piece.netWeight > 0
            ? piece.netWeight.toString()
            : '');
  }

  @override
  void dispose() {
    _tagNo.dispose();
    _huid.dispose();
    _gross.dispose();
    _stone.dispose();
    _net.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final tagNo = _tagNo.text.trim();
    if (tagNo.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final gross = double.tryParse(_gross.text.trim()) ?? 0.0;
      final stone = double.tryParse(_stone.text.trim()) ?? 0.0;
      final netOverride = double.tryParse(_net.text.trim());
      final existing = widget.existing;
      final piece = (existing ??
              JewelleryPiece.create(
                productId: widget.productId,
                tagNo: tagNo,
                grossWeight: gross,
                stoneWeight: stone,
                purity: widget.attributes?.purity ?? '',
              ))
          .copyWith(
        tagNo: tagNo,
        huid: _huid.text.trim(),
        grossWeight: gross,
        stoneWeight: stone,
        netWeight: netOverride ?? (gross - stone).clamp(0.0, double.infinity),
      );
      await ref.read(jewelleryRepositoryProvider).upsertPiece(piece);
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null ? l10n.piecesAdd : l10n.piecesEdit,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tagNo,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.piecesTagNo,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _huid,
              decoration: InputDecoration(
                labelText: l10n.jewelleryHuidLabel,
                hintText: l10n.jewelleryHuidHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
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
                      border: const OutlineInputBorder(),
                    ),
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
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _net,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: l10n.jewelleryNetWeightLabel,
                      hintText: l10n.jewelleryNetWeightHint,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: AppPrimaryButton(
                onPressed: _saving ? null : _save,
                loading: _saving,
                label: Text(l10n.actionSave),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
