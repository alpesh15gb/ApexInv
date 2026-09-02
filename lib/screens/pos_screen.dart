import 'package:flutter/material.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/customer_service.dart';
import 'package:apexbooks/database/pos_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/sale_order_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  List<Product> _products = const [];
  List<Customer> _customers = const [];
  List<FinancialAccount> _accounts = const [];
  Map<String, double> _reserved = const {};
  final Map<String, InvoiceItem> _cart = {};
  final _search = TextEditingController();
  Customer? _customer;
  String _currencyCode = 'INR';
  String _currencySymbol = '₹';
  bool _loading = true;
  bool _saving = false;

  Customer get _walkIn => Customer(id: 'walk-in', name: 'Walk-in Customer',
      email: '', phone: '', address: '', gstin: '');

  @override
  void initState() { super.initState(); _load(); _search.addListener(() => setState(() {})); }

  @override
  void dispose() { _search.dispose(); super.dispose(); }

  Future<void> _load() async {
    final results = await Future.wait([
      ProductService.getAllProducts(), CustomerService.getAllCustomers(),
      AccountingService.getAccounts(), SaleOrderService.getReservedQuantities(),
      SettingsService.getCurrency(),
    ]);
    if (!mounted) return;
    setState(() {
      _products = results[0] as List<Product>;
      _customers = results[1] as List<Customer>;
      _accounts = results[2] as List<FinancialAccount>;
      _reserved = results[3] as Map<String, double>;
      final currency = results[4] as dynamic;
      _currencyCode = currency.code as String;
      _currencySymbol = currency.symbol as String;
      _customer ??= _walkIn;
      _loading = false;
    });
  }

  List<Product> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _products;
    return _products.where((p) => p.name.toLowerCase().contains(q) ||
      p.barcode.toLowerCase().contains(q)).toList();
  }

  double _available(Product product) => product.unlimitedStock
      ? double.infinity
      : (product.stock.toDouble() - (_reserved[product.id] ?? 0))
          .clamp(0, double.infinity).toDouble();

  void _add(Product product) {
    final existing = _cart[product.id];
    final next = (existing?.quantity ?? 0) + 1;
    if (!product.unlimitedStock && next > _available(product) + 0.000001) {
      _error('No unreserved stock available for ${product.name}.');
      return;
    }
    setState(() => _cart[product.id] = InvoiceItem(
      id: existing?.id, product: product, quantity: next,
      discount: existing?.discount ?? product.defaultDiscount,
      unitPrice: existing?.unitPrice));
  }

  void _changeQty(Product product, double delta) {
    final existing = _cart[product.id];
    if (existing == null) return;
    final next = existing.quantity + delta;
    if (next <= 0) { setState(() => _cart.remove(product.id)); return; }
    if (!product.unlimitedStock && next > _available(product) + 0.000001) {
      _error('Only ${_available(product)} unreserved units are available.'); return;
    }
    setState(() => _cart[product.id] = InvoiceItem(id: existing.id,
      product: product, quantity: next, discount: existing.discount,
      unitPrice: existing.unitPrice));
  }

  Invoice get _previewInvoice => Invoice(
        id: 'pos-preview',
        customer: _customer ?? _walkIn,
        items: _cart.values.toList(),
        date: DateTime.now(),
        type: 'Invoice',
        taxMode: TaxMode.perItem,
      );

  double get _subtotal => _previewInvoice.subtotal;
  double get _tax => _previewInvoice.tax;
  double get _total => _previewInvoice.total;
  int get _itemCount => _cart.values.fold(0, (count, item) =>
      count + item.quantity.round());

  Future<void> _checkout() async {
    if (_cart.isEmpty || _saving) return;
    if (_accounts.isEmpty) { _error('Create a cash or bank account first.'); return; }
    final tenders = <_TenderDraft>[_TenderDraft('Cash', _total, _accounts)];
    final notes = TextEditingController();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Complete sale'),
        content: SizedBox(width: 680, height: 480, child: Column(children: [
          Row(children: [
            const Text('Sale total', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(), Text('$_currencySymbol ${_total.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleLarge),
          ]),
          const SizedBox(height: 8),
          Expanded(child: ListView.builder(itemCount: tenders.length,
            itemBuilder: (context, index) {
              final tender = tenders[index];
              final accountChoices = _accounts.where((a) =>
                tender.method == 'Cash' ? a.type == 'cash' : a.type == 'bank').toList();
              if (accountChoices.isNotEmpty &&
                  !accountChoices.any((a) => a.id == tender.accountId)) {
                tender.accountId = accountChoices.first.id;
              }
              return Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [
                Row(children: [
                  Expanded(child: DropdownButtonFormField<String>(value: tender.method,
                    decoration: const InputDecoration(labelText: 'Method', isDense: true),
                    items: const ['Cash', 'Bank Transfer', 'Online', 'Check']
                      .map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                    onChanged: (v) => setDialogState(() => tender.method = v!))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: tender.amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Amount', isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: DropdownButtonFormField<String>(value: tender.accountId,
                    decoration: const InputDecoration(labelText: 'Account', isDense: true),
                    items: accountChoices.map((a) => DropdownMenuItem(value: a.id,
                      child: Text(a.name))).toList(),
                    onChanged: (v) => tender.accountId = v)),
                  IconButton(onPressed: tenders.length == 1 ? null : () => setDialogState(() {
                    tenders.removeAt(index).dispose();
                  }), icon: const Icon(Icons.delete_outline)),
                ]),
                if (tender.method == 'Check') Row(children: [
                  Expanded(child: TextField(controller: tender.chequeNumber,
                    decoration: const InputDecoration(labelText: 'Cheque number'))),
                  const SizedBox(width: 8),
                  Expanded(child: ListTile(contentPadding: EdgeInsets.zero,
                    title: const Text('Cheque date'),
                    subtitle: Text(tender.chequeDate.toLocal().toString().split(' ').first),
                    onTap: () async {
                      final picked = await showDatePicker(context: ctx,
                        initialDate: tender.chequeDate, firstDate: DateTime(2000),
                        lastDate: DateTime.now().add(const Duration(days: 730)));
                      if (picked != null) setDialogState(() => tender.chequeDate = picked);
                    })),
                ]),
              ])));
            })),
          Row(children: [
            TextButton.icon(onPressed: () => setDialogState(() =>
              tenders.add(_TenderDraft('Bank Transfer', 0, _accounts))),
              icon: const Icon(Icons.add), label: const Text('Split tender')),
            const Spacer(),
            Text('Tendered $_currencySymbol ${tenders.fold(0.0, (s, t) => s + (double.tryParse(t.amount.text) ?? 0)).toStringAsFixed(2)}'),
          ]),
          TextField(controller: notes,
            decoration: const InputDecoration(labelText: 'Receipt notes')),
          if (_customer?.id == 'walk-in') const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Walk-in sales must be fully paid.', style: TextStyle(color: Colors.orange))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Finalize & post')),
        ],
      )));
    if (ok != true) { for (final t in tenders) { t.dispose(); } notes.dispose(); return; }
    setState(() => _saving = true);
    try {
      final invoice = await PosService.finalize(
        customer: _customer ?? _walkIn, items: _cart.values.toList(),
        tenders: tenders.map((t) => PosTender(method: t.method,
          amount: double.tryParse(t.amount.text.trim()) ?? 0,
          accountId: t.accountId,
          chequeNumber: t.method == 'Check' ? t.chequeNumber.text.trim() : null,
          chequeDate: t.method == 'Check' ? t.chequeDate : null)).toList(),
        currencyCode: _currencyCode, currencySymbol: _currencySymbol,
        notes: notes.text.trim());
      if (!mounted) return;
      setState(() { _cart.clear(); _customer = _walkIn; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sale ${invoice.invoiceNumber} posted successfully.'),
        backgroundColor: Colors.green));
      await _load();
    } catch (e) { _error(e); }
    finally {
      for (final t in tenders) { t.dispose(); } notes.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(e.toString().replaceFirst('StateError: ', '')),
      backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('POS'), actions: [
      IconButton(tooltip: 'Refresh stock', onPressed: _load,
          icon: const Icon(Icons.refresh)),
      if (_cart.isNotEmpty) TextButton.icon(onPressed: () => setState(_cart.clear),
        icon: const Icon(Icons.delete_sweep_outlined), label: const Text('Clear cart')),
      const SizedBox(width: 8),
    ]),
    body: _loading ? const Center(child: CircularProgressIndicator()) :
      LayoutBuilder(builder: (context, constraints) {
        final products = _productPane(); final cart = _cartPane();
        if (constraints.maxWidth < 850) return Column(children: [
          Expanded(flex: 3, child: products), const Divider(height: 1),
          Expanded(flex: 2, child: cart)]);
        return Row(children: [Expanded(flex: 3, child: products),
          const VerticalDivider(width: 1), SizedBox(width: 410, child: cart)]);
      }),
  );

  Widget _productPane() => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: TextField(controller: _search,
      decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
        labelText: 'Search name or barcode', border: OutlineInputBorder()))),
    Expanded(child: _filtered.isEmpty ? const Center(child: Text('No products found')) :
      RefreshIndicator(onRefresh: _load, child: GridView.builder(padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 230, childAspectRatio: 1.6, crossAxisSpacing: 10, mainAxisSpacing: 10),
        itemCount: _filtered.length,
        itemBuilder: (context, index) {
          final product = _filtered[index]; final available = _available(product);
          final canAdd = product.unlimitedStock || available > 0;
          return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: canAdd ? () => _add(product) : null,
            child: Padding(padding: const EdgeInsets.all(12), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Expanded(child: Text(product.name, maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold))),
                  Icon(canAdd ? Icons.add_circle_outline : Icons.block_outlined,
                    color: canAdd ? Theme.of(context).colorScheme.primary : Colors.red)]),
                const Spacer(), Text('$_currencySymbol ${product.price.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(product.unlimitedStock ? 'Service / unlimited' :
                  '${available.toStringAsFixed(2)} available',
                  style: TextStyle(fontSize: 12, color: available <= 0 ? Colors.red : null)),
              ]))));
        }))),
  ]);

  Widget _cartPane() => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 8), child: Row(children: [
      Text('Current sale', style: Theme.of(context).textTheme.titleMedium),
      const Spacer(),
      if (_cart.isNotEmpty) Chip(label: Text('$_itemCount item${_itemCount == 1 ? '' : 's'}')),
    ])),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: DropdownButtonFormField<String>(
      value: _customer?.id ?? 'walk-in', decoration: const InputDecoration(
        labelText: 'Customer', border: OutlineInputBorder()),
      items: [_walkIn, ..._customers].map((c) => DropdownMenuItem(value: c.id,
        child: Text(c.name))).toList(),
      onChanged: (id) => setState(() => _customer = id == 'walk-in' ? _walkIn :
        _customers.firstWhere((c) => c.id == id)))),
    const Divider(height: 1),
    Expanded(child: _cart.isEmpty ? const Center(child: Text('Tap a product to add it')) :
      ListView.separated(itemCount: _cart.length, separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _cart.values.elementAt(index);
          return ListTile(title: Text(item.product.name),
            subtitle: Text('${item.quantity} × $_currencySymbol ${(item.unitPrice ?? item.product.price).toStringAsFixed(2)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(onPressed: () => _changeQty(item.product, -1), icon: const Icon(Icons.remove_circle_outline)),
              Text(item.quantity.toStringAsFixed(item.quantity % 1 == 0 ? 0 : 2),
                style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => _changeQty(item.product, 1), icon: const Icon(Icons.add_circle_outline)),
              IconButton(tooltip: 'Remove item', onPressed: () => setState(() => _cart.remove(item.product.id)),
                icon: const Icon(Icons.close)),
            ]));
        })),
    const Divider(height: 1),
    Padding(padding: const EdgeInsets.all(16), child: Column(children: [
      _summary('Subtotal', _subtotal), _summary('Tax', _tax),
      const Divider(), _summary('Total', _total, bold: true),
      const SizedBox(height: 12), SizedBox(width: double.infinity,
        child: FilledButton.icon(onPressed: _cart.isEmpty || _saving ? null : _checkout,
          icon: _saving ? const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.point_of_sale),
          label: Text(_saving ? 'Posting…' : 'Checkout'))),
    ])),
  ]);

  Widget _summary(String label, double amount, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
      Text(label, style: bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 17) : null),
      const Spacer(), Text('$_currencySymbol ${amount.toStringAsFixed(2)}',
        style: bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 17) : null),
    ]));
}

class _TenderDraft {
  String method;
  String? accountId;
  final TextEditingController amount;
  final TextEditingController chequeNumber = TextEditingController();
  DateTime chequeDate = DateTime.now();

  _TenderDraft(this.method, double value, List<FinancialAccount> accounts)
      : amount = TextEditingController(text: value.toStringAsFixed(2)) {
    final wanted = method == 'Cash' ? 'cash' : 'bank';
    for (final account in accounts) {
      if (account.type == wanted) { accountId = account.id; break; }
    }
  }

  void dispose() { amount.dispose(); chequeNumber.dispose(); }
}
