class PurchaseOrder {
  final String id;
  final String? orderNumber;
  final String vendorName;
  final String? vendorPhone;
  final String? vendorEmail;
  final String? vendorAddress;
  final List<PurchaseOrderItem> items;
  final DateTime date;
  final DateTime? expectedDate;
  final String status; // 'draft', 'confirmed', 'received', 'cancelled'
  final double totalAmount;
  final double amountPaid;
  final bool priceIncludesTax; // document-level GST toggle state
  final String? notes;
  final String currencyCode;
  final String currencySymbol;

  const PurchaseOrder({
    required this.id,
    this.orderNumber,
    required this.vendorName,
    this.vendorPhone,
    this.vendorEmail,
    this.vendorAddress,
    this.items = const [],
    required this.date,
    this.expectedDate,
    this.status = 'draft',
    this.totalAmount = 0.0,
    this.amountPaid = 0.0,
    this.priceIncludesTax = false,
    this.notes,
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
  });

  factory PurchaseOrder.fromMap(Map<String, dynamic> map) {
    return PurchaseOrder(
      id: map['id']?.toString() ?? '',
      orderNumber: map['order_number'] as String?,
      vendorName: map['vendor_name'] ?? '',
      vendorPhone: map['vendor_phone'] as String?,
      vendorEmail: map['vendor_email'] as String?,
      vendorAddress: map['vendor_address'] as String?,
      date: map['date'] != null ? DateTime.parse(map['date']) : DateTime.now(),
      expectedDate: map['expected_date'] != null
          ? DateTime.parse(map['expected_date'])
          : null,
      status: map['status'] ?? 'draft',
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0.0,
      amountPaid: (map['amount_paid'] as num?)?.toDouble() ?? 0.0,
      priceIncludesTax: (map['price_includes_tax'] as num?)?.toInt() == 1,
      notes: map['notes'] as String?,
      currencyCode: map['currency_code'] ?? 'INR',
      currencySymbol: map['currency_symbol'] ?? '₹',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'order_number': orderNumber,
      'vendor_name': vendorName,
      'vendor_phone': vendorPhone,
      'vendor_email': vendorEmail,
      'vendor_address': vendorAddress,
      'date': date.toIso8601String(),
      'expected_date': expectedDate?.toIso8601String(),
      'status': status,
      'total_amount': totalAmount,
      'amount_paid': amountPaid,
      'price_includes_tax': priceIncludesTax ? 1 : 0,
      'notes': notes,
      'currency_code': currencyCode,
      'currency_symbol': currencySymbol,
    };
  }

  double get outstandingBalance => totalAmount - amountPaid;

  PurchaseOrder copyWith({
    String? id,
    String? orderNumber,
    String? vendorName,
    String? vendorPhone,
    String? vendorEmail,
    String? vendorAddress,
    List<PurchaseOrderItem>? items,
    DateTime? date,
    DateTime? expectedDate,
    String? status,
    double? totalAmount,
    double? amountPaid,
    bool? priceIncludesTax,
    String? notes,
    String? currencyCode,
    String? currencySymbol,
  }) {
    return PurchaseOrder(
      id: id ?? this.id,
      orderNumber: orderNumber ?? this.orderNumber,
      vendorName: vendorName ?? this.vendorName,
      vendorPhone: vendorPhone ?? this.vendorPhone,
      vendorEmail: vendorEmail ?? this.vendorEmail,
      vendorAddress: vendorAddress ?? this.vendorAddress,
      items: items ?? this.items,
      date: date ?? this.date,
      expectedDate: expectedDate ?? this.expectedDate,
      status: status ?? this.status,
      totalAmount: totalAmount ?? this.totalAmount,
      amountPaid: amountPaid ?? this.amountPaid,
      priceIncludesTax: priceIncludesTax ?? this.priceIncludesTax,
      notes: notes ?? this.notes,
      currencyCode: currencyCode ?? this.currencyCode,
      currencySymbol: currencySymbol ?? this.currencySymbol,
    );
  }
}

class PurchaseOrderItem {
  final String id;
  final String productId;
  final String productName;
  final double quantity;
  final double pricePerUnit;
  final double taxRate;
  final double discount;
  final String? description;

  const PurchaseOrderItem({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.pricePerUnit,
    this.taxRate = 0.0,
    this.discount = 0.0,
    this.description,
  });

  double get totalAmount {
    final sub = quantity * pricePerUnit - discount;
    return sub + (sub * taxRate / 100);
  }

  /// Line amount honouring the document-level GST toggle. Inclusive unit
  /// prices already contain tax, so the typed amount is the total.
  double totalFor(bool pricesIncludeTax) {
    final sub = quantity * pricePerUnit - discount;
    if (pricesIncludeTax) return sub;
    return sub + (sub * taxRate / 100);
  }

  factory PurchaseOrderItem.fromMap(Map<String, dynamic> map) {
    return PurchaseOrderItem(
      id: map['id']?.toString() ?? '',
      productId: map['product_id']?.toString() ?? '',
      productName: map['product_name'] ?? '',
      quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
      pricePerUnit: (map['price_per_unit'] as num?)?.toDouble() ?? 0.0,
      taxRate: (map['tax_rate'] as num?)?.toDouble() ?? 0.0,
      discount: (map['discount'] as num?)?.toDouble() ?? 0.0,
      description: map['description'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'product_name': productName,
      'quantity': quantity,
      'price_per_unit': pricePerUnit,
      'tax_rate': taxRate,
      'discount': discount,
      'description': description,
    };
  }
}
