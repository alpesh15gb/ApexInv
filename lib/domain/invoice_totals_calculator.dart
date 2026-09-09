import 'package:apexbooks/common/common.dart';

import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';

// Price glossary — which "price" to use where:
//
// product.price          Stored catalog price. Tax-inclusive or exclusive
//                         depending on product.priceIncludesTax.
// item.unitPrice          Optional per-invoice override of product.price
//                         (null = use product.price). Same inclusive/exclusive
//                         rule as product.price applies to it too.
// item.effectivePrice     unitPrice ?? product.price. "The price actually
//                         charged for one unit on this invoice." Use this,
//                         never product.price directly, when displaying/
//                         calculating an invoice line.
// netPrice()              effectivePrice with tax backed out (only when
//                         priceIncludesTax is true). "What the unit is worth
//                         before tax." Use for tax-exclusive display only —
//                         never feed it back into line()'s `price` param.
// InvoiceLineAmount.lineTotal    Taxable base for the line (qty applied,
//                         discount/extraCost applied, tax backed out if
//                         inclusive). Feeds itemTax and totals().
// InvoiceLineAmount.grossTotal   Same as lineTotal but pre-discount —
//                         used for line-item "before discount" display.
// InvoiceLineAmount.displayTotal Qty × price incl. discount/extraCost,
//                         WITHOUT backing out tax. "What the line item row
//                         shows as its total." == item.total.
// InvoiceLineAmount.itemTax      lineTotal × taxRatePercent/100. == item.taxAmount.
// InvoiceTotals.subtotal/tax/total  Invoice-wide sums of the above across
//                         all lines — see totals() below.
//
// Rule of thumb: effectivePrice for calculating, netPrice() only for showing
// a tax-exclusive number to the user, displayTotal/total for the row's price tag.

enum TaxRateFormat {
  fraction,
  percent,
}

class InvoiceLineAmount {
  final double lineTotal;
  final double grossTotal;
  final double discountTotal;
  final double taxRatePercent;
  final double displayTotal;

  /// Jewellery weight lines carry their statutory 3% tax separately from the
  /// generic product/global tax configuration. Null ⇒ derived from the rate.
  final double? itemTaxOverride;

  /// True only for a retail jewellery line that must keep its statutory 3%
  /// treatment even when the document otherwise uses a generic global rate.
  final bool useTaxOverrideInGlobal;

  const InvoiceLineAmount({
    required this.lineTotal,
    required this.grossTotal,
    required this.discountTotal,
    required this.taxRatePercent,
    required this.displayTotal,
    this.itemTaxOverride,
    this.useTaxOverrideInGlobal = false,
  });

  double get itemTax => itemTaxOverride ?? lineTotal * (taxRatePercent / 100);
}

class InvoiceTotals {
  final double subtotal;
  final double grossSubtotal;
  final double totalDiscount;
  final double tax;
  final double additionalCostsTotal;
  final double invoiceDiscountAmount;

  const InvoiceTotals({
    required this.subtotal,
    required this.grossSubtotal,
    required this.totalDiscount,
    required this.tax,
    required this.additionalCostsTotal,
    this.invoiceDiscountAmount = 0.0,
  });

  double get preDiscountTotal => subtotal + tax + additionalCostsTotal;

  double get total =>
      (preDiscountTotal - invoiceDiscountAmount).clamp(0.0, double.infinity);
}

class InvoiceTotalsCalculator {
  const InvoiceTotalsCalculator._();

  /// Round-off for an invoice total, rounded to paise. Returns 0 when
  /// disabled. Positive means the customer pays slightly more than the
  /// exact total (rounded up), negative the reverse.
  static double roundOffAmount(double total, {required bool enabled}) {
    if (!enabled) return 0.0;
    final rounded = total.roundToDouble();
    return ((rounded - total) * 100).roundToDouble() / 100;
  }

  /// Payable total: exact total plus round-off when enabled.
  static double payableTotal(double total, {required bool enabled}) =>
      total + roundOffAmount(total, enabled: enabled);

  /// Backs tax out of a tax-inclusive price. Returns [price] unchanged
  /// when the price is exclusive or tax rate is 0.
  static double netPrice({
    required double price,
    required double taxRatePercent,
    required bool priceIncludesTax,
  }) {
    if (!priceIncludesTax || taxRatePercent <= 0) return price;
    return price / (1 + taxRatePercent / 100);
  }

  static InvoiceLineAmount line({
    required double price,
    required double quantity,
    required double discount,
    required bool discountPerUnit,
    double extraCost = 0,
    double taxRatePercent = 0,
    bool priceIncludesTax = false,
    TaxMode taxMode = TaxMode.perItem,
    double globalTaxRatePercent = 0,
  }) {
    final displayTotal = discountPerUnit
        ? (price - discount) * quantity + extraCost
        : (price * quantity) - discount + extraCost;
    // When price is tax-inclusive, back out the tax so lineTotal holds the
    // taxable base — itemTax and every downstream subtotal/tax sum then
    // stay correct without touching the totals() aggregation formula.
    // In global mode the invoice charges globalTaxRatePercent, not the
    // item's own rate, so that's the rate actually baked into the price
    // and the one that must be backed out here.
    final backOutRatePercent =
        taxMode == TaxMode.global ? globalTaxRatePercent : taxRatePercent;
    final taxDivisor = (priceIncludesTax && backOutRatePercent > 0)
        ? (1 + backOutRatePercent / 100)
        : 1.0;
    final lineTotal = displayTotal / taxDivisor;
    return InvoiceLineAmount(
      lineTotal: lineTotal,
      // Back out tax here too, so grossSubtotal (pre-discount subtotal,
      // used whenever any line has a discount) stays on the same taxable
      // basis as subtotal — otherwise mixing inclusive/exclusive items
      // with a discount flips the displayed pre-discount figure between
      // tax-inclusive and tax-exclusive depending on which is shown.
      grossTotal: (price * quantity + extraCost) / taxDivisor,
      discountTotal: discountPerUnit ? discount * quantity : discount,
      taxRatePercent: taxRatePercent,
      displayTotal: displayTotal,
    );
  }

  static InvoiceLineAmount lineFromDbRow(
    Map<String, dynamic> row, {
    TaxMode taxMode = TaxMode.perItem,
    double globalTaxRatePercent = 0,
  }) {
    final price = (row['unit_price'] as num?)?.toDouble() ??
        (row['product_price'] as num?)?.toDouble() ??
        0.0;
    final quantity = (row['quantity'] as num?)?.toDouble() ?? 0.0;
    final discount = (row['discount'] as num?)?.toDouble() ?? 0.0;
    final discountPerUnit = (row['discount_per_unit'] as int?) == 1;
    final metalRateId = row['metal_rate_id'] as String?;
    if (metalRateId != null && metalRateId.isNotEmpty) {
      final treatment = jewelleryTaxTreatmentFromKey(
          row['jewellery_tax_treatment'] as String?);
      // Jewellery weight line: unit_price is the purity-adjusted
      // GST-exclusive sell rate/gram and quantity the net grams. Making and
      // wastage ride on top in the same 3% retail-jewellery tax bucket.
      final metalBase = (discountPerUnit
              ? (price - discount) * quantity
              : price * quantity - discount)
          .clamp(0.0, double.infinity);
      final charges = ((row['making_amount'] as num?)?.toDouble() ?? 0.0) +
          ((row['wastage_amount'] as num?)?.toDouble() ?? 0.0);
      final base = metalBase + charges;
      final split = JewelleryCalculator.frozenLineTaxSplit(
        metalBase: metalBase,
        makingAmount: charges,
        wastageAmount: 0,
        treatment: treatment,
      );
      return InvoiceLineAmount(
        lineTotal: base,
        grossTotal: price * quantity + charges,
        discountTotal: discountPerUnit ? discount * quantity : discount,
        taxRatePercent: jewelleryGstPercent,
        displayTotal: base,
        itemTaxOverride: split.metalTax + split.makingTax,
        useTaxOverrideInGlobal: treatment == JewelleryTaxTreatment.retail3,
      );
    }
    return line(
      price: price,
      quantity: quantity,
      discount: discount,
      discountPerUnit: discountPerUnit,
      extraCost: (row['extra_cost'] as num?)?.toDouble() ?? 0.0,
      taxRatePercent: (row['product_tax_rate'] as num?)?.toDouble() ?? 0.0,
      priceIncludesTax: (row['product_price_includes_tax'] as int?) == 1,
      taxMode: taxMode,
      globalTaxRatePercent: globalTaxRatePercent,
    );
  }

  static InvoiceTotals totals({
    required Iterable<InvoiceLineAmount> lines,
    required TaxMode taxMode,
    required double globalTaxRate,
    TaxRateFormat globalTaxRateFormat = TaxRateFormat.fraction,
    double additionalCostsTotal = 0,
    InvoiceDiscountType invoiceDiscountType = InvoiceDiscountType.percent,
    double invoiceDiscountValue = 0,
  }) {
    double subtotal = 0;
    double grossSubtotal = 0;
    double totalDiscount = 0;
    double itemTax = 0;
    double globalTax = 0;
    final globalRateFraction = globalTaxRateFormat == TaxRateFormat.percent
        ? globalTaxRate / 100
        : globalTaxRate;

    for (final line in lines) {
      subtotal += line.lineTotal;
      grossSubtotal += line.grossTotal;
      totalDiscount += line.discountTotal;
      if (taxMode == TaxMode.perItem) itemTax += line.itemTax;
      if (taxMode == TaxMode.global) {
        globalTax += line.useTaxOverrideInGlobal
            ? line.itemTaxOverride ?? line.lineTotal * globalRateFraction
            : line.lineTotal * globalRateFraction;
      }
    }

    final tax = switch (taxMode) {
      TaxMode.global => globalTax,
      TaxMode.perItem => itemTax,
      TaxMode.none => 0.0,
    };

    final preDiscountTotal = subtotal + tax + additionalCostsTotal;
    final normalizedDiscount = _normalizeInvoiceDiscount(
      type: invoiceDiscountType,
      value: invoiceDiscountValue,
      preDiscountTotal: preDiscountTotal,
    );
    final invoiceDiscountAmount = normalizedDiscount <= 0
        ? 0.0
        : (invoiceDiscountType == InvoiceDiscountType.percent
            ? preDiscountTotal * normalizedDiscount / 100
            : normalizedDiscount);

    return InvoiceTotals(
      subtotal: subtotal,
      grossSubtotal: grossSubtotal,
      totalDiscount: totalDiscount,
      tax: tax,
      additionalCostsTotal: additionalCostsTotal,
      invoiceDiscountAmount: invoiceDiscountAmount,
    );
  }

  /// Stored discounts are untrusted: NaN/Infinity/negative normalize to 0,
  /// percent clamps to 0..100, flat caps at [preDiscountTotal] so totals
  /// can never go negative or NaN from a bad stored value.
  static double _normalizeInvoiceDiscount({
    required InvoiceDiscountType type,
    required double value,
    required double preDiscountTotal,
  }) {
    if (!value.isFinite || value <= 0) return 0.0;
    final pre = (!preDiscountTotal.isFinite || preDiscountTotal < 0)
        ? 0.0
        : preDiscountTotal;
    if (type == InvoiceDiscountType.percent) {
      return value.clamp(0.0, 100.0).toDouble();
    }
    return value.clamp(0.0, pre).toDouble();
  }
}
