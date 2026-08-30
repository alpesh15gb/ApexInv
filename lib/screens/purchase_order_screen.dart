import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:apexbooks/database/purchase_order_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/models/purchase_order.dart';
import 'package:apexbooks/models/product.dart';

class PurchaseOrderScreen extends ConsumerStatefulWidget {
  const PurchaseOrderScreen({super.key});

  @override
  ConsumerState<PurchaseOrderScreen> createState() => _PurchaseOrderScreenState();
}

class _PurchaseOrderScreenState extends ConsumerState<PurchaseOrderScreen> {
  List<PurchaseOrder> _orders = [];
  bool _isLoading = true;
  String? _filterStatus;
  int _currentPage = 0;
  final int _pageSize = 20;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final orders = await PurchaseOrderService.getPurchaseOrdersPaginated(
      page: _currentPage,
      pageSize: _pageSize,
      status: _filterStatus,
    );
    final count = await PurchaseOrderService.getPurchaseOrderCount(status: _filterStatus);
    if (mounted) {
      setState(() {
        _orders = orders;
        _totalCount = count;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Purchase Orders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showCreateOrderDialog(),
            tooltip: 'Create Purchase Order',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('All', null),
                _buildFilterChip('Draft', 'draft'),
                _buildFilterChip('Confirmed', 'confirmed'),
                _buildFilterChip('Received', 'received'),
              ],
            ),
          ),

          // Order list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _orders.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.shopping_cart_outlined, size: 64, color: colorScheme.outlineVariant),
                            const SizedBox(height: 16),
                            Text(
                              'No purchase orders found',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.tonal(
                              onPressed: () => _showCreateOrderDialog(),
                              child: const Text('Create First Order'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _orders.length,
                        itemBuilder: (context, index) {
                          final order = _orders[index];
                          return _buildOrderCard(order);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String? status) {
    final isSelected = _filterStatus == status;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() => _filterStatus = status);
        _currentPage = 0;
        _loadData();
      },
    );
  }

  Widget _buildOrderCard(PurchaseOrder order) {
    final colorScheme = Theme.of(context).colorScheme;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    Color statusColor;
    IconData statusIcon;
    switch (order.status) {
      case 'confirmed':
        statusColor = Colors.blue;
        statusIcon = Icons.check_circle;
        break;
      case 'received':
        statusColor = Colors.green;
        statusIcon = Icons.done_all;
        break;
      case 'cancelled':
        statusColor = Colors.red;
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = Colors.orange;
        statusIcon = Icons.edit_note;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showOrderDetail(order),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 400;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'PO #${order.orderNumber ?? order.id}',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              order.vendorName,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, size: 14, color: statusColor),
                            const SizedBox(width: 4),
                            Text(
                              order.status[0].toUpperCase() + order.status.substring(1),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (isWide)
                    Row(
                      children: [
                        _buildInfoChip(Icons.calendar_today, DateFormat('dd MMM yyyy').format(order.date)),
                        const SizedBox(width: 12),
                        _buildInfoChip(Icons.inventory_2, '${order.items.length} items'),
                        const Spacer(),
                        Text(
                          currencyFormat.format(order.totalAmount),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            _buildInfoChip(Icons.calendar_today, DateFormat('dd MMM yyyy').format(order.date)),
                            _buildInfoChip(Icons.inventory_2, '${order.items.length} items'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          currencyFormat.format(order.totalAmount),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  if (order.outstandingBalance > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                        const SizedBox(width: 4),
                        Text(
                          'Outstanding: ${currencyFormat.format(order.outstandingBalance)}',
                          style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  void _showCreateOrderDialog() {
    _showOrderDialog();
  }

  Future<void> _showOrderDialog({PurchaseOrder? existingOrder}) async {
    final vendorController = TextEditingController(text: existingOrder?.vendorName ?? '');
    final notesController = TextEditingController(text: existingOrder?.notes ?? '');
    DateTime orderDate = existingOrder?.date ?? DateTime.now();
    DateTime? expectedDate = existingOrder?.expectedDate;
    String status = existingOrder?.status ?? 'draft';

    List<PurchaseOrderItem> items = List.from(existingOrder?.items ?? []);

    // Load products for selection
    final products = await ProductService.getAllProducts();

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existingOrder == null ? 'Create Purchase Order' : 'Edit Purchase Order'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: vendorController,
                  decoration: const InputDecoration(
                    labelText: 'Vendor Name *',
                    hintText: 'e.g. ABC Suppliers',
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Order Date'),
                  subtitle: Text(DateFormat('dd MMM yyyy').format(orderDate)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: orderDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setDialogState(() => orderDate = picked);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expected Date (optional)'),
                  subtitle: Text(expectedDate != null
                      ? DateFormat('dd MMM yyyy').format(expectedDate!)
                      : 'Not set'),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: expectedDate ?? DateTime.now().add(const Duration(days: 7)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setDialogState(() => expectedDate = picked);
                  },
                ),
                if (existingOrder != null) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: const [
                      DropdownMenuItem(value: 'draft', child: Text('Draft')),
                      DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
                      DropdownMenuItem(value: 'received', child: Text('Received')),
                      DropdownMenuItem(value: 'cancelled', child: Text('Cancelled')),
                    ],
                    onChanged: (v) => setDialogState(() => status = v ?? 'draft'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Any additional notes',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                // Items section
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Items (${items.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final item = await _showAddItemDialog(products);
                        if (item != null) {
                          setDialogState(() => items.add(item));
                        }
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add Item'),
                    ),
                  ],
                ),
                if (items.isNotEmpty)
                  ...items.asMap().entries.map((entry) {
                    final i = entry.key;
                    final item = entry.value;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.productName),
                      subtitle: Text('${item.quantity} × ₹${item.pricePerUnit.toStringAsFixed(2)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '₹${item.totalAmount.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setDialogState(() => items.removeAt(i)),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (vendorController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Vendor name is required')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(existingOrder == null ? 'Create' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final totalAmount = items.fold(0.0, (sum, item) => sum + item.totalAmount);
      final id = existingOrder?.id ?? await PurchaseOrderService.generateNextId();
      final orderNumber = existingOrder?.orderNumber ?? await PurchaseOrderService.generateNextOrderNumber();

      final order = PurchaseOrder(
        id: id,
        orderNumber: orderNumber,
        vendorName: vendorController.text,
        items: items,
        date: orderDate,
        expectedDate: expectedDate,
        status: status,
        totalAmount: totalAmount,
        amountPaid: existingOrder?.amountPaid ?? 0,
        notes: notesController.text,
      );

      if (existingOrder == null) {
        await PurchaseOrderService.insertPurchaseOrder(order, items);
      } else {
        await PurchaseOrderService.updatePurchaseOrder(order, items: items);
      }
      _loadData();
    }
  }

  Future<PurchaseOrderItem?> _showAddItemDialog(List<Product> products) async {
    Product? selectedProduct;
    final qtyController = TextEditingController(text: '1');
    final priceController = TextEditingController();

    return showDialog<PurchaseOrderItem>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Item'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Product>(
                decoration: const InputDecoration(labelText: 'Product *'),
                items: products.map((p) => DropdownMenuItem(
                  value: p,
                  child: Text(p.name, overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (p) {
                  selectedProduct = p;
                  if (p != null) {
                    priceController.text = p.purchasePrice > 0
                        ? p.purchasePrice.toStringAsFixed(2)
                        : p.price.toStringAsFixed(2);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qtyController,
                decoration: const InputDecoration(labelText: 'Quantity *'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceController,
                decoration: const InputDecoration(
                  labelText: 'Price per Unit *',
                  prefixText: '₹ ',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (selectedProduct == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Select a product')),
                );
                return;
              }
              final qty = double.tryParse(qtyController.text) ?? 1;
              final price = double.tryParse(priceController.text) ?? 0;
              Navigator.pop(context, PurchaseOrderItem(
                id: 'poi-${DateTime.now().millisecondsSinceEpoch}',
                productId: selectedProduct!.id,
                productName: selectedProduct!.name,
                quantity: qty,
                pricePerUnit: price,
                taxRate: selectedProduct!.tax_rate.toDouble(),
              ));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _showOrderDetail(PurchaseOrder order) async {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('PO #${order.orderNumber ?? order.id}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Vendor: ${order.vendorName}'),
              Text('Date: ${DateFormat('dd MMM yyyy').format(order.date)}'),
              if (order.expectedDate != null)
                Text('Expected: ${DateFormat('dd MMM yyyy').format(order.expectedDate!)}'),
              Text('Status: ${order.status}'),
              const Divider(),
              ...order.items.map((item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text('${item.productName} (${item.quantity})')),
                    Text(currencyFormat.format(item.totalAmount)),
                  ],
                ),
              )),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(currencyFormat.format(order.totalAmount),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              if (order.amountPaid > 0) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Paid:'),
                    Text(currencyFormat.format(order.amountPaid)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Outstanding:', style: TextStyle(color: Colors.orange)),
                    Text(
                      currencyFormat.format(order.outstandingBalance),
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (order.status == 'draft')
            FilledButton(
              onPressed: () async {
                await PurchaseOrderService.updateStatus(order.id, 'confirmed');
                Navigator.pop(context);
                _loadData();
              },
              child: const Text('Confirm'),
            ),
          if (order.status == 'confirmed')
            FilledButton(
              onPressed: () async {
                // Mark as received and update stock
                for (final item in order.items) {
                  final product = await ProductService.getProductById(item.productId);
                  if (product != null && !product.unlimitedStock) {
                    final newStock = product.stock + item.quantity.toInt();
                    await ProductService.updateProductStock(product.id, newStock);
                  }
                }
                await PurchaseOrderService.updateStatus(order.id, 'received');
                Navigator.pop(context);
                _loadData();
              },
              child: const Text('Mark Received'),
            ),
        ],
      ),
    );
  }
}
