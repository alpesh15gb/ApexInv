import 'package:flutter/material.dart';
import 'package:apexbooks/models/product.dart';

/// Visual-only frame shared by financial document editors.
/// Business rules remain in the owning screen.
class DocumentEditorShell extends StatelessWidget {
  final Widget editor;
  final Widget actions;
  final List<String> validationErrors;
  final String stateLabel;
  final bool isDirty;
  final String? documentTitle;
  final String? documentReference;
  final Widget? documentMode;

  const DocumentEditorShell({
    super.key,
    required this.editor,
    required this.actions,
    required this.validationErrors,
    required this.stateLabel,
    this.isDirty = false,
    this.documentTitle,
    this.documentReference,
    this.documentMode,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (documentTitle != null)
          _DocumentWorkspaceHeader(
            title: documentTitle!,
            reference: documentReference,
            mode: documentMode,
          ),
        _ReviewStrip(
          stateLabel: stateLabel,
          isDirty: isDirty,
          validationErrors: validationErrors,
        ),
        Expanded(child: editor),
        actions,
      ],
    );
  }
}

/// Compact document workspace chrome used by invoice, order and bill editors.
/// It keeps the document identity, mode and auto-generated reference visible
/// while the table/form body scrolls independently below it.
class _DocumentWorkspaceHeader extends StatelessWidget {
  final String title;
  final String? reference;
  final Widget? mode;

  const _DocumentWorkspaceHeader({
    required this.title,
    this.reference,
    this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 620;
            final identity = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_outlined,
                    size: 19, color: scheme.primary),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ],
            );
            final referenceChip = reference == null || reference!.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(reference!,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  identity,
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (mode != null) mode!,
                    referenceChip,
                  ]),
                ],
              );
            }
            return Row(children: [
              Expanded(child: identity),
              if (mode != null) mode!,
              if (mode != null && reference != null && reference!.isNotEmpty)
                const SizedBox(width: 10),
              referenceChip,
            ]);
          },
        ),
      ),
    );
  }
}

class _ReviewStrip extends StatelessWidget {
  final String stateLabel;
  final bool isDirty;
  final List<String> validationErrors;

  const _ReviewStrip({
    required this.stateLabel,
    required this.isDirty,
    required this.validationErrors,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasErrors = validationErrors.isNotEmpty;
    final color =
        hasErrors ? theme.colorScheme.error : theme.colorScheme.primary;
    return Material(
      color: color.withValues(alpha: 0.07),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(hasErrors ? Icons.error_outline : Icons.check_circle_outline,
                size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasErrors ? validationErrors.join('  |  ') : stateLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            if (isDirty && !hasErrors)
              Text('Unsaved changes',
                  style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Inventory-aware type-ahead for document line items. Users may keep typing
/// a new item name, while choosing a catalog item provides its details to the
/// owning form through [onSelected].
class DocumentItemPicker extends StatefulWidget {
  final List<Product> products;
  final String initialValue;
  final String label;
  final ValueChanged<String> onChanged;
  final ValueChanged<Product> onSelected;

  const DocumentItemPicker({
    super.key,
    required this.products,
    required this.initialValue,
    required this.label,
    required this.onChanged,
    required this.onSelected,
  });

  @override
  State<DocumentItemPicker> createState() => _DocumentItemPickerState();
}

class _DocumentItemPickerState extends State<DocumentItemPicker> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant DocumentItemPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        _controller.text != widget.initialValue) {
      _controller.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Autocomplete<Product>(
      textEditingController: _controller,
      displayStringForOption: (product) => product.name,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return widget.products.take(12);
        return widget.products.where((product) {
          return product.name.toLowerCase().contains(query) ||
              product.hsncode.toLowerCase().contains(query) ||
              product.barcode.toLowerCase().contains(query) ||
              (product.aliasName?.toLowerCase().contains(query) ?? false);
        }).take(12);
      },
      onSelected: widget.onSelected,
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: 'Type to search inventory',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
          ),
          onChanged: widget.onChanged,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final scheme = Theme.of(context).colorScheme;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 520),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final product = options.elementAt(index);
                  final detail = [
                    if (product.hsncode.isNotEmpty) 'HSN ${product.hsncode}',
                    if (product.barcode.isNotEmpty) product.barcode,
                    '${product.stock} in stock',
                  ].join('  |  ');
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      product.type == 'service'
                          ? Icons.design_services_outlined
                          : Icons.inventory_2_outlined,
                      color: scheme.primary,
                    ),
                    title: Text(product.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(detail,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(
                      product.price.toStringAsFixed(2),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    onTap: () => onSelected(product),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
