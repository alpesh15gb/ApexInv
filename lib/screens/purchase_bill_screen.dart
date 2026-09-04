import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/utils/gstin_validator.dart';

/// Inward supplies (purchase bills) — feeds ITC reporting and GSTR-2.
class PurchaseBillScreen extends ConsumerStatefulWidget {
  final User user;
  const PurchaseBillScreen({super.key, required this.user});

  @override
  ConsumerState<PurchaseBillScreen> createState() => _PurchaseBillScreenState();
}

class _PurchaseBillScreenState extends ConsumerState<PurchaseBillScreen> {
  List<PurchaseBill> _bills = [];
  bool _isLoading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final bills = await PurchaseBillService.getBills();
    if (!mounted) return;
    setState(() {
      _bills = bills;
      _isLoading = false;
    });
  }

  List<PurchaseBill> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _bills;
    return _bills.where((b) {
      return b.supplierName.toLowerCase().contains(q) ||
          (b.billNumber ?? '').toLowerCase().contains(q) ||
          b.supplierGstin.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _openForm([PurchaseBill? existing]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PurchaseBillFormScreen(
          user: widget.user,
          existing: existing,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _recordPayment(PurchaseBill bill) async {
    final controller = TextEditingController();
    final notesController = TextEditingController();
    DateTime paymentDate = DateTime.now();
    String? method;
    final payments = await PurchaseBillService.getPayments(bill.id);
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pay ${bill.supplierName}'),
        content: StatefulBuilder(
            builder: (ctx, setDialogState) => SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (payments.isNotEmpty) ...[
                        const Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Payment history',
                                style: TextStyle(fontWeight: FontWeight.bold))),
                        for (final p in payments)
                          ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                  '${p.datePaid.toLocal().toString().split(' ').first}  ${p.paymentMethod ?? 'Other'}'),
                              trailing: Text(
                                  '${bill.currencySymbol} ${p.amountPaid.toStringAsFixed(2)}')),
                        const Divider(),
                      ],
                      TextField(
                          controller: controller,
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: l10n.fieldTotalLabel,
                              prefixText: '${bill.currencySymbol} ',
                              hintText: bill.outstanding.toStringAsFixed(2))),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          value: method,
                          decoration: const InputDecoration(
                              labelText: 'Payment method'),
                          items: const [
                            DropdownMenuItem(
                                value: 'Cash', child: Text('Cash')),
                            DropdownMenuItem(
                                value: 'Bank Transfer',
                                child: Text('Bank Transfer')),
                            DropdownMenuItem(
                                value: 'Online', child: Text('Online')),
                            DropdownMenuItem(
                                value: 'Other', child: Text('Other'))
                          ],
                          onChanged: (v) => setDialogState(() => method = v)),
                      TextField(
                          controller: notesController,
                          decoration: const InputDecoration(
                              labelText: 'Notes (optional)')),
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Payment date'),
                          trailing: TextButton(
                              child: Text(paymentDate
                                  .toLocal()
                                  .toString()
                                  .split(' ')
                                  .first),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: paymentDate,
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime.now()
                                        .add(const Duration(days: 365)));
                                if (picked != null)
                                  setDialogState(() => paymentDate = picked);
                              })),
                    ],
                  )),
                )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.actionCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.actionSave)),
        ],
      ),
    );
    if (ok != true) return;
    final amount = double.tryParse(controller.text.trim());
    if (amount == null || amount <= 0) return;
    await PurchaseBillService.recordPayment(bill.id, amount,
        datePaid: paymentDate,
        paymentMethod: method,
        notes: notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim());
    controller.dispose();
    notesController.dispose();
    await AuditLogService.log(
      action: 'purchase_payment',
      username: widget.user.username,
      entity: 'purchase_bills',
      entityId: bill.id,
      details: 'Paid ${amount.toStringAsFixed(2)} to ${bill.supplierName}',
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isCompact = context.isCompact;
    return Scaffold(
      backgroundColor:
          theme.brightness == Brightness.dark ? null : Colors.grey[50],
      appBar: AppBar(
        title: const Text('Purchase Bills'),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          FilledButton.icon(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Bill'),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionRefresh,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search supplier / bill no / GSTIN',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 64,
                                color: theme.colorScheme.outlineVariant),
                            const SizedBox(height: 12),
                            const Text(
                                'No purchase bills yet.\nRecord inward supplies to track ITC.',
                                textAlign: TextAlign.center),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 2),
                        itemBuilder: (context, i) =>
                            _billCard(_filtered[i], isCompact),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _billCard(PurchaseBill bill, bool isCompact) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM yyyy');
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(bill.supplierName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: bill.itcEligible
                        ? Colors.green.withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(bill.itcEligible ? 'ITC' : 'No ITC',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: bill.itcEligible
                              ? Colors.green[800]
                              : theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if ((bill.billNumber ?? '').isNotEmpty)
                  'Bill #${bill.billNumber}',
                df.format(bill.date),
                if (bill.supplierGstin.isNotEmpty) bill.supplierGstin,
              ].join('  ·  '),
              style: TextStyle(
                  fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Taxable + Tax',
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant)),
                      Text(
                        '${bill.currencySymbol} ${bill.taxableTotal.toStringAsFixed(2)} + ${bill.currencySymbol} ${bill.totalTax.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Total',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant)),
                    Text(
                      '${bill.currencySymbol} ${bill.totalAmount.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: theme.primaryColor),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.payments_outlined,
                    size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  bill.outstanding > 0.005
                      ? 'Outstanding ${bill.currencySymbol} ${bill.outstanding.toStringAsFixed(2)}'
                      : 'Fully paid',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: bill.outstanding > 0.005
                          ? Colors.orange[800]
                          : Colors.green[700],
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (bill.outstanding > 0.005)
                  IconButton(
                    icon: const Icon(Icons.payments_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Record payment',
                    onPressed: () => _recordPayment(bill),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openForm(bill),
                  tooltip: AppLocalizations.of(context)!.actionEdit,
                ),
                if (widget.user.isAdmin())
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    visualDensity: VisualDensity.compact,
                    color: theme.colorScheme.error,
                    tooltip: AppLocalizations.of(context)!.actionDelete,
                    onPressed: () async {
                      await PurchaseBillService.softDeleteBill(bill.id);
                      await AuditLogService.log(
                        action: 'purchase_bill_delete',
                        username: widget.user.username,
                        entity: 'purchase_bills',
                        entityId: bill.id,
                        details: bill.supplierName,
                      );
                      _load();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Add / edit form — full-screen so it works on every width.
class PurchaseBillFormScreen extends ConsumerStatefulWidget {
  final User user;
  final PurchaseBill? existing;
  const PurchaseBillFormScreen({super.key, required this.user, this.existing});

  @override
  ConsumerState<PurchaseBillFormScreen> createState() =>
      _PurchaseBillFormScreenState();
}

class _PurchaseBillFormScreenState
    extends ConsumerState<PurchaseBillFormScreen> {
  late final List<_ItemDraft> _items;
  late final String _billId;
  final _supplierCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _billNoCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  bool _itcEligible = true;
  bool _reverseCharge = false;
  bool _interState = false;
  // Document-level GST toggle: true → typed rates include GST.
  // Applies to every line, existing and subsequently added.
  bool _pricesIncludeTax = false;
  bool _isSaving = false;
  String _currencySymbol = '₹';
  String _currencyCode = 'INR';

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _billId = e?.id ?? const Uuid().v4();
    _items = e == null
        ? [_ItemDraft()]
        : e.items
            .map((i) => _ItemDraft(
                  name: i.productName,
                  hsn: i.hsnCode,
                  qty: i.quantity,
                  rate: i.rate,
                  taxRate: i.taxRate,
                  discount: i.discount,
                ))
            .toList();
    if (e != null) {
      _supplierCtrl.text = e.supplierName;
      _gstinCtrl.text = e.supplierGstin;
      _phoneCtrl.text = e.supplierPhone;
      _emailCtrl.text = e.supplierEmail;
      _addressCtrl.text = e.supplierAddress;
      _currencySymbol = e.currencySymbol;
      _currencyCode = e.currencyCode;
      _billNoCtrl.text = e.billNumber ?? '';
      _notesCtrl.text = e.notes;
      _date = e.date;
      _dueDate = e.dueDate;
      _itcEligible = e.itcEligible;
      _reverseCharge = e.reverseCharge;
      _interState = e.igstTotal > 0;
      _pricesIncludeTax = e.priceIncludesTax;
    } else {
      _loadConfiguredCurrency();
    }
  }

  Future<void> _loadConfiguredCurrency() async {
    final results = await Future.wait([
      SettingsService.getCurrency(),
      SettingsService.getDefaultPriceIncludesTax(),
    ]);
    if (!mounted) return;
    setState(() {
      final currency = results[0] as dynamic;
      _currencyCode = currency.code as String;
      _currencySymbol = currency.symbol as String;
      _pricesIncludeTax = results[1] as bool;
    });
  }

  @override
  void dispose() {
    _supplierCtrl.dispose();
    _gstinCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _billNoCtrl.dispose();
    _notesCtrl.dispose();
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  List<PurchaseBillItem> get _computedItems {
    final id = _billId;
    return _items
        .where((d) => d.name.text.trim().isNotEmpty)
        .map((d) => PurchaseBillItem.compute(
              id: d.id,
              purchaseBillId: id,
              productName: d.name.text.trim(),
              hsnCode: d.hsn.text.trim(),
              quantity: double.tryParse(d.qty.text) ?? 0,
              rate: double.tryParse(d.rate.text) ?? 0,
              taxRate: double.tryParse(d.tax.text) ?? 0,
              discount: double.tryParse(d.discount.text) ?? 0,
              interState: _interState || _reverseCharge,
              priceIncludesTax: _pricesIncludeTax,
            ))
        .toList();
  }

  double get _totalTaxable =>
      _computedItems.fold(0, (s, i) => s + i.taxableValue);
  double get _totalTax =>
      _computedItems.fold(0, (s, i) => s + i.amount - i.taxableValue);
  double get _grandTotal => _computedItems.fold(0, (s, i) => s + i.amount);

  Future<void> _save() async {
    // Trial/licence gate: new bills only; edits to existing stay allowed.
    if (!_isEdit && !await LicenseGate.canCreate(context)) return;
    if (_supplierCtrl.text.trim().isEmpty ||
        _isSaving ||
        _computedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Supplier name and at least one item are required')));
      return;
    }
    // Warn-only GSTIN check: never block saving real bills.
    final supplierGstinRaw = _gstinCtrl.text.trim();
    if (supplierGstinRaw.isNotEmpty && !isValidGstin(supplierGstinRaw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GSTIN looks invalid')),
      );
    }
    setState(() => _isSaving = true);
    final id = widget.existing?.id ?? const Uuid().v4();
    final bill = PurchaseBill(
      id: id,
      billNumber: _billNoCtrl.text.trim(),
      supplierName: _supplierCtrl.text.trim(),
      supplierGstin: _gstinCtrl.text.trim().toUpperCase(),
      supplierPhone: _phoneCtrl.text.trim(),
      supplierEmail: _emailCtrl.text.trim(),
      supplierAddress: _addressCtrl.text.trim(),
      date: _date,
      dueDate: _dueDate,
      totalAmount: _grandTotal,
      totalTax: _totalTax,
      amountPaid: widget.existing?.amountPaid ?? 0,
      itcEligible: _itcEligible,
      reverseCharge: _reverseCharge,
      priceIncludesTax: _pricesIncludeTax,
      notes: _notesCtrl.text.trim(),
      currencyCode: _currencyCode,
      currencySymbol: _currencySymbol,
      items: _computedItems,
    );
    if (_isEdit) {
      await PurchaseBillService.updateBill(bill);
    } else {
      await PurchaseBillService.insertBill(bill);
    }
    await AuditLogService.log(
      action: _isEdit ? 'purchase_bill_update' : 'purchase_bill_create',
      username: widget.user.username,
      entity: 'purchase_bills',
      entityId: id,
      details: '${bill.supplierName} · ${bill.totalAmount.toStringAsFixed(2)}',
    );
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _pickDate({required bool due}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: due ? (_dueDate ?? _date) : _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (due) {
        _dueDate = picked;
      } else {
        _date = picked;
      }
    });
  }

  BoxDecoration _flatCard(BuildContext context) => BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      );

  InputDecoration _fieldDec(String label, {Widget? suffixIcon}) =>
      InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  Widget _responsiveGrid(List<Widget> fields) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= Breakpoints.compactMax) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: fields[i]),
              ],
            ],
          );
        }
        const gap = 12.0;
        final w = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final f in fields) SizedBox(width: w, child: f)],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final df = DateFormat('dd MMM yyyy');
    final title = _isEdit ? 'Edit Purchase Bill' : 'New Purchase Bill';
    return Scaffold(
      backgroundColor:
          theme.brightness == Brightness.dark ? null : Colors.grey[50],
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, c) {
            final compact = c.maxWidth < 640;
            if (compact) {
              return Text(title, overflow: TextOverflow.ellipsis, maxLines: 1);
            }
            return Row(
              children: [
                Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis, maxLines: 1)),
                if (_billNoCtrl.text.trim().isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('#${_billNoCtrl.text.trim()}',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ],
            );
          },
        ),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Container(
        color: theme.scaffoldBackgroundColor,
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  const wide = 980.0;
                  final isWide = c.maxWidth >= wide;
                  final supplierCard = Container(
                    decoration: _flatCard(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                          child: Row(
                            children: [
                              Icon(Icons.storefront_outlined,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              const Text('SUPPLIER DETAILS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _responsiveGrid([
                                TextField(
                                    controller: _supplierCtrl,
                                    decoration: _fieldDec('Supplier Name *')),
                                TextField(
                                    controller: _gstinCtrl,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    decoration: _fieldDec('Supplier GSTIN')),
                                TextField(
                                    controller: _phoneCtrl,
                                    decoration: _fieldDec('Phone'),
                                    keyboardType: TextInputType.phone),
                              ]),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: _billNoCtrl,
                                  decoration: _fieldDec('Supplier Invoice No')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                  final billCard = Container(
                    decoration: _flatCard(context),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.receipt_long_outlined,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              const Text('BILL DETAILS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(height: 1),
                          const SizedBox(height: 12),
                          _responsiveGrid([
                            InkWell(
                              onTap: () => _pickDate(due: false),
                              child: InputDecorator(
                                decoration: _fieldDec('Bill Date'),
                                child: Text(df.format(_date)),
                              ),
                            ),
                            InkWell(
                              onTap: () => _pickDate(due: true),
                              child: InputDecorator(
                                decoration: _fieldDec('Due Date'),
                                child: Text(_dueDate == null
                                    ? '—'
                                    : df.format(_dueDate!)),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilterChip(
                                selected: _interState,
                                label: const Text('Inter-state (IGST)'),
                                onSelected: (v) =>
                                    setState(() => _interState = v),
                              ),
                              FilterChip(
                                selected: _reverseCharge,
                                label: const Text('Reverse charge'),
                                onSelected: (v) =>
                                    setState(() => _reverseCharge = v),
                              ),
                              FilterChip(
                                selected: _itcEligible,
                                label: const Text('ITC eligible'),
                                onSelected: (v) =>
                                    setState(() => _itcEligible = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                  final itemsCard = Container(
                    decoration: _flatCard(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: Row(
                            children: [
                              const Text('ITEMS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color:
                                      theme.primaryColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text('${_items.length}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: theme.primaryColor)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._items
                            .asMap()
                            .entries
                            .map((e) => _itemEditor(e.key, e.value)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                setState(() => _items.add(_ItemDraft())),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add item'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                  final summaryCard = Container(
                    decoration: _flatCard(context),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SUMMARY',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6)),
                        const SizedBox(height: 12),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                                value: false, label: Text('Excl GST')),
                            ButtonSegment<bool>(
                                value: true, label: Text('Incl GST')),
                          ],
                          selected: {_pricesIncludeTax},
                          onSelectionChanged: (selection) {
                            if (!mounted) return;
                            setState(() => _pricesIncludeTax = selection.first);
                          },
                        ),
                        const SizedBox(height: 12),
                        _totalRow('Taxable', _totalTaxable),
                        _totalRow('Tax', _totalTax),
                        const Divider(),
                        _totalRow('Total', _grandTotal, bold: true),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _notesCtrl,
                          maxLines: 2,
                          decoration: _fieldDec('Notes'),
                        ),
                      ],
                    ),
                  );
                  if (isWide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              supplierCard,
                              const SizedBox(height: 12),
                              billCard,
                              const SizedBox(height: 12),
                              Expanded(child: itemsCard),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 360,
                          child: SingleChildScrollView(child: summaryCard),
                        ),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        supplierCard,
                        const SizedBox(height: 12),
                        billCard,
                        const SizedBox(height: 12),
                        itemsCard,
                        const SizedBox(height: 12),
                        summaryCard,
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant)),
                  color: theme.colorScheme.surface,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.fieldTotalLabel,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurfaceVariant)),
                          Text(
                            '$_currencySymbol ${_grandTotal.toStringAsFixed(2)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: theme.primaryColor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: Text(_isEdit ? 'Update Bill' : 'Save Bill'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemEditor(int index, _ItemDraft d) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
                child: TextField(
                    controller: d.name, decoration: _dec('Item / service *'))),
            IconButton(
                onPressed: () => setState(() => _items.removeAt(index)),
                icon: const Icon(Icons.remove_circle_outline,
                    color: Colors.redAccent)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(controller: d.hsn, decoration: _dec('HSN'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.qty,
                    decoration: _dec('Qty'),
                    keyboardType: TextInputType.number)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: d.rate,
                    decoration: _dec('Rate'),
                    keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.tax,
                    decoration: _dec('GST %'),
                    keyboardType: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: d.discount,
                    decoration: _dec('Discount'),
                    keyboardType: TextInputType.number)),
          ]),
        ]),
      ),
    );
  }

  Widget _totalRow(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label,
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
        Text('$_currencySymbol ${value.toStringAsFixed(2)}',
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}

class _ItemDraft {
  final id = const Uuid().v4();
  final name = TextEditingController();
  final hsn = TextEditingController();
  final qty = TextEditingController(text: '1');
  final rate = TextEditingController();
  final tax = TextEditingController(text: '18');
  final discount = TextEditingController(text: '0');

  _ItemDraft(
      {String name = '',
      String hsn = '',
      double qty = 1,
      double rate = 0,
      double taxRate = 18,
      double discount = 0}) {
    this.name.text = name;
    this.hsn.text = hsn;
    this.qty.text = qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 2);
    this.rate.text = rate.toStringAsFixed(2);
    tax.text = taxRate.toStringAsFixed(0);
    this.discount.text = discount.toStringAsFixed(2);
  }

  void dispose() {
    name.dispose();
    hsn.dispose();
    qty.dispose();
    rate.dispose();
    tax.dispose();
    discount.dispose();
  }
}
