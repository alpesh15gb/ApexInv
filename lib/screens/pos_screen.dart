import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';

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
import 'package:apexbooks/sync/sync_controller.dart';
import 'package:apexbooks/sync/sync_engine.dart';

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
  final _customerSearch = TextEditingController();
  final _searchFocus = FocusNode();
  final List<_HeldCart> _heldCarts = [];
  final Set<String> _favourites = {};
  final List<String> _recentProductIds = [];
  Customer? _customer;
  String _currencyCode = 'INR';
  String _currencySymbol = '₹';
  // Cart-level GST interpretation: true → typed prices include GST.
  // Applies to every cart line, existing and subsequently added.
  bool _pricesIncludeTax = false;
  bool _loading = true;
  bool _saving = false;
  DateTime? _stockLoadedAt;

  Customer get _walkIn => Customer(
      id: 'walk-in',
      name: 'Walk-in Customer',
      email: '',
      phone: '',
      address: '',
      gstin: '');

  @override
  void initState() {
    super.initState();
    _load();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _customerSearch.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      ProductService.getAllProducts(),
      CustomerService.getAllCustomers(),
      AccountingService.getAccounts(),
      SaleOrderService.getReservedQuantities(),
      SettingsService.getCurrency(),
      SettingsService.getDefaultPriceIncludesTax(),
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
      _pricesIncludeTax = results[5] as bool;
      _customer ??= _walkIn;
      _loading = false;
      _stockLoadedAt = DateTime.now();
    });
  }

  List<Product> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _products;
    return _products
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.barcode.toLowerCase().contains(q))
        .toList();
  }

  double _available(Product product) => product.unlimitedStock
      ? double.infinity
      : (product.stock.toDouble() - (_reserved[product.id] ?? 0))
          .clamp(0, double.infinity)
          .toDouble();

  void _setPricesIncludeTax(bool value) {
    if (_pricesIncludeTax == value) return;
    setState(() {
      _pricesIncludeTax = value;
      for (final item in _cart.values) {
        if (item.product.priceIncludesTax != value) {
          item.product = item.product.withPriceIncludesTax(value);
        }
      }
    });
  }

  void _add(Product product) {
    final existing = _cart[product.id];
    final next = (existing?.quantity ?? 0) + 1;
    if (!product.unlimitedStock && next > _available(product) + 0.000001) {
      _error('No unreserved stock available for ${product.name}.');
      return;
    }
    // Newly added lines follow the cart-level GST toggle; the copy keeps
    // the catalog instance untouched.
    final lineProduct = existing?.product ??
        (product.priceIncludesTax == _pricesIncludeTax
            ? product
            : product.withPriceIncludesTax(_pricesIncludeTax));
    setState(() {
      _cart[product.id] = InvoiceItem(
          id: existing?.id,
          product: lineProduct,
          quantity: next,
          discount: existing?.discount ?? product.defaultDiscount,
          unitPrice: existing?.unitPrice);
      _recentProductIds.remove(product.id);
      _recentProductIds.insert(0, product.id);
      if (_recentProductIds.length > 8) _recentProductIds.removeLast();
    });
  }

  void _clearCart() => setState(() {
        _cart.clear();
        _customer = _walkIn;
      });

  void _holdCart() {
    if (_cart.isEmpty) {
      _error('Add an item before holding a cart.');
      return;
    }
    setState(() {
      _heldCarts.insert(
          0,
          _HeldCart(
              items: Map<String, InvoiceItem>.from(_cart),
              customer: _customer ?? _walkIn,
              heldAt: DateTime.now()));
      _cart.clear();
      _customer = _walkIn;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Cart held')));
  }

  void _resumeCart(int index) {
    final held = _heldCarts[index];
    if (_cart.isNotEmpty) {
      _error('Hold or clear the current cart before resuming another.');
      return;
    }
    setState(() {
      _cart.addAll(held.items);
      _customer = held.customer;
      _heldCarts.removeAt(index);
    });
    Navigator.pop(context);
  }

  void _scanSubmitted(String value) {
    final query = value.trim().toLowerCase();
    if (query.isEmpty) return;
    Product? match;
    for (final product in _products) {
      if (product.barcode.trim().toLowerCase() == query ||
          product.name.trim().toLowerCase() == query) {
        match = product;
        break;
      }
    }
    if (match == null) {
      _error('No exact barcode or product name match.');
      return;
    }
    _add(match);
    _search.clear();
  }

  void _showHeldCarts() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 360,
          child: _heldCarts.isEmpty
              ? const Center(child: Text('No held carts'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _heldCarts.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    final held = _heldCarts[index];
                    final count = held.items.values.fold<int>(
                        0, (sum, item) => sum + item.quantity.round());
                    return ListTile(
                      leading: const Icon(Icons.pause_circle_outline),
                      title: Text('${held.customer.name}  -  $count items'),
                      subtitle: Text('Held ${_timeLabel(held.heldAt)}'),
                      trailing: FilledButton(
                          onPressed: () => _resumeCart(index),
                          child: const Text('Resume')),
                    );
                  },
                ),
        ),
      ),
    );
  }

  String _timeLabel(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  List<Product> _recentProducts() => _recentProductIds
      .map((id) => _products.where((product) => product.id == id))
      .where((matches) => matches.isNotEmpty)
      .map((matches) => matches.first)
      .toList();

  List<Product> _favouriteProducts() =>
      _products.where((product) => _favourites.contains(product.id)).toList();

  String _syncLabel() {
    try {
      final controller = SyncController.instance;
      final status = controller.status;
      if (!controller.isLinked) return 'Sync not linked';
      if (status.cycle == SyncCycleStatus.error) return 'Sync error';
      if (status.cycle == SyncCycleStatus.syncing) return 'Syncing';
      if (status.lastSyncAt != null) {
        return 'Synced ${_timeLabel(status.lastSyncAt!.toLocal())}';
      }
      return 'Sync linked';
    } catch (_) {
      return 'Local mode';
    }
  }

  Future<void> _quickAddCustomer() async {
    final name = TextEditingController(text: _customerSearch.text.trim());
    final phone = TextEditingController();
    final result = await showDialog<({String name, String phone})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quick add customer'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: phone,
              decoration: const InputDecoration(labelText: 'Phone')),
          const SizedBox(height: 8),
          const Text('The customer is saved and available for future payments.',
              style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(context,
                    (name: name.text.trim(), phone: phone.text.trim()));
              },
              child: const Text('Save customer')),
        ],
      ),
    );
    name.dispose();
    phone.dispose();
    if (result == null || !mounted) return;
    try {
      final existing = await CustomerService.findByPhone(result.phone);
      final customer = existing ??
          Customer(
              id: const Uuid().v4(),
              name: result.name,
              email: '',
              phone: result.phone,
              address: '',
              gstin: '');
      if (existing == null) await CustomerService.insertCustomer(customer);
      if (!mounted) return;
      setState(() {
        if (existing == null) _customers = [..._customers, customer];
        _customer = customer;
      });
    } catch (e) {
      _error('Could not save customer: $e');
      return;
    }
    _customerSearch.clear();
  }

  void _changeQty(Product product, double delta) {
    final existing = _cart[product.id];
    if (existing == null) return;
    final next = existing.quantity + delta;
    if (next <= 0) {
      setState(() => _cart.remove(product.id));
      return;
    }
    if (!product.unlimitedStock && next > _available(product) + 0.000001) {
      _error('Only ${_available(product)} unreserved units are available.');
      return;
    }
    setState(() => _cart[product.id] = InvoiceItem(
        id: existing.id,
        product: product,
        quantity: next,
        discount: existing.discount,
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
  int get _itemCount =>
      _cart.values.fold(0, (count, item) => count + item.quantity.round());

  Future<void> _checkout() async {
    if (_cart.isEmpty || _saving) return;
    if (_accounts.isEmpty) {
      _error('Create a cash or bank account first.');
      return;
    }
    final tenders = <_TenderDraft>[_TenderDraft('Cash', _total, _accounts)];
    String? tenderError;
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
                  title: const Text('Complete sale'),
                  content: SizedBox(
                      width: 680,
                      height: 480,
                      child: Column(children: [
                        Row(children: [
                          const Text('Review payment',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const Spacer(),
                          Text('$_currencySymbol ${_total.toStringAsFixed(2)}',
                              style: Theme.of(context).textTheme.titleLarge),
                        ]),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Sale total',
                                style: Theme.of(context).textTheme.bodySmall)),
                        const SizedBox(height: 8),
                        Expanded(
                            child: ListView.builder(
                                itemCount: tenders.length,
                                itemBuilder: (context, index) {
                                  final tender = tenders[index];
                                  final accountChoices = _accounts
                                      .where((a) => tender.method == 'Cash'
                                          ? a.type == 'cash'
                                          : a.type == 'bank')
                                      .toList();
                                  if (accountChoices.isNotEmpty &&
                                      !accountChoices.any(
                                          (a) => a.id == tender.accountId)) {
                                    tender.accountId = accountChoices.first.id;
                                  }
                                  return Card(
                                      child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Column(children: [
                                            Row(children: [
                                              Expanded(
                                                  child: DropdownButtonFormField<
                                                          String>(
                                                      value: tender.method,
                                                      decoration:
                                                          const InputDecoration(
                                                              labelText:
                                                                  'Method',
                                                              isDense: true),
                                                      items: const [
                                                        'Cash',
                                                        'Bank Transfer',
                                                        'Online',
                                                        'Check'
                                                      ]
                                                          .map((m) =>
                                                              DropdownMenuItem(
                                                                  value: m,
                                                                  child:
                                                                      Text(m)))
                                                          .toList(),
                                                      onChanged: (v) =>
                                                          setDialogState(() =>
                                                              tender.method =
                                                                  v!))),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                  child: TextField(
                                                      controller: tender.amount,
                                                      onChanged: (_) =>
                                                          setDialogState(() {}),
                                                      keyboardType:
                                                          const TextInputType
                                                              .numberWithOptions(
                                                              decimal: true),
                                                      decoration:
                                                          const InputDecoration(
                                                              labelText:
                                                                  'Amount',
                                                              isDense: true))),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                  child: DropdownButtonFormField<
                                                          String>(
                                                      value: tender.accountId,
                                                      decoration:
                                                          const InputDecoration(
                                                              labelText:
                                                                  'Account',
                                                              isDense: true),
                                                      items: accountChoices
                                                          .map((a) =>
                                                              DropdownMenuItem(
                                                                  value: a.id,
                                                                  child: Text(
                                                                      a.name)))
                                                          .toList(),
                                                      onChanged: (v) => tender
                                                          .accountId = v)),
                                              IconButton(
                                                  onPressed: tenders.length == 1
                                                      ? null
                                                      : () =>
                                                          setDialogState(() {
                                                            tenders
                                                                .removeAt(index)
                                                                .dispose();
                                                          }),
                                                  icon: const Icon(
                                                      Icons.delete_outline)),
                                            ]),
                                            if (tender.method == 'Check')
                                              Row(children: [
                                                Expanded(
                                                    child: TextField(
                                                        controller:
                                                            tender.chequeNumber,
                                                        decoration:
                                                            const InputDecoration(
                                                                labelText:
                                                                    'Cheque number'))),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                    child: ListTile(
                                                        contentPadding:
                                                            EdgeInsets.zero,
                                                        title: const Text(
                                                            'Cheque date'),
                                                        subtitle: Text(tender
                                                            .chequeDate
                                                            .toLocal()
                                                            .toString()
                                                            .split(' ')
                                                            .first),
                                                        onTap: () async {
                                                          final picked = await showDatePicker(
                                                              context: ctx,
                                                              initialDate: tender
                                                                  .chequeDate,
                                                              firstDate:
                                                                  DateTime(
                                                                      2000),
                                                              lastDate: DateTime
                                                                      .now()
                                                                  .add(const Duration(
                                                                      days:
                                                                          730)));
                                                          if (picked != null)
                                                            setDialogState(() =>
                                                                tender.chequeDate =
                                                                    picked);
                                                        })),
                                              ]),
                                          ])));
                                })),
                        Row(children: [
                          TextButton.icon(
                              onPressed: () => setDialogState(() => tenders.add(
                                  _TenderDraft('Bank Transfer', 0, _accounts))),
                              icon: const Icon(Icons.add),
                              label: const Text('Split tender')),
                          const Spacer(),
                          Text(
                              'Tendered $_currencySymbol ${tenders.fold(0.0, (s, t) => s + (double.tryParse(t.amount.text) ?? 0)).toStringAsFixed(2)}'),
                        ]),
                        Builder(builder: (context) {
                          final paid = tenders.fold<double>(
                              0,
                              (sum, tender) =>
                                  sum +
                                  (double.tryParse(tender.amount.text) ?? 0));
                          final balance = _total - paid;
                          final walkIn = _customer?.id == 'walk-in';
                          final valid = paid > 0 &&
                              balance >= -0.005 &&
                              (!walkIn || balance <= 0.005) &&
                              tenders
                                  .every((tender) => tender.accountId != null);
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            color: valid
                                ? Colors.green.withValues(alpha: .08)
                                : Colors.orange.withValues(alpha: .10),
                            child: Row(children: [
                              Icon(
                                  valid
                                      ? Icons.check_circle_outline
                                      : Icons.info_outline,
                                  color: valid ? Colors.green : Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(valid
                                      ? balance > 0.005
                                          ? 'Part payment. The remaining balance will stay on the account.'
                                          : 'Payment covers the sale. Ready to post.'
                                      : balance > 0.005
                                          ? walkIn
                                              ? 'Walk-in sales must be paid in full.'
                                              : 'Remaining balance: $_currencySymbol ${balance.toStringAsFixed(2)}'
                                          : 'Check tender amounts and account selection.')),
                            ]),
                          );
                        }),
                        if (tenderError != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(tenderError!,
                                style: TextStyle(
                                    color: Theme.of(ctx).colorScheme.error,
                                    fontSize: 12)),
                          ),
                        TextField(
                            controller: notes,
                            decoration: const InputDecoration(
                                labelText: 'Receipt notes')),
                        if (_customer?.id == 'walk-in')
                          const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('Walk-in sales must be fully paid.',
                                  style: TextStyle(color: Colors.orange))),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () {
                          final paid = tenders.fold<double>(
                              0,
                              (sum, tender) =>
                                  sum +
                                  (double.tryParse(tender.amount.text) ?? 0));
                          final error = paid <= 0
                              ? 'Enter a tender amount.'
                              : paid > _total + 0.005
                                  ? 'Tendered amount cannot exceed the sale total.'
                                  : (_customer?.id == 'walk-in' &&
                                          paid < _total - 0.005)
                                      ? 'Walk-in sales must be fully paid.'
                                      : tenders.any((tender) =>
                                              tender.accountId == null)
                                          ? 'Select an account for every tender.'
                                          : null;
                          if (error != null) {
                            setDialogState(() => tenderError = error);
                            return;
                          }
                          Navigator.pop(ctx, true);
                        },
                        child: const Text('Finalize & post')),
                  ],
                )));
    if (ok != true) {
      for (final t in tenders) {
        t.dispose();
      }
      notes.dispose();
      return;
    }
    setState(() => _saving = true);
    try {
      final invoice = await PosService.finalize(
          customer: _customer ?? _walkIn,
          items: _cart.values.toList(),
          tenders: tenders
              .map((t) => PosTender(
                  method: t.method,
                  amount: double.tryParse(t.amount.text.trim()) ?? 0,
                  accountId: t.accountId,
                  chequeNumber:
                      t.method == 'Check' ? t.chequeNumber.text.trim() : null,
                  chequeDate: t.method == 'Check' ? t.chequeDate : null))
              .toList(),
          currencyCode: _currencyCode,
          currencySymbol: _currencySymbol,
          notes: notes.text.trim());
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _customer = _walkIn;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Sale ${invoice.invoiceNumber} posted successfully.'),
          backgroundColor: Colors.green));
      await _load();
    } catch (e) {
      _error(e);
    } finally {
      for (final t in tenders) {
        t.dispose();
      }
      notes.dispose();
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
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f2): () =>
              _searchFocus.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.keyH, control: true):
              _holdCart,
          const SingleActivator(LogicalKeyboardKey.keyL, control: true):
              _clearCart,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(title: const Text('POS'), actions: [
              if (_heldCarts.isNotEmpty)
                Badge(
                    label: Text('${_heldCarts.length}'),
                    child: IconButton(
                        tooltip: 'Held carts',
                        onPressed: _showHeldCarts,
                        icon: const Icon(Icons.pause_circle_outline))),
              IconButton(
                  tooltip: 'Refresh stock',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh)),
              if (_cart.isNotEmpty)
                TextButton.icon(
                    onPressed: _clearCart,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Clear cart')),
              const SizedBox(width: 8),
            ]),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, constraints) {
                    final products = _productPane();
                    final cart = _cartPane();
                    if (constraints.maxWidth < 850)
                      return Column(children: [
                        Expanded(flex: 3, child: products),
                        const Divider(height: 1),
                        Expanded(flex: 2, child: cart)
                      ]);
                    return Row(children: [
                      Expanded(flex: 3, child: products),
                      const VerticalDivider(width: 1),
                      SizedBox(width: 410, child: cart)
                    ]);
                  }),
          ),
        ),
      );

  Widget _productPane() => Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onSubmitted: _scanSubmitted,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search name or barcode',
                    helperText:
                        'Enter scans an exact barcode or product name. F2 focuses here.',
                    border: OutlineInputBorder()))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Icon(Icons.inventory_2_outlined,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(_stockLoadedAt == null
                      ? 'Stock snapshot loading'
                      : 'Stock checked ${_timeLabel(_stockLoadedAt!.toLocal())}')),
              Icon(Icons.cloud_outlined, size: 18),
              const SizedBox(width: 4),
              Text(_syncLabel()),
            ])),
        const SizedBox(height: 8),
        Expanded(
            child: _filtered.isEmpty
                ? const Center(child: Text('No products found'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      children: [
                        if (_search.text.trim().isEmpty &&
                            _favouriteProducts().isNotEmpty)
                          _productSection('Favourites', _favouriteProducts()),
                        if (_search.text.trim().isEmpty &&
                            _recentProducts().isNotEmpty)
                          _productSection('Recent', _recentProducts()),
                        _productSection(
                            _search.text.trim().isEmpty
                                ? 'All products'
                                : 'Results',
                            _filtered),
                      ],
                    ))),
      ]);

  Widget _productSection(String title, List<Product> products) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child:
                  Text(title, style: Theme.of(context).textTheme.titleSmall)),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 230,
                childAspectRatio: 1.6,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10),
            itemCount: products.length,
            itemBuilder: (context, index) {
              final product = products[index];
              final available = _available(product);
              final canAdd = product.unlimitedStock || available > 0;
              return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: canAdd ? () => _add(product) : null,
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(
                                    child: Text(product.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold))),
                                IconButton(
                                    tooltip: _favourites.contains(product.id)
                                        ? 'Remove from favourites'
                                        : 'Add to favourites',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                        minWidth: 44, minHeight: 44),
                                    onPressed: () => setState(() {
                                          if (!_favourites.add(product.id))
                                            _favourites.remove(product.id);
                                        }),
                                    icon: Icon(
                                        _favourites.contains(product.id)
                                            ? Icons.star
                                            : Icons.star_border,
                                        size: 20)),
                              ]),
                              const Spacer(),
                              Text(
                                  '$_currencySymbol ${product.price.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              Text(
                                  product.unlimitedStock
                                      ? 'Service / unlimited'
                                      : '${available.toStringAsFixed(2)} available',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          available <= 0 ? Colors.red : null)),
                            ])),
                  ));
            },
          ),
        ],
      );

  Widget _cartPane() => Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(children: [
              Text('Current sale',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              OutlinedButton.icon(
                  onPressed: _cart.isEmpty ? null : _holdCart,
                  icon: const Icon(Icons.pause, size: 18),
                  label: const Text('Hold')),
              const SizedBox(width: 8),
              if (_cart.isNotEmpty)
                Chip(
                    label:
                        Text('$_itemCount item${_itemCount == 1 ? '' : 's'}')),
            ])),
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: TextField(
              controller: _customerSearch,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: 'Find customer',
                  prefixIcon: const Icon(Icons.person_search_outlined),
                  suffixIcon: IconButton(
                      tooltip: 'Quick add customer',
                      onPressed: _quickAddCustomer,
                      icon: const Icon(Icons.person_add_alt_1))),
              onSubmitted: (_) {
                final matches = _customerMatches;
                if (matches.length == 1)
                  setState(() => _customer = matches.first);
              },
            )),
        if (_customerSearch.text.trim().isNotEmpty)
          ..._customerMatches.take(4).map((customer) => ListTile(
                dense: true,
                leading: const Icon(Icons.person_outline),
                title: Text(customer.name),
                subtitle: Text(
                    customer.phone.isEmpty ? 'Saved customer' : customer.phone),
                onTap: () => setState(() {
                  _customer = customer;
                  _customerSearch.clear();
                }),
              )),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<String>(
                value: _customer?.id ?? 'walk-in',
                decoration: const InputDecoration(
                    labelText: 'Selected customer',
                    border: OutlineInputBorder()),
                items: [_walkIn, ..._customers]
                    .map((c) =>
                        DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: (id) => setState(() => _customer = id == 'walk-in'
                    ? _walkIn
                    : _customers.firstWhere((c) => c.id == id)))),
        const Divider(height: 1),
        Expanded(
            child: _cart.isEmpty
                ? const Center(child: Text('Tap a product to add it'))
                : ListView.separated(
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = _cart.values.elementAt(index);
                      return ListTile(
                          title: Text(item.product.name),
                          subtitle: Text(
                              '${item.quantity} × $_currencySymbol ${(item.unitPrice ?? item.product.price).toStringAsFixed(2)}'),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                onPressed: () => _changeQty(item.product, -1),
                                icon: const Icon(Icons.remove_circle_outline)),
                            Text(
                                item.quantity.toStringAsFixed(
                                    item.quantity % 1 == 0 ? 0 : 2),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                onPressed: () => _changeQty(item.product, 1),
                                icon: const Icon(Icons.add_circle_outline)),
                            IconButton(
                                tooltip: 'Remove item',
                                onPressed: () => setState(
                                    () => _cart.remove(item.product.id)),
                                icon: const Icon(Icons.close)),
                          ]));
                    })),
        const Divider(height: 1),
        Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(value: false, label: Text('Excl GST')),
                  ButtonSegment<bool>(value: true, label: Text('Incl GST')),
                ],
                selected: {_pricesIncludeTax},
                onSelectionChanged: (selection) =>
                    _setPricesIncludeTax(selection.first),
              ),
              const SizedBox(height: 8),
              _summary('Subtotal', _subtotal),
              _summary('Tax', _tax),
              const Divider(),
              _summary('Total', _total, bold: true),
              const SizedBox(height: 12),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                      onPressed: _cart.isEmpty || _saving ? null : _checkout,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.point_of_sale),
                      label: Text(_saving ? 'Posting…' : 'Checkout'))),
            ])),
      ]);

  List<Customer> get _customerMatches {
    final query = _customerSearch.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return _customers
        .where((customer) =>
            customer.name.toLowerCase().contains(query) ||
            customer.phone.toLowerCase().contains(query) ||
            customer.email.toLowerCase().contains(query))
        .toList();
  }

  Widget _summary(String label, double amount, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Text(label,
            style: bold
                ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)
                : null),
        const Spacer(),
        Text('$_currencySymbol ${amount.toStringAsFixed(2)}',
            style: bold
                ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)
                : null),
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
      if (account.type == wanted) {
        accountId = account.id;
        break;
      }
    }
  }

  void dispose() {
    amount.dispose();
    chequeNumber.dispose();
  }
}

class _HeldCart {
  final Map<String, InvoiceItem> items;
  final Customer customer;
  final DateTime heldAt;

  const _HeldCart({
    required this.items,
    required this.customer,
    required this.heldAt,
  });
}
