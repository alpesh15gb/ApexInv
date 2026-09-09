import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/product_variant_service.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/verticals.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Manage a retail product's variants (size/colour — retail.md P4). Each
/// variant is a sellable option with an optional price delta and stock.
Future<void> showProductVariantsSheet(
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
    builder: (_) => _VariantsSheetBody(
      productId: productId,
      productName: productName,
    ),
  );
}

class _VariantsSheetBody extends StatefulWidget {
  final String productId;
  final String productName;

  const _VariantsSheetBody({
    required this.productId,
    required this.productName,
  });

  @override
  State<_VariantsSheetBody> createState() => _VariantsSheetBodyState();
}

class _VariantsSheetBodyState extends State<_VariantsSheetBody> {
  bool _loading = true;
  List<ProductVariant> _variants = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final variants =
          await ProductVariantService.getForProduct(widget.productId);
      if (!mounted) return;
      setState(() {
        _variants = variants;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _addOrEdit([ProductVariant? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _VariantFormSheet(
        productId: widget.productId,
        existing: existing,
      ),
    );
    if (saved == true) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.piecesSavedMessage)));
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
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.variantsTitle,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.productName} · ${l10n.piecesCountLabel(_variants.length)}',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                AppPrimaryButton(
                  onPressed: () => _addOrEdit(),
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(l10n.variantsAdd),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_variants.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(l10n.variantsEmpty,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _variants.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final variant = _variants[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${variant.name}: ${variant.value}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${variant.stock.toStringAsFixed(0)} in stock'
                        '${variant.extraPrice > 0 ? ' · +₹${variant.extraPrice.toStringAsFixed(2)}' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _addOrEdit(variant),
                      ),
                      onLongPress: () async {
                        await ProductVariantService.delete(variant.id);
                        await _load();
                      },
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

class _VariantFormSheet extends StatefulWidget {
  final String productId;
  final ProductVariant? existing;

  const _VariantFormSheet({required this.productId, this.existing});

  @override
  State<_VariantFormSheet> createState() => _VariantFormSheetState();
}

class _VariantFormSheetState extends State<_VariantFormSheet> {
  late final TextEditingController _name;
  late final TextEditingController _value;
  late final TextEditingController _extraPrice;
  late final TextEditingController _stock;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final variant = widget.existing;
    _name = TextEditingController(text: variant?.name ?? 'Size');
    _value = TextEditingController(text: variant?.value ?? '');
    _extraPrice = TextEditingController(
        text: variant != null && variant.extraPrice > 0
            ? variant.extraPrice.toString()
            : '0');
    _stock =
        TextEditingController(text: variant?.stock.toStringAsFixed(0) ?? '0');
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    _extraPrice.dispose();
    _stock.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _value.text.trim();
    if (value.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ProductVariantService.upsert(ProductVariant(
        id: widget.existing?.id ?? const Uuid().v4(),
        productId: widget.productId,
        name: _name.text.trim().isEmpty ? 'Variant' : _name.text.trim(),
        value: value,
        extraPrice: double.tryParse(_extraPrice.text.trim()) ?? 0.0,
        stock: double.tryParse(_stock.text.trim()) ?? 0.0,
        barcode: widget.existing?.barcode ?? '',
      ));
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
            Text(widget.existing == null ? l10n.variantsAdd : l10n.variantsEdit,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: InputDecoration(
                        labelText: l10n.variantsNameLabel,
                        hintText: 'Size',
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _value,
                    autofocus: true,
                    decoration: InputDecoration(
                        labelText: l10n.variantsValueLabel,
                        hintText: 'M',
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _extraPrice,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: l10n.variantsExtraPriceLabel,
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _stock,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: l10n.labelStock,
                        isDense: true,
                        border: const OutlineInputBorder()),
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
