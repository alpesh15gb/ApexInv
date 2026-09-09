/// Old gold received against a sale. The exchange credit is booked as a
/// receipt from the customer into Old Gold Stock at the negotiated buyback
/// rate frozen on this entry.
class OldGoldEntry {
  final String id;
  final String? invoiceId;
  final String? customerId;
  final String customerName;
  final String metal; // 'gold' | 'silver'
  final String purity;
  final double grossWeight;
  final double netWeight;
  final double ratePerGram;
  final double amount; // net weight × agreed purity-specific buyback rate

  /// Historical/manual RCM amount only. New old-gold exchanges do not infer
  /// RCM from a customer's GSTIN; any supplier-tax treatment needs its own
  /// purchase document and accountant review.
  final double rcmTax;

  const OldGoldEntry({
    required this.id,
    this.invoiceId,
    this.customerId,
    this.customerName = '',
    required this.metal,
    this.purity = '',
    this.grossWeight = 0,
    this.netWeight = 0,
    this.ratePerGram = 0,
    this.amount = 0,
    this.rcmTax = 0,
  });

  factory OldGoldEntry.fromMap(Map<String, dynamic> map) {
    return OldGoldEntry(
      id: map['id']?.toString() ?? '',
      invoiceId: map['invoice_id']?.toString(),
      customerId: map['customer_id']?.toString(),
      customerName: map['customer_name']?.toString() ?? '',
      metal: map['metal']?.toString() ?? 'gold',
      purity: map['purity']?.toString() ?? '',
      grossWeight: (map['gross_weight'] as num?)?.toDouble() ?? 0.0,
      netWeight: (map['net_weight'] as num?)?.toDouble() ?? 0.0,
      ratePerGram: (map['rate_per_gram'] as num?)?.toDouble() ?? 0.0,
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      rcmTax: (map['rcm_tax'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'invoice_id': invoiceId,
        'customer_id': customerId,
        'customer_name': customerName,
        'metal': metal,
        'purity': purity,
        'gross_weight': grossWeight,
        'net_weight': netWeight,
        'rate_per_gram': ratePerGram,
        'amount': amount,
        'rcm_tax': rcmTax,
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };
}

/// One karigar job (retail.md P3): metal issued out, finished pieces
/// received back, wastage measured as the weight that never returned.
class JobWorkOrder {
  final String id;
  final String karigar;
  final String metal; // 'gold' | 'silver'
  final String purity;
  final String description;
  final double issuedGross;
  final double issuedStone;
  final DateTime? issuedDate;
  final String status; // 'open' | 'received'
  final double receivedNet;
  final double wastagePercent;
  final DateTime? receivedDate;

  const JobWorkOrder({
    required this.id,
    required this.karigar,
    required this.metal,
    this.purity = '',
    this.description = '',
    this.issuedGross = 0,
    this.issuedStone = 0,
    this.issuedDate,
    this.status = 'open',
    this.receivedNet = 0,
    this.wastagePercent = 0,
    this.receivedDate,
  });

  static const statuses = ['open', 'received'];

  factory JobWorkOrder.fromMap(Map<String, dynamic> map) {
    return JobWorkOrder(
      id: map['id']?.toString() ?? '',
      karigar: map['karigar']?.toString() ?? '',
      metal: map['metal']?.toString() ?? 'gold',
      purity: map['purity']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      issuedGross: (map['issued_gross'] as num?)?.toDouble() ?? 0.0,
      issuedStone: (map['issued_stone'] as num?)?.toDouble() ?? 0.0,
      issuedDate: DateTime.tryParse(map['issued_date']?.toString() ?? ''),
      status: map['status']?.toString() ?? 'open',
      receivedNet: (map['received_net'] as num?)?.toDouble() ?? 0.0,
      wastagePercent: (map['wastage_percent'] as num?)?.toDouble() ?? 0.0,
      receivedDate: DateTime.tryParse(map['received_date']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'karigar': karigar,
        'metal': metal,
        'purity': purity,
        'description': description,
        'issued_gross': issuedGross,
        'issued_stone': issuedStone,
        'issued_date': issuedDate?.toIso8601String(),
        'status': status,
        'received_net': receivedNet,
        'wastage_percent': wastagePercent,
        'received_date': receivedDate?.toIso8601String(),
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };

  bool get isOpen => status == 'open';

  /// Issued net metal = gross − stone; wastage % derives on receive.
  double get issuedNet =>
      (issuedGross - issuedStone).clamp(0.0, double.infinity);

  JobWorkOrder copyWith({
    String? karigar,
    String? metal,
    String? purity,
    String? description,
    double? issuedGross,
    double? issuedStone,
    DateTime? issuedDate,
    String? status,
    double? receivedNet,
    double? wastagePercent,
    DateTime? receivedDate,
  }) {
    return JobWorkOrder(
      id: id,
      karigar: karigar ?? this.karigar,
      metal: metal ?? this.metal,
      purity: purity ?? this.purity,
      description: description ?? this.description,
      issuedGross: issuedGross ?? this.issuedGross,
      issuedStone: issuedStone ?? this.issuedStone,
      issuedDate: issuedDate ?? this.issuedDate,
      status: status ?? this.status,
      receivedNet: receivedNet ?? this.receivedNet,
      wastagePercent: wastagePercent ?? this.wastagePercent,
      receivedDate: receivedDate ?? this.receivedDate,
    );
  }
}

/// One variant of a retail product (size/colour — retail.md P4). The
/// catalog product stays the shared design; variants are sellable options.
class ProductVariant {
  final String id;
  final String productId;
  final String name; // 'Size' | 'Colour' | ...
  final String value; // 'M' | 'Red' | ...
  final double extraPrice;
  final double stock;
  final String barcode;

  const ProductVariant({
    required this.id,
    required this.productId,
    required this.name,
    required this.value,
    this.extraPrice = 0,
    this.stock = 0,
    this.barcode = '',
  });

  factory ProductVariant.fromMap(Map<String, dynamic> map) {
    return ProductVariant(
      id: map['id']?.toString() ?? '',
      productId: map['product_id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      value: map['value']?.toString() ?? '',
      extraPrice: (map['extra_price'] as num?)?.toDouble() ?? 0.0,
      stock: (map['stock'] as num?)?.toDouble() ?? 0.0,
      barcode: map['barcode']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'product_id': productId,
        'name': name,
        'value': value,
        'extra_price': extraPrice,
        'stock': stock,
        'barcode': barcode,
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };
}
