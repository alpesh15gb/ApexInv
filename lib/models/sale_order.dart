class SaleOrder {
  final String id;
  final String orderNumber;
  final String customerId;
  final String customerName;
  final String customerEmail;
  final String customerPhone;
  final String customerAddress;
  final String customerGstin;
  final DateTime date;
  final DateTime? expectedDate;
  final String status; // draft | confirmed | partial | fulfilled | cancelled
  final String currencyCode;
  final String currencySymbol;
  final bool priceIncludesTax; // document-level GST toggle state
  final String notes;
  final List<SaleOrderItem> items;

  const SaleOrder({
    required this.id,
    required this.orderNumber,
    required this.customerId,
    required this.customerName,
    this.customerEmail = '',
    this.customerPhone = '',
    this.customerAddress = '',
    this.customerGstin = '',
    required this.date,
    this.expectedDate,
    this.status = 'draft',
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    this.priceIncludesTax = false,
    this.notes = '',
    this.items = const [],
  });

  double get total => items.fold(0.0, (sum, item) => sum + item.total);

  /// Order total honouring the document-level GST toggle: inclusive lines
  /// contribute their typed amount, exclusive lines add tax on top.
  double get displayTotal =>
      items.fold(0.0, (sum, item) => sum + item.totalFor(priceIncludesTax));

  double get remainingTotal =>
      items.fold(0.0, (sum, item) => sum + item.remainingTotal);

  factory SaleOrder.fromMap(Map<String, dynamic> map,
          {List<SaleOrderItem> items = const []}) =>
      SaleOrder(
        id: map['id'] as String,
        orderNumber: map['order_number'] as String? ?? '',
        customerId: map['customer_id'] as String? ?? '',
        customerName: map['customer_name'] as String? ?? '',
        customerEmail: map['customer_email'] as String? ?? '',
        customerPhone: map['customer_phone'] as String? ?? '',
        customerAddress: map['customer_address'] as String? ?? '',
        customerGstin: map['customer_gstin'] as String? ?? '',
        date: DateTime.parse(map['date'] as String),
        expectedDate: DateTime.tryParse(map['expected_date'] as String? ?? ''),
        status: map['status'] as String? ?? 'draft',
        currencyCode: map['currency_code'] as String? ?? 'INR',
        currencySymbol: map['currency_symbol'] as String? ?? '₹',
        priceIncludesTax: (map['price_includes_tax'] as num?)?.toInt() == 1,
        notes: map['notes'] as String? ?? '',
        items: items,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'order_number': orderNumber,
        'customer_id': customerId,
        'customer_name': customerName,
        'customer_email': customerEmail,
        'customer_phone': customerPhone,
        'customer_address': customerAddress,
        'customer_gstin': customerGstin,
        'date': date.toIso8601String(),
        'expected_date': expectedDate?.toIso8601String(),
        'status': status,
        'currency_code': currencyCode,
        'currency_symbol': currencySymbol,
        'price_includes_tax': priceIncludesTax ? 1 : 0,
        'notes': notes,
      };
}

class SaleOrderItem {
  final String id;
  final String saleOrderId;
  final String productId;
  final String productName;
  final String description;
  final double quantity;
  final double fulfilledQuantity;
  final double unitPrice;
  final double taxRate;
  final double discount;

  const SaleOrderItem({
    required this.id,
    required this.saleOrderId,
    required this.productId,
    required this.productName,
    this.description = '',
    required this.quantity,
    this.fulfilledQuantity = 0,
    required this.unitPrice,
    this.taxRate = 0,
    this.discount = 0,
  });

  double get remainingQuantity =>
      (quantity - fulfilledQuantity).clamp(0, double.infinity).toDouble();
  double get total {
    final taxable =
        (quantity * unitPrice - discount).clamp(0, double.infinity).toDouble();
    return taxable + taxable * taxRate / 100;
  }

  /// Line amount honouring the document-level GST toggle. Inclusive unit
  /// prices already contain tax, so the typed amount is the total.
  double totalFor(bool pricesIncludeTax) {
    final gross =
        (quantity * unitPrice - discount).clamp(0, double.infinity).toDouble();
    if (pricesIncludeTax) return gross;
    return gross + gross * taxRate / 100;
  }

  double get remainingTotal {
    if (quantity <= 0) return 0;
    return total * remainingQuantity / quantity;
  }

  factory SaleOrderItem.fromMap(Map<String, dynamic> map) => SaleOrderItem(
        id: map['id'] as String,
        saleOrderId: map['sale_order_id'] as String,
        productId: map['product_id'] as String,
        productName: map['product_name'] as String? ?? '',
        description: map['description'] as String? ?? '',
        quantity: (map['quantity'] as num?)?.toDouble() ?? 0,
        fulfilledQuantity: (map['fulfilled_quantity'] as num?)?.toDouble() ?? 0,
        unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0,
        taxRate: (map['tax_rate'] as num?)?.toDouble() ?? 0,
        discount: (map['discount'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'sale_order_id': saleOrderId,
        'product_id': productId,
        'product_name': productName,
        'description': description,
        'quantity': quantity,
        'fulfilled_quantity': fulfilledQuantity,
        'unit_price': unitPrice,
        'tax_rate': taxRate,
        'discount': discount,
      };
}
