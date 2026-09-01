class BatchInfo {
  final String id;
  final String productId;
  final String batchNumber;
  final String? serialNumber;
  final double quantity;
  final double mrp;
  final DateTime? expiryDate;
  final DateTime? manufacturingDate;
  final String? size;

  const BatchInfo({
    required this.id,
    required this.productId,
    required this.batchNumber,
    this.serialNumber,
    this.quantity = 0.0,
    this.mrp = 0.0,
    this.expiryDate,
    this.manufacturingDate,
    this.size,
  });

  factory BatchInfo.fromMap(Map<String, dynamic> map) {
    return BatchInfo(
      id: map['id']?.toString() ?? '',
      productId: map['product_id']?.toString() ?? '',
      batchNumber: map['batch_number'] ?? '',
      serialNumber: map['serial_number'] as String?,
      quantity: (map['quantity'] as num?)?.toDouble() ?? 0.0,
      mrp: (map['mrp'] as num?)?.toDouble() ?? 0.0,
      expiryDate: map['expiry_date'] != null
          ? DateTime.parse(map['expiry_date'])
          : null,
      manufacturingDate: map['manufacturing_date'] != null
          ? DateTime.parse(map['manufacturing_date'])
          : null,
      size: map['size'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'batch_number': batchNumber,
      'serial_number': serialNumber,
      'quantity': quantity,
      'mrp': mrp,
      'expiry_date': expiryDate?.toIso8601String(),
      'manufacturing_date': manufacturingDate?.toIso8601String(),
      'size': size,
    };
  }

  BatchInfo copyWith({
    String? id,
    String? productId,
    String? batchNumber,
    String? serialNumber,
    double? quantity,
    double? mrp,
    DateTime? expiryDate,
    DateTime? manufacturingDate,
    String? size,
  }) {
    return BatchInfo(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      batchNumber: batchNumber ?? this.batchNumber,
      serialNumber: serialNumber ?? this.serialNumber,
      quantity: quantity ?? this.quantity,
      mrp: mrp ?? this.mrp,
      expiryDate: expiryDate ?? this.expiryDate,
      manufacturingDate: manufacturingDate ?? this.manufacturingDate,
      size: size ?? this.size,
    );
  }

  bool get isExpired {
    if (expiryDate == null) return false;
    return expiryDate!.isBefore(DateTime.now());
  }
}
