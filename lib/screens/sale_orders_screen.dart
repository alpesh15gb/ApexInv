import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/customer_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/sale_order_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/sale_order.dart';

class SaleOrdersScreen extends StatefulWidget {
  const SaleOrdersScreen({super.key});

  @override
  State<SaleOrdersScreen> createState() => _SaleOrdersScreenState();
}

class _SaleOrdersScreenState extends State<SaleOrdersScreen> {
  List<SaleOrder> _orders = const [];
  String? _status;
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await SaleOrderService.getOrders(status: _status);
    if (mounted) setState(() { _orders = rows; _loading = false; });
  }

  Future<void> _openForm([SaleOrder? existing]) async {
    final customers = await CustomerService.getAllCustomers();
    final products = await ProductService.getAllProducts();
    final currency = await SettingsService.getCurrency();
    if (!mounted) return;
    if (customers.isEmpty || products.isEmpty) {
      _error('Create at least one customer and product first.');
      return;
    }
    Customer customer = existing == null
        ? customers.first
        : customers.firstWhere((c) => c.id == existing.customerId,
            orElse: () => customers.first);
    final notes = TextEditingController(text: existing?.notes ?? '');
    DateTime date = existing?.date ?? DateTime.now();
    DateTime? expected = existing?.expectedDate;
    final drafts = existing == null
        ? <_SaleOrderLineDraft>[_SaleOrderLineDraft(products.first)]
        : existing.items.map((item) => _SaleOrderLineDraft(
            products.firstWhere((p) => p.id == item.productId,
                orElse: () => products.first),
            quantity: item.quantity,
            price: item.unitPrice,
            discount: item.discount,
            description: item.description)).toList();
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: Text(existing == null ? 'New Sale Order' : 'Edit Sale Order'),
        content: SizedBox(width: 1080, height: MediaQuery.sizeOf(ctx).height * .78, child: Column(children: [
          Align(alignment: Alignment.centerLeft, child: Text('Order details',
            style: Theme.of(ctx).textTheme.titleSmall)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: DropdownButtonFormField<String>(
              value: customer.id,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: customers.map((c) => DropdownMenuItem(value: c.id,
                  child: Text(c.name))).toList(),
              onChanged: (v) => customer = customers.firstWhere((c) => c.id == v))),
            const SizedBox(width: 12),
            Expanded(child: ListTile(contentPadding: EdgeInsets.zero,
              title: const Text('Order date'),
              subtitle: Text(date.toLocal().toString().split(' ').first),
              onTap: () async {
                final picked = await showDatePicker(context: ctx, initialDate: date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now().add(const Duration(days: 365)));
                if (picked != null) setDialogState(() => date = picked);
              })),
            Expanded(child: ListTile(contentPadding: EdgeInsets.zero,
              title: const Text('Expected date'),
              subtitle: Text(expected == null ? 'Not set' :
                  expected!.toLocal().toString().split(' ').first),
              onTap: () async {
                final picked = await showDatePicker(context: ctx,
                  initialDate: expected ?? date.add(const Duration(days: 7)),
                  firstDate: date, lastDate: date.add(const Duration(days: 3650)));
                if (picked != null) setDialogState(() => expected = picked);
              })),
          ]),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text('Line items',
            style: Theme.of(ctx).textTheme.titleSmall)),
          const SizedBox(height: 4),
          Expanded(child: ListView.builder(itemCount: drafts.length,
            itemBuilder: (context, index) {
              final draft = drafts[index];
              return Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [
                Row(children: [
                  Expanded(flex: 3, child: DropdownButtonFormField<String>(
                    value: draft.product.id,
                    decoration: const InputDecoration(labelText: 'Product', isDense: true),
                    items: products.map((p) => DropdownMenuItem(value: p.id,
                      child: Text(p.name))).toList(),
                    onChanged: (v) => setDialogState(() {
                      draft.product = products.firstWhere((p) => p.id == v);
                      draft.price.text = draft.product.price.toStringAsFixed(2);
                    }))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: draft.quantity,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Qty', isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: draft.price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Price', isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: draft.discount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Discount', isDense: true))),
                  IconButton(onPressed: drafts.length == 1 ? null : () =>
                    setDialogState(() { drafts.removeAt(index).dispose(); }),
                    icon: const Icon(Icons.delete_outline)),
                ]),
                TextField(controller: draft.description,
                  decoration: const InputDecoration(labelText: 'Line description', isDense: true)),
              ])));
            })),
          Row(children: [
            TextButton.icon(onPressed: () => setDialogState(() =>
              drafts.add(_SaleOrderLineDraft(products.first))),
              icon: const Icon(Icons.add), label: const Text('Add line')),
            const Spacer(),
            Text('${currency.symbol} ${_draftTotal(drafts).toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleMedium),
          ]),
          TextField(controller: notes,
            decoration: const InputDecoration(labelText: 'Notes')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save draft')),
        ],
      )));
    if (ok != true) { for (final d in drafts) { d.dispose(); } return; }
    try {
      final orderId = existing?.id ?? const Uuid().v4();
      final orderNumber = existing?.orderNumber ?? await SaleOrderService.nextOrderNumber();
      final items = <SaleOrderItem>[];
      for (final draft in drafts) {
        final qty = double.tryParse(draft.quantity.text.trim()) ?? 0;
        final price = double.tryParse(draft.price.text.trim()) ?? 0;
        if (qty <= 0) throw StateError('Every line needs a positive quantity');
        final existingLine = existing != null && items.length < existing.items.length
            ? existing.items[items.length]
            : null;
        items.add(SaleOrderItem(
          id: existingLine?.id ?? const Uuid().v4(),
          saleOrderId: orderId,
          productId: draft.product.id,
          productName: draft.product.name,
          description: draft.description.text.trim(),
          quantity: qty,
          fulfilledQuantity: existingLine?.fulfilledQuantity ?? 0,
          unitPrice: price,
          taxRate: draft.product.tax_rate.toDouble(),
          discount: double.tryParse(draft.discount.text.trim()) ?? 0));
      }
      await SaleOrderService.saveOrder(SaleOrder(
        id: orderId, orderNumber: orderNumber, customerId: customer.id,
        customerName: customer.name, customerEmail: customer.email,
        customerPhone: customer.phone, customerAddress: customer.address,
        customerGstin: customer.gstin, date: date, expectedDate: expected,
        status: 'draft', currencyCode: currency.code,
        currencySymbol: currency.symbol, notes: notes.text.trim(), items: items));
      await _load();
    } catch (e) { _error(e); }
    finally { for (final d in drafts) { d.dispose(); } }
  }

  double _draftTotal(List<_SaleOrderLineDraft> drafts) => drafts.fold(0, (sum, d) {
    final qty = double.tryParse(d.quantity.text) ?? 0;
    final price = double.tryParse(d.price.text) ?? 0;
    final discount = double.tryParse(d.discount.text) ?? 0;
    final taxable = (qty * price - discount).clamp(0, double.infinity);
    return sum + taxable + taxable * d.product.tax_rate / 100;
  });

  Future<void> _fulfill(SaleOrder order) async {
    final controllers = <String, TextEditingController>{
      for (final item in order.items)
        if (item.remainingQuantity > 0)
          item.id: TextEditingController(text: item.remainingQuantity.toString())
    };
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Fulfill ${order.orderNumber}'),
      content: SizedBox(width: 560, child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('An invoice will be created and stock deducted for these quantities.'),
        const SizedBox(height: 12),
        ...order.items.where((i) => i.remainingQuantity > 0).map((item) =>
          ListTile(title: Text(item.productName),
            subtitle: Text('Remaining ${item.remainingQuantity}'),
            trailing: SizedBox(width: 120, child: TextField(
              controller: controllers[item.id],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Invoice qty'))))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create invoice')),
      ],
    ));
    if (ok != true) { for (final c in controllers.values) { c.dispose(); } return; }
    try {
      final invoiceId = await SaleOrderService.fulfillToInvoice(order.id,
        quantitiesByItemId: {for (final e in controllers.entries)
          e.key: double.tryParse(e.value.text.trim()) ?? 0});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invoice $invoiceId created from ${order.orderNumber}.'),
        backgroundColor: Colors.green));
      await _load();
    } catch (e) { _error(e); }
    finally { for (final c in controllers.values) { c.dispose(); } }
  }

  Future<void> _act(SaleOrder order, String action) async {
    try {
      if (action == 'confirm') await SaleOrderService.confirm(order.id);
      if (action == 'cancel') await SaleOrderService.cancel(order.id);
      if (action == 'delete') await SaleOrderService.deleteDraft(order.id);
      if (action == 'fulfill') { await _fulfill(order); return; }
      if (action == 'edit') { await _openForm(order); return; }
      await _load();
    } catch (e) { _error(e); }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(e.toString().replaceFirst('StateError: ', '')),
      backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sale Orders'), actions: [
      FilledButton.icon(onPressed: () => _openForm(), icon: const Icon(Icons.add, size: 18),
        label: const Text('New Order')),
      const SizedBox(width: 8), IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      const SizedBox(width: 8),
    ]),
    body: Column(children: [
      SizedBox(height: 58, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [null, 'draft', 'confirmed', 'partial', 'fulfilled', 'cancelled']
          .map((status) => Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(
            selected: _status == status,
            label: Text(status == null ? 'All' : '${status[0].toUpperCase()}${status.substring(1)}'),
            onSelected: (_) { setState(() => _status = status); _load(); }))).toList())),
      const Divider(height: 1),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) :
        _orders.isEmpty ? const Center(child: Text('No sale orders in this view.')) :
        ListView.separated(padding: const EdgeInsets.all(16), itemCount: _orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => _card(_orders[index]))),
    ]),
  );

  Widget _card(SaleOrder order) {
    final color = switch (order.status) {
      'fulfilled' => Colors.green, 'confirmed' => Colors.blue,
      'partial' => Colors.deepOrange, 'cancelled' => Colors.red, _ => Colors.orange,
    };
    return Card(child: ListTile(
      leading: CircleAvatar(backgroundColor: color.withValues(alpha: .12),
        child: Icon(Icons.shopping_bag_outlined, color: color)),
      title: Text('${order.orderNumber} • ${order.customerName}'),
      subtitle: Text('${order.date.toLocal().toString().split(' ').first} • '
        '${order.items.length} item(s) • ${order.status}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${order.currencySymbol} ${order.total.toStringAsFixed(2)}',
          style: const TextStyle(fontWeight: FontWeight.bold)),
        PopupMenuButton<String>(onSelected: (v) => _act(order, v), itemBuilder: (_) => [
          if (order.status == 'draft') const PopupMenuItem(value: 'edit', child: Text('Edit')),
          if (order.status == 'draft') const PopupMenuItem(value: 'confirm', child: Text('Confirm & reserve')),
          if (order.status == 'confirmed' || order.status == 'partial')
            const PopupMenuItem(value: 'fulfill', child: Text('Create invoice / fulfill')),
          if (order.status != 'fulfilled' && order.status != 'cancelled')
            const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
          if (order.status == 'draft' || order.status == 'cancelled')
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ]),
      ]),
    ));
  }
}

class _SaleOrderLineDraft {
  Product product;
  final TextEditingController quantity;
  final TextEditingController price;
  final TextEditingController discount;
  final TextEditingController description;

  _SaleOrderLineDraft(this.product, {double quantity = 1, double? price,
      double discount = 0, String description = ''})
      : quantity = TextEditingController(text: quantity.toString()),
        price = TextEditingController(text: (price ?? product.price).toStringAsFixed(2)),
        discount = TextEditingController(text: discount.toStringAsFixed(2)),
        description = TextEditingController(text: description);

  void dispose() { quantity.dispose(); price.dispose(); discount.dispose(); description.dispose(); }
}
