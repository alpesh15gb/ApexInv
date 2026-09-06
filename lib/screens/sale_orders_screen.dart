import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/customer_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/sale_order_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/licensing/license_gate.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/sale_order.dart';
import 'package:apexbooks/widgets/app/app.dart';
import 'package:apexbooks/widgets/document_editor_shell.dart';

class SaleOrdersScreen extends StatefulWidget {
  const SaleOrdersScreen({super.key});

  @override
  State<SaleOrdersScreen> createState() => _SaleOrdersScreenState();
}

class _SaleOrdersScreenState extends State<SaleOrdersScreen> {
  List<SaleOrder> _allOrders = const [];
  String? _status;
  bool _loading = true;
  String _search = '';
  DateTime? _fromDate;
  DateTime? _toDate;
  String _sortField = 'date'; // 'number' | 'date' | 'customer' | 'total'
  bool _sortAsc = false;
  int _page = 0;
  int _pageSize = 10;
  final TextEditingController _searchController = TextEditingController();

  static const List<String> _statuses = [
    'draft',
    'confirmed',
    'partial',
    'fulfilled',
    'cancelled',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Reference-design revamp: the full set is loaded with the existing
    // query (no new query semantics) and status/search/date are applied in
    // memory below, so the chips show LIVE counts from already-loaded rows.
    final rows = await SaleOrderService.getOrders();
    if (mounted) {
      setState(() {
        _allOrders = rows;
        _loading = false;
        _clampPage();
      });
    }
  }

  void _clampPage() {
    final pages = _totalPages;
    if (pages <= 0) {
      _page = 0;
    } else if (_page >= pages) {
      _page = pages - 1;
    }
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Search + date context (status-independent): the rows the chip counts
  /// aggregate over.
  List<SaleOrder> get _contextOrders {
    final q = _search.trim().toLowerCase();
    return _allOrders.where((o) {
      if (q.isNotEmpty &&
          !o.orderNumber.toLowerCase().contains(q) &&
          !o.customerName.toLowerCase().contains(q)) {
        return false;
      }
      if (_fromDate != null && _day(o.date).isBefore(_day(_fromDate!))) {
        return false;
      }
      if (_toDate != null && _day(o.date).isAfter(_day(_toDate!))) {
        return false;
      }
      return true;
    }).toList();
  }

  Map<String, int> get _statusCounts {
    final context = _contextOrders;
    final counts = <String, int>{'all': context.length};
    for (final s in _statuses) {
      counts[s] = 0;
    }
    for (final o in context) {
      counts[o.status] = (counts[o.status] ?? 0) + 1;
    }
    return counts;
  }

  /// Visible rows: status chip + in-memory sort. Same rows the old
  /// status-filtered query returned, minus any query round-trip.
  List<SaleOrder> get _visibleOrders {
    Iterable<SaleOrder> rows = _contextOrders;
    if (_status != null) {
      rows = rows.where((o) => o.status == _status);
    }
    final list = rows.toList();
    list.sort((a, b) {
      final int c;
      switch (_sortField) {
        case 'number':
          c = a.orderNumber.compareTo(b.orderNumber);
        case 'customer':
          c = a.customerName.toLowerCase().compareTo(
                b.customerName.toLowerCase(),
              );
        case 'total':
          c = a.displayTotal.compareTo(b.displayTotal);
        default:
          c = a.date.compareTo(b.date);
      }
      return _sortAsc ? c : -c;
    });
    return list;
  }

  int get _totalCount => _visibleOrders.length;

  int get _totalPages => (_totalCount / _pageSize).ceil();

  void _changeSort(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAsc = !_sortAsc;
      } else {
        _sortField = field;
        _sortAsc = field == 'number' || field == 'customer';
      }
      _page = 0;
    });
  }

  Future<void> _openForm([SaleOrder? existing]) async {
    final customers = await CustomerService.getAllCustomers();
    final products = await ProductService.getAllProducts();
    final currency = await SettingsService.getCurrency();
    final defaultPricesIncludeTax =
        await SettingsService.getDefaultPriceIncludesTax();
    if (!mounted) return;
    if (customers.isEmpty || products.isEmpty) {
      _error('Create at least one customer and product first.');
      return;
    }
    Customer customer = existing == null
        ? customers.first
        : customers.firstWhere((c) => c.id == existing.customerId,
            orElse: () => customers.first);
    var customerBalance = await InvoiceService.getPreviousBalanceDueForCustomer(
      customerId: customer.id,
      currencyCode: currency.code,
      asOfDate: DateTime.now(),
    );
    final notes = TextEditingController(text: existing?.notes ?? '');
    DateTime date = existing?.date ?? DateTime.now();
    DateTime? expected = existing?.expectedDate;
    // Document-level GST toggle: existing orders keep their stored flag,
    // new orders start from the global default. Applies to all lines.
    bool pricesIncludeTax =
        existing?.priceIncludesTax ?? defaultPricesIncludeTax;
    final drafts = existing == null
        ? <_SaleOrderLineDraft>[_SaleOrderLineDraft(products.first)]
        : existing.items
            .map((item) => _SaleOrderLineDraft(
                products.firstWhere((p) => p.id == item.productId,
                    orElse: () => products.first),
                quantity: item.quantity,
                price: item.unitPrice,
                discount: item.discount,
                description: item.description))
            .toList();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => Dialog.fullscreen(
                  child: Scaffold(
                    appBar: AppBar(
                        title: Text(existing == null
                            ? 'New Sale Order'
                            : 'Edit Sale Order')),
                    body: DocumentEditorShell(
                      stateLabel: existing == null
                          ? 'Draft workspace'
                          : 'Editing draft',
                      validationErrors: const [],
                      editor: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1120),
                            child: Column(children: [
                              _contextPanel(ctx, currency.symbol, customer.name,
                                  customerBalance, drafts, existing),
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Order details',
                                      style:
                                          Theme.of(ctx).textTheme.titleSmall)),
                              const SizedBox(height: 8),
                              LayoutBuilder(builder: (context, constraints) {
                                final wide = constraints.maxWidth >= 700;
                                final fieldWidth = wide
                                    ? (constraints.maxWidth - 12) / 2
                                    : constraints.maxWidth;
                                return Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    children: [
                                      SizedBox(
                                          width: fieldWidth,
                                          child: DropdownButtonFormField<
                                                  String>(
                                              value: customer.id,
                                              decoration: const InputDecoration(
                                                  labelText: 'Customer'),
                                              items: customers
                                                  .map((c) => DropdownMenuItem(
                                                      value: c.id,
                                                      child: Text(c.name)))
                                                  .toList(),
                                              onChanged: (v) async {
                                                if (v == null) return;
                                                final next =
                                                    customers.firstWhere(
                                                        (c) => c.id == v);
                                                setDialogState(
                                                    () => customer = next);
                                                final balance = await InvoiceService
                                                    .getPreviousBalanceDueForCustomer(
                                                        customerId: next.id,
                                                        currencyCode:
                                                            currency.code,
                                                        asOfDate:
                                                            DateTime.now());
                                                if (!ctx.mounted) return;
                                                setDialogState(() =>
                                                    customerBalance = balance);
                                              })),
                                      SizedBox(
                                          width: fieldWidth,
                                          child: ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title: const Text('Order date'),
                                              subtitle: Text(date
                                                  .toLocal()
                                                  .toString()
                                                  .split(' ')
                                                  .first),
                                              onTap: () async {
                                                final picked =
                                                    await showDatePicker(
                                                        context: ctx,
                                                        initialDate: date,
                                                        firstDate:
                                                            DateTime(2000),
                                                        lastDate: DateTime.now()
                                                            .add(const Duration(
                                                                days: 365)));
                                                if (picked != null)
                                                  setDialogState(
                                                      () => date = picked);
                                              })),
                                      SizedBox(
                                          width: fieldWidth,
                                          child: ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title:
                                                  const Text('Expected date'),
                                              subtitle: Text(expected == null
                                                  ? 'Not set'
                                                  : expected!
                                                      .toLocal()
                                                      .toString()
                                                      .split(' ')
                                                      .first),
                                              onTap: () async {
                                                final picked =
                                                    await showDatePicker(
                                                        context: ctx,
                                                        initialDate:
                                                            expected ??
                                                                date.add(
                                                                    const Duration(
                                                                        days:
                                                                            7)),
                                                        firstDate: date,
                                                        lastDate: date.add(
                                                            const Duration(
                                                                days: 3650)));
                                                if (picked != null)
                                                  setDialogState(
                                                      () => expected = picked);
                                              })),
                                    ]);
                              }),
                              const SizedBox(height: 12),
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Line items',
                                      style:
                                          Theme.of(ctx).textTheme.titleSmall)),
                              const SizedBox(height: 4),
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: SegmentedButton<bool>(
                                    segments: const [
                                      ButtonSegment<bool>(
                                          value: false,
                                          label: Text('Excl GST')),
                                      ButtonSegment<bool>(
                                          value: true, label: Text('Incl GST')),
                                    ],
                                    selected: {pricesIncludeTax},
                                    onSelectionChanged: (selection) =>
                                        setDialogState(() =>
                                            pricesIncludeTax = selection.first),
                                  )),
                              const SizedBox(height: 4),
                              ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: drafts.length,
                                  itemBuilder: (context, index) {
                                    final draft = drafts[index];
                                    return Card(
                                        child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(children: [
                                              LayoutBuilder(builder:
                                                  (context, constraints) {
                                                final narrow =
                                                    constraints.maxWidth < 680;
                                                final productWidth = narrow
                                                    ? constraints.maxWidth
                                                    : constraints.maxWidth *
                                                        .42;
                                                final detailWidth = narrow
                                                    ? (constraints.maxWidth -
                                                            8) /
                                                        2
                                                    : (constraints.maxWidth -
                                                            productWidth -
                                                            72) /
                                                        3;
                                                return Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: [
                                                      SizedBox(
                                                          width: productWidth,
                                                          child: DropdownButtonFormField<
                                                                  String>(
                                                              value: draft
                                                                  .product.id,
                                                              decoration:
                                                                  const InputDecoration(
                                                                      labelText:
                                                                          'Product',
                                                                      isDense:
                                                                          true),
                                                              items: products
                                                                  .map((p) => DropdownMenuItem(
                                                                      value:
                                                                          p.id,
                                                                      child: Text(p
                                                                          .name)))
                                                                  .toList(),
                                                              onChanged: (v) =>
                                                                  setDialogState(
                                                                      () {
                                                                    draft.product =
                                                                        products.firstWhere((p) =>
                                                                            p.id ==
                                                                            v);
                                                                    draft.price.text = draft
                                                                        .product
                                                                        .price
                                                                        .toStringAsFixed(
                                                                            2);
                                                                  }))),
                                                      SizedBox(
                                                          width: detailWidth,
                                                          child: TextField(
                                                              controller: draft
                                                                  .quantity,
                                                              keyboardType:
                                                                  const TextInputType
                                                                      .numberWithOptions(
                                                                      decimal:
                                                                          true),
                                                              decoration:
                                                                  const InputDecoration(
                                                                      labelText:
                                                                          'Qty',
                                                                      isDense:
                                                                          true))),
                                                      SizedBox(
                                                          width: detailWidth,
                                                          child: TextField(
                                                              controller: draft
                                                                  .price,
                                                              keyboardType:
                                                                  const TextInputType
                                                                      .numberWithOptions(
                                                                      decimal:
                                                                          true),
                                                              decoration:
                                                                  const InputDecoration(
                                                                      labelText:
                                                                          'Price',
                                                                      isDense:
                                                                          true))),
                                                      SizedBox(
                                                          width: detailWidth,
                                                          child: TextField(
                                                              controller: draft
                                                                  .discount,
                                                              keyboardType:
                                                                  const TextInputType
                                                                      .numberWithOptions(
                                                                      decimal:
                                                                          true),
                                                              decoration:
                                                                  const InputDecoration(
                                                                      labelText:
                                                                          'Discount',
                                                                      isDense:
                                                                          true))),
                                                      SizedBox(
                                                        width: 48,
                                                        child: IconButton(
                                                            onPressed: drafts
                                                                        .length ==
                                                                    1
                                                                ? null
                                                                : () =>
                                                                    setDialogState(
                                                                        () {
                                                                      drafts
                                                                          .removeAt(
                                                                              index)
                                                                          .dispose();
                                                                    }),
                                                            icon: const Icon(Icons
                                                                .delete_outline)),
                                                      ),
                                                    ]);
                                              }),
                                              TextField(
                                                  controller: draft.description,
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Line description',
                                                          isDense: true)),
                                            ])));
                                  }),
                              Row(children: [
                                TextButton.icon(
                                    onPressed: () => setDialogState(() =>
                                        drafts.add(_SaleOrderLineDraft(
                                            products.first))),
                                    icon: const Icon(Icons.add),
                                    label: const Text('Add line')),
                                const Spacer(),
                                Text(
                                    '${currency.symbol} ${_draftTotal(drafts, pricesIncludeTax).toStringAsFixed(2)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ]),
                              TextField(
                                  controller: notes,
                                  decoration: const InputDecoration(
                                      labelText: 'Notes')),
                            ]),
                          ),
                        ),
                      ),
                      actions: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel')),
                              const SizedBox(width: 12),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Save draft')),
                            ]),
                      ),
                    ),
                  ),
                )));
    if (ok != true) {
      for (final d in drafts) {
        d.dispose();
      }
      return;
    }
    // Trial/licence gate: new orders only; edits to existing stay allowed.
    if (existing == null && !await LicenseGate.canCreate(context)) {
      for (final d in drafts) {
        d.dispose();
      }
      return;
    }
    try {
      final orderId = existing?.id ?? const Uuid().v4();
      final orderNumber =
          existing?.orderNumber ?? await SaleOrderService.nextOrderNumber();
      final items = <SaleOrderItem>[];
      for (final draft in drafts) {
        final qty = double.tryParse(draft.quantity.text.trim()) ?? 0;
        final price = double.tryParse(draft.price.text.trim()) ?? 0;
        if (qty <= 0) throw StateError('Every line needs a positive quantity');
        final existingLine =
            existing != null && items.length < existing.items.length
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
          id: orderId,
          orderNumber: orderNumber,
          customerId: customer.id,
          customerName: customer.name,
          customerEmail: customer.email,
          customerPhone: customer.phone,
          customerAddress: customer.address,
          customerGstin: customer.gstin,
          date: date,
          expectedDate: expected,
          status: 'draft',
          currencyCode: currency.code,
          currencySymbol: currency.symbol,
          priceIncludesTax: pricesIncludeTax,
          notes: notes.text.trim(),
          items: items));
      await _load();
    } catch (e) {
      _error(e);
    } finally {
      for (final d in drafts) {
        d.dispose();
      }
    }
  }

  double _draftTotal(List<_SaleOrderLineDraft> drafts, bool pricesIncludeTax) =>
      drafts.fold(0, (sum, d) {
        final qty = double.tryParse(d.quantity.text) ?? 0;
        final price = double.tryParse(d.price.text) ?? 0;
        final discount = double.tryParse(d.discount.text) ?? 0;
        final gross = (qty * price - discount).clamp(0, double.infinity);
        if (pricesIncludeTax) return sum + gross;
        return sum + gross + gross * d.product.tax_rate / 100;
      });

  Widget _contextPanel(BuildContext context, String symbol, String customer,
      double balance, List<_SaleOrderLineDraft> drafts, SaleOrder? existing) {
    final fulfilled = existing?.items
            .fold<double>(0, (sum, item) => sum + item.fulfilledQuantity) ??
        0;
    final expected = drafts.fold<double>(
        0, (sum, item) => sum + (double.tryParse(item.quantity.text) ?? 0));
    final reserved =
        existing?.status == 'confirmed' || existing?.status == 'partial'
            ? (expected - fulfilled).clamp(0, double.infinity).toDouble()
            : 0.0;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _metric('Customer', customer),
              _metric('Currency', symbol),
              _metric('Expected qty', expected.toStringAsFixed(2)),
              _metric('Fulfilled', fulfilled.toStringAsFixed(2)),
              _metric('Reserved', reserved.toStringAsFixed(2)),
              _metric(
                  'Outstanding qty',
                  (expected - fulfilled)
                      .clamp(0, double.infinity)
                      .toStringAsFixed(2)),
              _metric('Conversion', 'Sales invoice'),
              _metric('Outstanding balance',
                  '$symbol ${balance.toStringAsFixed(2)}'),
              if (existing?.expectedDate != null)
                _metric(
                    'Due',
                    existing!.expectedDate!
                        .toLocal()
                        .toString()
                        .split(' ')
                        .first),
            ],
          )),
    );
  }

  Widget _metric(String label, String value) => SizedBox(
        width: 170,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  Future<void> _fulfill(SaleOrder order) async {
    final controllers = <String, TextEditingController>{
      for (final item in order.items)
        if (item.remainingQuantity > 0)
          item.id:
              TextEditingController(text: item.remainingQuantity.toString())
    };
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Fulfill ${order.orderNumber}'),
              content: SizedBox(
                  width: 560,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'An invoice will be created and stock deducted for these quantities.'),
                    const SizedBox(height: 12),
                    ...order.items.where((i) => i.remainingQuantity > 0).map(
                        (item) => ListTile(
                            title: Text(item.productName),
                            subtitle:
                                Text('Remaining ${item.remainingQuantity}'),
                            trailing: SizedBox(
                                width: 120,
                                child: TextField(
                                    controller: controllers[item.id],
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText: 'Invoice qty'))))),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Convert to Invoice')),
              ],
            ));
    if (ok != true) {
      for (final c in controllers.values) {
        c.dispose();
      }
      return;
    }
    try {
      final invoiceId = await SaleOrderService.fulfillToInvoice(order.id,
          quantitiesByItemId: {
            for (final e in controllers.entries)
              e.key: double.tryParse(e.value.text.trim()) ?? 0
          });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Invoice $invoiceId created from ${order.orderNumber}.'),
            backgroundColor: Colors.green));
      await _load();
    } catch (e) {
      _error(e);
    } finally {
      for (final c in controllers.values) {
        c.dispose();
      }
    }
  }

  Future<void> _act(SaleOrder order, String action) async {
    try {
      if (action == 'confirm') await SaleOrderService.confirm(order.id);
      if (action == 'cancel') await SaleOrderService.cancel(order.id);
      if (action == 'delete') await SaleOrderService.deleteDraft(order.id);
      if (action == 'fulfill') {
        await _fulfill(order);
        return;
      }
      if (action == 'edit') {
        await _openForm(order);
        return;
      }
      await _load();
    } catch (e) {
      _error(e);
    }
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('StateError: ', '')),
        backgroundColor: Colors.red));
  }

  static Color _statusColor(String status) => switch (status) {
        'fulfilled' => Colors.green,
        'confirmed' => Colors.blue,
        'partial' => Colors.deepOrange,
        'cancelled' => Colors.red,
        _ => Colors.orange,
      };

  String _dateLabel(DateTime? d) =>
      d == null ? 'Any date' : d.toLocal().toString().split(' ').first;

  String get _rangeLabel {
    if (_fromDate == null && _toDate == null) return 'Any date';
    return '${_dateLabel(_fromDate)} – ${_dateLabel(_toDate)}';
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: (_fromDate != null || _toDate != null)
          ? DateTimeRange(
              start: _fromDate ?? _toDate!,
              end: _toDate ?? _fromDate!,
            )
          : null,
    );
    if (picked == null) return;
    setState(() {
      _fromDate = picked.start;
      _toDate = picked.end;
      _page = 0;
    });
  }

  void _clearRange() => setState(() {
        _fromDate = null;
        _toDate = null;
        _page = 0;
      });

  int get _activeFilterCount =>
      (_status != null ? 1 : 0) +
      ((_fromDate != null || _toDate != null) ? 1 : 0);

  Future<void> _showFilterDialog() async {
    String? tempStatus = _status;
    DateTime? tempFrom = _fromDate;
    DateTime? tempTo = _toDate;
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(builder: (dialogContext, setDialogState) {
          String cap(String s) => '${s[0].toUpperCase()}${s.substring(1)}';
          Widget dateBox(String label, DateTime? value, bool isFrom) {
            return OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: dialogContext,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setDialogState(() {
                    if (isFrom) {
                      tempFrom = picked;
                    } else {
                      tempTo = picked;
                    }
                  });
                }
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(value == null
                  ? label
                  : value.toLocal().toString().split(' ').first),
            );
          }

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Filter Sale Orders'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Status',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('All'),
                        selected: tempStatus == null,
                        onSelected: (_) =>
                            setDialogState(() => tempStatus = null),
                      ),
                      for (final s in _statuses)
                        ChoiceChip(
                          label: Text(cap(s)),
                          selected: tempStatus == s,
                          onSelected: (_) =>
                              setDialogState(() => tempStatus = s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('Order date range',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: dateBox('From', tempFrom, true)),
                      const SizedBox(width: 12),
                      Expanded(child: dateBox('To', tempTo, false)),
                    ],
                  ),
                  if (tempFrom != null || tempTo != null) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => setDialogState(() {
                        tempFrom = null;
                        tempTo = null;
                      }),
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear dates'),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setDialogState(() {
                  tempStatus = null;
                  tempFrom = null;
                  tempTo = null;
                }),
                child: const Text('Reset'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  setState(() {
                    _status = tempStatus;
                    _fromDate = tempFrom;
                    _toDate = tempTo;
                    _page = 0;
                  });
                },
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  /// Reference-design header: title + live subtitle, primary Create on wide
  /// (narrow uses the FAB and the existing AppBar action). Labels unchanged.
  Widget _header(bool isWide, int total) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Sale Orders',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('$total sale orders',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        if (isWide)
          AppPrimaryButton(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Order'),
          ),
      ],
    );
  }

  /// Status filter chips with LIVE counts aggregated from the loaded rows.
  Widget _chips(Map<String, int> counts) {
    String cap(String s) => '${s[0].toUpperCase()}${s.substring(1)}';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _statusChip(null, 'All', counts['all'] ?? 0, Colors.grey),
        for (final s in _statuses)
          _statusChip(s, cap(s), counts[s] ?? 0, _statusColor(s)),
      ],
    );
  }

  Widget _statusChip(String? value, String label, int count, Color color) {
    final selected = _status == value;
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => setState(() {
        _status = value;
        _page = 0;
      }),
      selectedColor: color.withValues(alpha: 0.18),
      labelStyle: TextStyle(
        color: selected ? color.withValues(alpha: 0.95) : null,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  /// Reference filter row: search + date-range picker + Filter button.
  Widget _toolbar(bool isWide) {
    final searchField = TextField(
      controller: _searchController,
      decoration: InputDecoration(
        hintText: 'Search by order no. or customer…',
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        suffixIcon: _search.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _search = '';
                    _page = 0;
                  });
                },
              )
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              BorderSide(color: Theme.of(context).primaryColor, width: 2),
        ),
      ),
      onChanged: (v) => setState(() {
        _search = v;
        _page = 0;
      }),
    );
    final hasRange = _fromDate != null || _toDate != null;
    final rangeButton = hasRange
        ? InputChip(
            avatar: const Icon(Icons.calendar_today_outlined, size: 16),
            label:
                Text(_rangeLabel, overflow: TextOverflow.ellipsis, maxLines: 1),
            onPressed: _pickRange,
            onDeleted: _clearRange,
          )
        : AppSecondaryButton(
            onPressed: _pickRange,
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text(_rangeLabel),
          );
    final filterButton = Stack(
      clipBehavior: Clip.none,
      children: [
        AppSecondaryButton(
          onPressed: _showFilterDialog,
          icon: const Icon(Icons.filter_list, size: 18),
          label: const Text('Filter'),
        ),
        if (_activeFilterCount > 0)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                shape: BoxShape.circle,
              ),
              child: Text('$_activeFilterCount',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
    if (isWide) {
      return Row(
        children: [
          Expanded(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: searchField)),
          const SizedBox(width: 12),
          rangeButton,
          const SizedBox(width: 8),
          filterButton,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        searchField,
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [rangeButton, filterButton],
        ),
      ],
    );
  }

  Widget _sortHead(String label, String field, TextStyle style) {
    final active = _sortField == field;
    return InkWell(
      onTap: () => _changeSort(field),
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label, overflow: TextOverflow.ellipsis, style: style),
          ),
          const SizedBox(width: 2),
          Icon(
            !active
                ? Icons.unfold_more
                : (_sortAsc ? Icons.arrow_upward : Icons.arrow_downward),
            size: 14,
            color: active ? Colors.white : Colors.white70,
          ),
        ],
      ),
    );
  }

  Widget _ordersTable(List<SaleOrder> items) {
    const headerStyle = TextStyle(
        color: Colors.white,
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: _sortHead('Order', 'number', headerStyle),
                  ),
                ),
                SizedBox(
                    width: 110, child: _sortHead('Date', 'date', headerStyle)),
                Expanded(
                  flex: 2,
                  child: _sortHead('Customer', 'customer', headerStyle),
                ),
                const SizedBox(
                    width: 64, child: Text('Items', style: headerStyle)),
                Expanded(child: _sortHead('Total', 'total', headerStyle)),
                const SizedBox(
                    width: 110, child: Text('Status', style: headerStyle)),
                const SizedBox(
                  width: 56,
                  child: Icon(Icons.more_vert, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          ...items.asMap().entries.map((e) => _orderRow(e.value, e.key.isEven)),
        ],
      ),
    );
  }

  Widget _orderRow(SaleOrder order, bool isEven) {
    final color = _statusColor(order.status);
    return Container(
      decoration: BoxDecoration(
        color: isEven
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Theme.of(context).colorScheme.surfaceContainer,
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(order.orderNumber,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700)),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(order.date.toLocal().toString().split(' ').first,
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            flex: 2,
            child: Text(order.customerName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          SizedBox(
            width: 64,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('${order.items.length}',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[700])),
              ),
            ),
          ),
          Expanded(
            child: AppMoney(
              order.displayTotal,
              currencySymbol: order.currencySymbol,
              bold: true,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          SizedBox(
            width: 110,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _statusPill(order.status, color),
            ),
          ),
          SizedBox(width: 56, child: _orderMenu(order)),
        ],
      ),
    );
  }

  Widget _statusPill(String status, Color color) {
    final label = '${status[0].toUpperCase()}${status.substring(1)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  /// Row overflow menu — the exact same actions the list rows always had.
  Widget _orderMenu(SaleOrder order) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: 'More actions',
      padding: EdgeInsets.zero,
      onSelected: (v) => _act(order, v),
      itemBuilder: (_) => [
        if (order.status == 'draft')
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (order.status == 'draft')
          const PopupMenuItem(
              value: 'confirm', child: Text('Confirm & reserve')),
        if (order.status == 'confirmed' || order.status == 'partial')
          const PopupMenuItem(
              value: 'fulfill', child: Text('Convert to Invoice')),
        if (order.status != 'fulfilled' && order.status != 'cancelled')
          const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
        if (order.status == 'draft' || order.status == 'cancelled')
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  Widget _footer(
      int start, int end, int total, int pages, int safePage, bool isWide) {
    final left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Showing $start–$end of $total',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 16),
        const Text('Rows per page:', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: _pageSize,
          underline: const SizedBox(),
          items: [10, 25, 50]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
              .toList(),
          onChanged: (n) {
            if (n == null) return;
            setState(() {
              _pageSize = n;
              _page = 0;
            });
          },
        ),
      ],
    );
    final right = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed:
              safePage > 0 ? () => setState(() => _page = safePage - 1) : null,
          icon: const Icon(Icons.chevron_left, size: 18),
          label: const Text('Previous'),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.3)),
          ),
          child: Text('Page ${safePage + 1} of ${pages > 0 ? pages : 1}',
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).primaryColor)),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: (safePage + 1 < pages)
              ? () => setState(() => _page = safePage + 1)
              : null,
          icon: const Icon(Icons.chevron_right, size: 18),
          label: const Text('Next'),
        ),
      ],
    );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      child: isWide
          ? Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [left, right])
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [left, right],
            ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1000;
        final useCards = constraints.maxWidth < 700;
        final counts = _statusCounts;
        final visible = _visibleOrders;
        final total = visible.length;
        final pages = (total / _pageSize).ceil();
        final safePage = pages == 0 ? 0 : _page.clamp(0, pages - 1);
        final items = total == 0
            ? const <SaleOrder>[]
            : visible.sublist(safePage * _pageSize,
                (safePage * _pageSize + _pageSize).clamp(0, total));
        final start = total == 0 ? 0 : safePage * _pageSize + 1;
        final end = total == 0 ? 0 : safePage * _pageSize + items.length;
        return Scaffold(
          appBar: AppBar(title: const Text('Sale Orders'), actions: [
            FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New Order')),
            const SizedBox(width: 8),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
            const SizedBox(width: 8),
          ]),
          floatingActionButton: useCards
              ? FloatingActionButton(
                  onPressed: () => _openForm(),
                  tooltip: 'New Order',
                  child: const Icon(Icons.add),
                )
              : null,
          body: Column(children: [
            Container(
              color: Theme.of(context).colorScheme.surfaceContainer,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(isWide, total),
                  const SizedBox(height: 12),
                  _chips(counts),
                  const SizedBox(height: 12),
                  _toolbar(isWide),
                ],
              ),
            ),
            Expanded(
                child: _loading
                    ? const AppLoadingState()
                    : visible.isEmpty
                        ? AppEmptyState(
                            icon: Icons.shopping_bag_outlined,
                            title: 'No sale orders in this view.',
                            subtitle: _status == null &&
                                    _search.trim().isEmpty &&
                                    _fromDate == null &&
                                    _toDate == null
                                ? 'Create your first sale order to get started.'
                                : 'Try a different search or status filter, or create a new order.',
                            action: AppPrimaryButton(
                              onPressed: () => _openForm(),
                              icon: const Icon(Icons.add),
                              label: const Text('New Sale Order'),
                            ),
                          )
                        : useCards
                            ? ListView.separated(
                                padding: const EdgeInsets.all(16),
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) =>
                                    _card(items[index]),
                              )
                            : SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: _ordersTable(items),
                              )),
            if (!_loading && visible.isNotEmpty)
              _footer(start, end, total, pages, safePage, isWide),
          ]),
        );
      });

  /// Compact-phone card in the reference style: number + amount + overflow
  /// menu, party + status pill, then date + item count. Every row action
  /// stays available in the overflow menu.
  Widget _card(SaleOrder order) {
    final color = _statusColor(order.status);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(order.orderNumber,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w700)),
              ),
              AppMoney(
                order.displayTotal,
                currencySymbol: order.currencySymbol,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              _orderMenu(order),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(order.customerName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              _statusPill(order.status, color),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${order.date.toLocal().toString().split(' ').first} • '
            '${order.items.length} item(s)',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SaleOrderLineDraft {
  Product product;
  final TextEditingController quantity;
  final TextEditingController price;
  final TextEditingController discount;
  final TextEditingController description;

  _SaleOrderLineDraft(this.product,
      {double quantity = 1,
      double? price,
      double discount = 0,
      String description = ''})
      : quantity = TextEditingController(text: quantity.toString()),
        price = TextEditingController(
            text: (price ?? product.price).toStringAsFixed(2)),
        discount = TextEditingController(text: discount.toStringAsFixed(2)),
        description = TextEditingController(text: description);

  void dispose() {
    quantity.dispose();
    price.dispose();
    discount.dispose();
    description.dispose();
  }
}
