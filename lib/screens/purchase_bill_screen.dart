import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/user.dart';

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
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pay ${bill.supplierName}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.fieldTotalLabel,
            prefixText: '${bill.currencySymbol} ',
            hintText: bill.outstanding.toStringAsFixed(2),
          ),
        ),
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
    await PurchaseBillService.recordPayment(bill.id, amount);
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
          IconButton(
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: l10n.actionRefresh,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('New Bill'),
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
  final _supplierCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _billNoCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  bool _itcEligible = true;
  bool _reverseCharge = false;
  bool _interState = false;
  bool _isSaving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
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
      _billNoCtrl.text = e.billNumber ?? '';
      _notesCtrl.text = e.notes;
      _date = e.date;
      _dueDate = e.dueDate;
      _itcEligible = e.itcEligible;
      _reverseCharge = e.reverseCharge;
      _interState = e.igstTotal > 0;
    }
  }

  @override
  void dispose() {
    _supplierCtrl.dispose();
    _gstinCtrl.dispose();
    _phoneCtrl.dispose();
    _billNoCtrl.dispose();
    _notesCtrl.dispose();
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  List<PurchaseBillItem> get _computedItems {
    final id = widget.existing?.id ?? const Uuid().v4();
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
            ))
        .toList();
  }

  double get _totalTaxable =>
      _computedItems.fold(0, (s, i) => s + i.taxableValue);
  double get _totalTax =>
      _computedItems.fold(0, (s, i) => s + i.amount - i.taxableValue);
  double get _grandTotal => _computedItems.fold(0, (s, i) => s + i.amount);

  Future<void> _save() async {
    if (_supplierCtrl.text.trim().isEmpty ||
        _isSaving ||
        _computedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Supplier name and at least one item are required')));
      return;
    }
    setState(() => _isSaving = true);
    final id = widget.existing?.id ?? const Uuid().v4();
    final bill = PurchaseBill(
      id: id,
      billNumber: _billNoCtrl.text.trim(),
      supplierName: _supplierCtrl.text.trim(),
      supplierGstin: _gstinCtrl.text.trim().toUpperCase(),
      supplierPhone: _phoneCtrl.text.trim(),
      date: _date,
      dueDate: _dueDate,
      totalAmount: _grandTotal,
      totalTax: _totalTax,
      amountPaid: widget.existing?.amountPaid ?? 0,
      itcEligible: _itcEligible,
      reverseCharge: _reverseCharge,
      notes: _notesCtrl.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM yyyy');
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Purchase Bill' : 'New Purchase Bill'),
        backgroundColor:
            theme.appBarTheme.backgroundColor ?? theme.primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save_outlined)),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('Supplier Name *'),
            TextField(
                controller: _supplierCtrl,
                decoration: _dec('Supplier / vendor')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _label('Supplier GSTIN')),
              const SizedBox(width: 12),
              Expanded(child: _label('Phone')),
            ]),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _gstinCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: _dec('27ABCDE1234F1Z5'))),
              const SizedBox(width: 12),
              Expanded(
                  child: TextField(
                      controller: _phoneCtrl,
                      decoration: _dec('Phone'),
                      keyboardType: TextInputType.phone)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _label('Supplier Invoice No')),
              const SizedBox(width: 12),
              Expanded(child: _label('Date')),
            ]),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _billNoCtrl,
                      decoration: _dec('Supplier inv no'))),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () => _pickDate(due: false),
                  child: InputDecorator(
                    decoration: _dec('Bill date'),
                    child: Text(df.format(_date)),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InkWell(
                  onTap: () => _pickDate(due: true),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                        labelText: 'Due date', border: OutlineInputBorder()),
                    child: Text(_dueDate == null ? '—' : df.format(_dueDate!)),
                  ),
                ),
                FilterChip(
                  selected: _interState,
                  label: const Text('Inter-state (IGST)'),
                  onSelected: (v) => setState(() => _interState = v),
                ),
                FilterChip(
                  selected: _reverseCharge,
                  label: const Text('Reverse charge'),
                  onSelected: (v) => setState(() => _reverseCharge = v),
                ),
                FilterChip(
                  selected: _itcEligible,
                  label: const Text('ITC eligible'),
                  onSelected: (v) => setState(() => _itcEligible = v),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _label('Items'),
            const SizedBox(height: 8),
            ..._items.asMap().entries.map((e) => _itemEditor(e.key, e.value)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _items.add(_ItemDraft())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add item'),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _totalRow('Taxable', _totalTaxable),
                      _totalRow('Tax', _totalTax),
                      const Divider(),
                      _totalRow('Total', _grandTotal, bold: true),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            _label('Notes'),
            TextField(
                controller: _notesCtrl, maxLines: 2, decoration: _dec('')),
            const SizedBox(height: 90),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_outlined),
              label: const Text('Save Bill'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
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
        Text(value.toStringAsFixed(2),
            style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      );

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
