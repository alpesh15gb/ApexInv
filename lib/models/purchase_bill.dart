class PurchaseBillItem {
  final String id;
  final String purchaseBillId;
  final String? productId;
  final String productName;
  final String hsnCode;
  final double quantity;
  final String unit;
  final double rate;
  final double taxRate; // percent, e.g. 18
  final double discount; // flat amount per line
  final double taxableValue;
  final double igst;
  final double cgst;
  final double sgst;
  final double amount; // taxable + tax

  const PurchaseBillItem({
    required this.id,
    required this.purchaseBillId,
    this.productId,
    required this.productName,
    this.hsnCode = '',
    this.quantity = 1,
    this.unit = '',
    required this.rate,
    this.taxRate = 0,
    this.discount = 0,
    this.taxableValue = 0,
    this.igst = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.amount = 0,
  });

  /// Computes the line's taxable value and tax split. `interState` chooses
  /// IGST vs CGST+SGST (50/50).
  static PurchaseBillItem compute({
    required String id,
    required String purchaseBillId,
    String? productId,
    required String productName,
    String hsnCode = '',
    required double quantity,
    String unit = '',
    required double rate,
    required double taxRate,
    required double discount,
    required bool interState,
  }) {
    final gross = quantity * rate;
    final taxable = (gross - discount).clamp(0.0, double.infinity);
    final tax = taxable * taxRate / 100;
    return PurchaseBillItem(
      id: id,
      purchaseBillId: purchaseBillId,
      productId: productId,
      productName: productName,
      hsnCode: hsnCode,
      quantity: quantity,
      unit: unit,
      rate: rate,
      taxRate: taxRate,
      discount: discount,
      taxableValue: taxable,
      igst: interState ? tax : 0,
      cgst: interState ? 0 : tax / 2,
      sgst: interState ? 0 : tax / 2,
      amount: taxable + tax,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'purchase_bill_id': purchaseBillId,
        'product_id': productId,
        'product_name': productName,
        'hsn_code': hsnCode,
        'quantity': quantity,
        'unit': unit,
        'rate': rate,
        'tax_rate': taxRate,
        'discount': discount,
        'taxable_value': taxableValue,
        'igst': igst,
        'cgst': cgst,
        'sgst': sgst,
        'amount': amount,
      };

  factory PurchaseBillItem.fromMap(Map<String, dynamic> map) =>
      PurchaseBillItem(
        id: map['id'] as String,
        purchaseBillId: map['purchase_bill_id'] as String,
        productId: map['product_id'] as String?,
        productName: map['product_name'] as String? ?? '',
        hsnCode: map['hsn_code'] as String? ?? '',
        quantity: (map['quantity'] as num?)?.toDouble() ?? 1,
        unit: map['unit'] as String? ?? '',
        rate: (map['rate'] as num?)?.toDouble() ?? 0,
        taxRate: (map['tax_rate'] as num?)?.toDouble() ?? 0,
        discount: (map['discount'] as num?)?.toDouble() ?? 0,
        taxableValue: (map['taxable_value'] as num?)?.toDouble() ?? 0,
        igst: (map['igst'] as num?)?.toDouble() ?? 0,
        cgst: (map['cgst'] as num?)?.toDouble() ?? 0,
        sgst: (map['sgst'] as num?)?.toDouble() ?? 0,
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
      );
}

class PurchaseBillPayment {
  final String id;
  final String purchaseBillId;
  final double amountPaid;
  final double previouslyPaid;
  final double balanceAfter;
  final DateTime datePaid;
  final String? paymentMethod;
  final String? notes;

  const PurchaseBillPayment({
    required this.id,
    required this.purchaseBillId,
    required this.amountPaid,
    required this.previouslyPaid,
    required this.balanceAfter,
    required this.datePaid,
    this.paymentMethod,
    this.notes,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'purchase_bill_id': purchaseBillId,
        'amount_paid': amountPaid,
        'previously_paid': previouslyPaid,
        'balance_after': balanceAfter,
        'date_paid': datePaid.toIso8601String(),
        'payment_method': paymentMethod,
        'notes': notes,
      };

  factory PurchaseBillPayment.fromMap(Map<String, dynamic> map) =>
      PurchaseBillPayment(
        id: map['id'] as String,
        purchaseBillId: map['purchase_bill_id'] as String,
        amountPaid: (map['amount_paid'] as num).toDouble(),
        previouslyPaid: (map['previously_paid'] as num?)?.toDouble() ?? 0,
        balanceAfter: (map['balance_after'] as num?)?.toDouble() ?? 0,
        datePaid: DateTime.parse(map['date_paid'] as String),
        paymentMethod: map['payment_method'] as String?,
        notes: map['notes'] as String?,
      );
}

class PurchaseBill {
  final String id;
  final String? billNumber; // supplier's invoice number
  final String supplierName;
  final String supplierGstin;
  final String supplierPhone;
  final String supplierEmail;
  final String supplierAddress;
  final DateTime date;
  final DateTime? dueDate;
  final double totalAmount; // taxable + tax
  final double totalTax;
  final double amountPaid;
  final bool itcEligible;
  final bool reverseCharge;
  final String notes;
  final String currencyCode;
  final String currencySymbol;
  final List<PurchaseBillItem> items;

  const PurchaseBill({
    required this.id,
    this.billNumber,
    required this.supplierName,
    this.supplierGstin = '',
    this.supplierPhone = '',
    this.supplierEmail = '',
    this.supplierAddress = '',
    required this.date,
    this.dueDate,
    this.totalAmount = 0,
    this.totalTax = 0,
    this.amountPaid = 0,
    this.itcEligible = true,
    this.reverseCharge = false,
    this.notes = '',
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    this.items = const [],
  });

  double get taxableTotal => items.fold(0, (s, i) => s + i.taxableValue);
  double get igstTotal => items.fold(0, (s, i) => s + i.igst);
  double get cgstTotal => items.fold(0, (s, i) => s + i.cgst);
  double get sgstTotal => items.fold(0, (s, i) => s + i.sgst);
  double get outstanding =>
      (totalAmount - amountPaid).clamp(0.0, double.infinity);

  PurchaseBill copyWith({double? amountPaid, List<PurchaseBillItem>? items}) {
    return PurchaseBill(
      id: id,
      billNumber: billNumber,
      supplierName: supplierName,
      supplierGstin: supplierGstin,
      supplierPhone: supplierPhone,
      supplierEmail: supplierEmail,
      supplierAddress: supplierAddress,
      date: date,
      dueDate: dueDate,
      totalAmount: totalAmount,
      totalTax: totalTax,
      amountPaid: amountPaid ?? this.amountPaid,
      itcEligible: itcEligible,
      reverseCharge: reverseCharge,
      notes: notes,
      currencyCode: currencyCode,
      currencySymbol: currencySymbol,
      items: items ?? this.items,
    );
  }
}
