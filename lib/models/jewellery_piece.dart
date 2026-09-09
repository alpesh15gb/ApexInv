import 'package:uuid/uuid.dart';

/// One tagged jewellery piece (retail.md P2). Jewellery is stocked per
/// piece — one necklace is not fungible with another — so sales pick
/// pieces, and a piece carries its own weights and hallmark id.
class JewelleryPiece {
  final String id;
  final String productId;
  final String tagNo;
  final String huid; // 6-char BIS hallmark id, may be empty
  final String purity; // falls back to the product's attributes when empty
  final double grossWeight;
  final double stoneWeight;
  final double netWeight; // derived default: gross − stone (stored)
  final String status; // in_stock | sold | exchanged | job_work
  final String? soldInvoiceId;

  const JewelleryPiece({
    required this.id,
    required this.productId,
    required this.tagNo,
    this.huid = '',
    this.purity = '',
    this.grossWeight = 0,
    this.stoneWeight = 0,
    this.netWeight = 0,
    this.status = 'in_stock',
    this.soldInvoiceId,
  });

  static const statuses = ['in_stock', 'sold', 'exchanged', 'job_work'];

  factory JewelleryPiece.create({
    required String productId,
    required String tagNo,
    String huid = '',
    String purity = '',
    required double grossWeight,
    required double stoneWeight,
    double? netWeight,
  }) {
    final net =
        netWeight ?? (grossWeight - stoneWeight).clamp(0.0, double.infinity);
    return JewelleryPiece(
      id: const Uuid().v4(),
      productId: productId,
      tagNo: tagNo,
      huid: huid,
      purity: purity,
      grossWeight: grossWeight,
      stoneWeight: stoneWeight,
      netWeight: net,
    );
  }

  factory JewelleryPiece.fromMap(Map<String, dynamic> map) {
    return JewelleryPiece(
      id: map['id']?.toString() ?? '',
      productId: map['product_id']?.toString() ?? '',
      tagNo: map['tag_no']?.toString() ?? '',
      huid: map['huid']?.toString() ?? '',
      purity: map['purity']?.toString() ?? '',
      grossWeight: (map['gross_weight'] as num?)?.toDouble() ?? 0.0,
      stoneWeight: (map['stone_weight'] as num?)?.toDouble() ?? 0.0,
      netWeight: (map['net_weight'] as num?)?.toDouble() ?? 0.0,
      status: map['status']?.toString() ?? 'in_stock',
      soldInvoiceId: map['sold_invoice_id']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'product_id': productId,
        'tag_no': tagNo,
        'huid': huid,
        'purity': purity,
        'gross_weight': grossWeight,
        'stone_weight': stoneWeight,
        'net_weight': netWeight,
        'status': status,
        'sold_invoice_id': soldInvoiceId,
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };

  bool get isInStock => status == 'in_stock';

  JewelleryPiece copyWith({
    String? tagNo,
    String? huid,
    String? purity,
    double? grossWeight,
    double? stoneWeight,
    double? netWeight,
    String? status,
    String? soldInvoiceId,
  }) {
    return JewelleryPiece(
      id: id,
      productId: productId,
      tagNo: tagNo ?? this.tagNo,
      huid: huid ?? this.huid,
      purity: purity ?? this.purity,
      grossWeight: grossWeight ?? this.grossWeight,
      stoneWeight: stoneWeight ?? this.stoneWeight,
      netWeight: netWeight ?? this.netWeight,
      status: status ?? this.status,
      soldInvoiceId: soldInvoiceId ?? this.soldInvoiceId,
    );
  }
}
