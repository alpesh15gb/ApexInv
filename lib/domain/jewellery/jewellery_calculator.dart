/// Pure-Dart jewellery billing math (see retail.md §4.3).
///
/// Metal value = net weight × rate/gram; wastage is a % of the metal value;
/// making charges are flat, per-gram, or a % of metal value. A retail
/// jewellery supply is taxed at 3% on its complete jewellery value (metal,
/// making, wastage and stones). Screens render these results; they never
/// reimplement them.
///
/// Rate semantics (BUG-05): `metal_rates` stores a market rate per
/// (metal, purity) pair — the rate board asks for a distinct price for 24K,
/// 22K, 18K, etc., and billing always looks the rate up by the item's own
/// purity. Those rates are ALREADY purity-adjusted, so the purity factor is
/// never multiplied in again here. [purityFactor] remains the pure
/// karat→fine-gold mapping for callers that hold a 24K-equivalent rate.
library;

/// GST on a retail jewellery supply. Standalone job work has separate tax
/// treatment and is not calculated by this retail-sale calculator.
const double jewelleryGstPercent = 3.0;

/// Calculation treatment frozen on an invoice line. The legacy option only
/// exists to reproduce invoices issued before the retail-jewellery rule was
/// corrected; new lines always use [retail3].
enum JewelleryTaxTreatment { legacySplit, retail3 }

extension JewelleryTaxTreatmentKey on JewelleryTaxTreatment {
  String get key => switch (this) {
        JewelleryTaxTreatment.legacySplit => 'legacy_split',
        JewelleryTaxTreatment.retail3 => 'retail_3',
      };
}

JewelleryTaxTreatment jewelleryTaxTreatmentFromKey(String? key) =>
    key == JewelleryTaxTreatment.legacySplit.key
        ? JewelleryTaxTreatment.legacySplit
        : JewelleryTaxTreatment.retail3;

const double _legacyMetalGstPercent = 3.0;
const double _legacyMakingGstPercent = 5.0;

/// Purity → fraction of 24K fine gold. Keys match `MetalRate.purity` and
/// `JewelleryAttributes.purity` ('24K', '22K', '18K', '14K', '925', '999').
double purityFactor(String purity) {
  switch (purity.trim().toUpperCase()) {
    case '24K':
    case '999':
    case '995':
      return 1.0;
    case '22K':
    case '916':
      return 0.916;
    case '18K':
    case '750':
      return 0.75;
    case '14K':
    case '585':
      return 0.585;
    case '925':
      return 0.925;
    default:
      return 1.0;
  }
}

/// How making charges are computed for a line.
enum MakingType { fixed, perGram, percent }

MakingType makingTypeFromKey(String? key) {
  switch (key) {
    case 'per_gram':
      return MakingType.perGram;
    case 'percent':
      return MakingType.percent;
    default:
      return MakingType.fixed;
  }
}

extension MakingTypeKey on MakingType {
  String get key => switch (this) {
        MakingType.fixed => 'fixed',
        MakingType.perGram => 'per_gram',
        MakingType.percent => 'percent',
      };
}

/// One jewellery line broken into its GST-exclusive components.
class JewelleryLineAmount {
  /// Fine-metal value: netWeight × ratePerGram (purity-specific rate).
  final double metalValue;

  /// Wastage (va) amount: metalValue × wastagePercent / 100.
  final double wastageAmount;

  /// Making charge amount per [MakingType].
  final double makingAmount;

  /// Extra stone/other charges included in the jewellery taxable value.
  final double stoneAmount;

  const JewelleryLineAmount({
    required this.metalValue,
    required this.wastageAmount,
    required this.makingAmount,
    this.stoneAmount = 0.0,
  });

  /// GST-exclusive line base.
  double get lineBase =>
      metalValue + wastageAmount + makingAmount + stoneAmount;

  /// GST on the complete retail jewellery value.
  double get metalTax => lineBase * jewelleryGstPercent / 100;

  /// Kept as a zero-valued compatibility component for callers that render
  /// the historical two-column breakdown. New retail invoices have one 3%
  /// jewellery tax bucket.
  double get makingTax => 0;

  /// Total GST for the line.
  double get lineTax => metalTax + makingTax;

  double get lineTotal => lineBase + lineTax;
}

class JewelleryCalculator {
  const JewelleryCalculator._();

  /// Net weight is always gross − stone; callers pass both so a mistyped
  /// stored value cannot silently inflate a bill.
  static double netWeight(double grossWeight, double stoneWeight) =>
      (grossWeight - stoneWeight).clamp(0.0, double.infinity);

  /// Fine-metal value: netWeight × ratePerGram. [ratePerGram] must be the
  /// purity-specific rate for [purity] — the rate board stores
  /// purity-adjusted prices, so no further purity conversion happens here
  /// (BUG-05: re-applying [purityFactor] double-discounted every 22K/18K
  /// line billed from its own rate row).
  static double metalValue({
    required double netWeight,
    required String purity,
    required double ratePerGram,
  }) =>
      netWeight * ratePerGram;

  static double wastageAmount({
    required double metalValue,
    required double wastagePercent,
  }) =>
      metalValue * wastagePercent / 100;

  static double makingAmount({
    required MakingType makingType,
    required double makingValue,
    required double netWeight,
    required double metalValue,
  }) {
    switch (makingType) {
      case MakingType.fixed:
        return makingValue;
      case MakingType.perGram:
        return netWeight * makingValue;
      case MakingType.percent:
        return metalValue * makingValue / 100;
    }
  }

  /// GST components for a stored retail jewellery line. The record shape is
  /// retained for older consumers, but all taxable components are now in the
  /// single 3% jewellery bucket.
  static ({double metalTax, double makingTax}) frozenLineTaxSplit({
    required double metalBase,
    required double makingAmount,
    required double wastageAmount,
    JewelleryTaxTreatment treatment = JewelleryTaxTreatment.retail3,
  }) =>
      treatment == JewelleryTaxTreatment.legacySplit
          ? (
              metalTax: metalBase * _legacyMetalGstPercent / 100,
              makingTax: (makingAmount + wastageAmount) *
                  _legacyMakingGstPercent /
                  100,
            )
          : (
              metalTax: (metalBase + makingAmount + wastageAmount) *
                  jewelleryGstPercent /
                  100,
              makingTax: 0,
            );

  static JewelleryLineAmount line({
    required double grossWeight,
    required double stoneWeight,
    required String purity,
    required double ratePerGram,
    required MakingType makingType,
    required double makingValue,
    required double wastagePercent,
    double stoneAmount = 0.0,
  }) {
    final net = netWeight(grossWeight, stoneWeight);
    final metal =
        metalValue(netWeight: net, purity: purity, ratePerGram: ratePerGram);
    return JewelleryLineAmount(
      metalValue: metal,
      wastageAmount:
          wastageAmount(metalValue: metal, wastagePercent: wastagePercent),
      makingAmount: makingAmount(
          makingType: makingType,
          makingValue: makingValue,
          netWeight: net,
          metalValue: metal),
      stoneAmount: stoneAmount,
    );
  }
}
