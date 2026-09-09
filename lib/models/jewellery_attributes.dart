/// Jewellery attributes for one catalog product (design/category).
///
/// Products stay the shared catalog; these attributes ride alongside and are
/// only edited/shown under the jewellery profile. Piece-level tracking
/// (phase 2) references the same shape per tagged piece.
class JewelleryAttributes {
  final String productId;
  final String metal; // 'gold' | 'silver'
  final String purity; // '24K' | '22K' | '18K' | '14K' | '925' | '999'
  final double grossWeight;
  final double stoneWeight;
  final double netWeight; // stored, editable; derived default gross − stone
  final String makingType; // 'fixed' | 'per_gram' | 'percent'
  final double makingValue;
  final double wastagePercent;
  final String huid; // 6-char BIS hallmark id, may be empty

  const JewelleryAttributes({
    required this.productId,
    this.metal = 'gold',
    this.purity = '22K',
    this.grossWeight = 0,
    this.stoneWeight = 0,
    this.netWeight = 0,
    this.makingType = 'fixed',
    this.makingValue = 0,
    this.wastagePercent = 0,
    this.huid = '',
  });

  factory JewelleryAttributes.fromMap(Map<String, dynamic> map) {
    return JewelleryAttributes(
      productId: map['product_id']?.toString() ?? '',
      metal: map['metal']?.toString() ?? 'gold',
      purity: map['purity']?.toString() ?? '22K',
      grossWeight: (map['gross_weight'] as num?)?.toDouble() ?? 0.0,
      stoneWeight: (map['stone_weight'] as num?)?.toDouble() ?? 0.0,
      netWeight: (map['net_weight'] as num?)?.toDouble() ?? 0.0,
      makingType: map['making_type']?.toString() ?? 'fixed',
      makingValue: (map['making_value'] as num?)?.toDouble() ?? 0.0,
      wastagePercent: (map['wastage_percent'] as num?)?.toDouble() ?? 0.0,
      huid: map['huid']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'product_id': productId,
        'metal': metal,
        'purity': purity,
        'gross_weight': grossWeight,
        'stone_weight': stoneWeight,
        'net_weight': netWeight,
        'making_type': makingType,
        'making_value': makingValue,
        'wastage_percent': wastagePercent,
        'huid': huid,
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };

  JewelleryAttributes copyWith({
    String? metal,
    String? purity,
    double? grossWeight,
    double? stoneWeight,
    double? netWeight,
    String? makingType,
    double? makingValue,
    double? wastagePercent,
    String? huid,
  }) {
    return JewelleryAttributes(
      productId: productId,
      metal: metal ?? this.metal,
      purity: purity ?? this.purity,
      grossWeight: grossWeight ?? this.grossWeight,
      stoneWeight: stoneWeight ?? this.stoneWeight,
      netWeight: netWeight ?? this.netWeight,
      makingType: makingType ?? this.makingType,
      makingValue: makingValue ?? this.makingValue,
      wastagePercent: wastagePercent ?? this.wastagePercent,
      huid: huid ?? this.huid,
    );
  }
}
