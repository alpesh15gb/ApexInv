import 'package:uuid/uuid.dart';

/// Daily metal rates per gram for one metal/purity pair.
///
/// [sellRatePerGram] is the retail rate used to bill jewellery and print tags.
/// [buyRatePerGram] is the shop's old-gold buyback rate. They are deliberately
/// separate: a retail sale rate is never an acquisition cost.
class MetalRate {
  final String id;
  final String metal; // 'gold' | 'silver'
  final String purity; // '24K' | '22K' | '18K' | '14K' | '925' | '999'
  final double sellRatePerGram;
  final double buyRatePerGram;
  final DateTime effectiveDate; // yyyy-MM-dd day the rate applies to

  const MetalRate({
    required this.id,
    required this.metal,
    required this.purity,
    required this.sellRatePerGram,
    required this.buyRatePerGram,
    required this.effectiveDate,
  });

  factory MetalRate.create({
    required String metal,
    required String purity,
    required double sellRatePerGram,
    required double buyRatePerGram,
    required DateTime effectiveDate,
  }) {
    if (!sellRatePerGram.isFinite ||
        !buyRatePerGram.isFinite ||
        sellRatePerGram <= 0 ||
        buyRatePerGram <= 0 ||
        buyRatePerGram > sellRatePerGram) {
      throw ArgumentError(
          'Sell and buyback rates must be positive, and buyback cannot exceed sell');
    }
    final day =
        DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    return MetalRate(
      id: const Uuid().v4(),
      metal: metal,
      purity: purity,
      sellRatePerGram: sellRatePerGram,
      buyRatePerGram: buyRatePerGram,
      effectiveDate: day,
    );
  }

  /// yyyy-MM-dd day key used for lookups and the UNIQUE(metal, purity, date)
  /// constraint.
  String get dateKey => '${effectiveDate.year.toString().padLeft(4, '0')}-'
      '${effectiveDate.month.toString().padLeft(2, '0')}-'
      '${effectiveDate.day.toString().padLeft(2, '0')}';

  factory MetalRate.fromMap(Map<String, dynamic> map) {
    final rawDate = map['effective_date'] as String? ?? '';
    // Pre-v62 databases/backups have one rate. Some old JSON/sync imports land
    // the new columns' zero defaults, which must behave like absent values.
    final legacyRate = (map['rate_per_gram'] as num?)?.toDouble() ?? 0.0;
    final storedSell =
        (map['sell_rate_per_gram'] as num?)?.toDouble() ?? legacyRate;
    final storedBuy =
        (map['buy_rate_per_gram'] as num?)?.toDouble() ?? legacyRate;
    return MetalRate(
      id: map['id']?.toString() ?? '',
      metal: map['metal']?.toString() ?? 'gold',
      purity: map['purity']?.toString() ?? '22K',
      sellRatePerGram: storedSell > 0 ? storedSell : legacyRate,
      buyRatePerGram: storedBuy > 0 ? storedBuy : legacyRate,
      effectiveDate: DateTime.tryParse(rawDate) ?? DateTime(2000),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'metal': metal,
        'purity': purity,
        // Keep the legacy column populated for older local backups and sync
        // peers. It always mirrors the explicit retail sell rate.
        'rate_per_gram': sellRatePerGram,
        'sell_rate_per_gram': sellRatePerGram,
        'buy_rate_per_gram': buyRatePerGram,
        'effective_date': dateKey,
        'company_id': 'local',
        'updated_at': DateTime.now().toIso8601String(),
      };

  static const List<String> metals = ['gold', 'silver'];

  static const List<String> purities = [
    '24K',
    '22K',
    '18K',
    '14K',
    '999',
    '925',
  ];

  static String metalLabel(String metal) =>
      metal == 'silver' ? 'Silver' : 'Gold';
}
