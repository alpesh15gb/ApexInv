import 'package:uuid/uuid.dart';

import 'package:apexbooks/models/product.dart';

import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';

class InvoiceItem {
  String id;
  Product product;
  double quantity;
  double discount;
  double? unitPrice; // overrides product.price when set
  double? extraCost; // optional flat fee added on top of the line total
  String? unit; // overrides product.unit when set
  String? description; // optional per-line note typed on the invoice
  bool
      discountPerUnit; // true  → (price − discount) × qty  (discount multiplied by qty)
  // false → (price × qty) − discount   (flat discount off line total)
  bool
      isProductSaved; // true → custom item was saved to product list; hides the save button

  // Jewellery weight billing (retail.md P1). Non-null [metalRateId] marks a
  // line billed by weight: [quantity] holds net grams, [unitPrice] the
  // purity-adjusted rate/gram (GST-exclusive), and making/wastage the frozen
  // rupee amounts. All null/empty ⇒ ordinary retail line. [jewelleryPieceId]
  // (P2) links the line to the tagged piece it sold.
  String? metalRateId;
  double? netWeight;
  double? makingAmount;
  double? wastageAmount;
  String? jewelleryPieceId;
  JewelleryTaxTreatment jewelleryTaxTreatment;

  // Immutable piece-identity snapshot captured at time of sale (HIGH-07 fix).
  // Preserves HUID, tag number, purity, and gross weight so printed invoices
  // remain accurate even if the catalog piece is later edited or deleted.
  String? huidSnapshot;
  String? tagNoSnapshot;
  String? puritySnapshot;
  double? grossWeightSnapshot;

  // Variant snapshot for retail lines (HIGH-02 fix). Captures which variant
  // was selected so invoices can identify and audit the specific variant sold.
  String? variantSnapshotId;
  String? variantSnapshotName;

  InvoiceItem({
    String? id,
    required this.product,
    required this.quantity, // supports decimals (e.g. 1.5 hrs)
    this.discount = 0.0,
    this.unitPrice,
    this.extraCost,
    this.unit,
    this.description,
    this.discountPerUnit = false,
    this.isProductSaved = false,
    this.metalRateId,
    this.netWeight,
    this.makingAmount,
    this.wastageAmount,
    this.jewelleryPieceId,
    this.jewelleryTaxTreatment = JewelleryTaxTreatment.retail3,
    this.huidSnapshot,
    this.tagNoSnapshot,
    this.puritySnapshot,
    this.grossWeightSnapshot,
    this.variantSnapshotId,
    this.variantSnapshotName,
  }) : id = id ?? const Uuid().v4();

  double get effectivePrice => unitPrice ?? product.price;

  String get effectiveUnit => unit ?? product.unit;

  String get effectiveDescription => (description ?? '').trim();

  bool get isJewelleryLine => metalRateId != null;

  /// Metal value after the line discount, GST-exclusive. Uses the same
  /// discount semantics as the generic line, applied to the metal part only
  /// (making/wastage are never discounted).
  double get jewelleryMetalBase => (discountPerUnit
          ? (effectivePrice - discount) * quantity
          : effectivePrice * quantity - discount)
      .clamp(0.0, double.infinity);

  double get jewelleryCharges => (makingAmount ?? 0.0) + (wastageAmount ?? 0.0);

  /// GST-exclusive line base for a weight-billed line.
  double get jewelleryLineBase => jewelleryMetalBase + jewelleryCharges;

  /// What prints on an invoice (A4 + thermal): the per-line note if the user
  /// typed one, otherwise the product's own snapshotted description. Only
  /// rendered when the "Show Product Description" setting is on. Kept out of
  /// [effectiveDescription] so the edit field is never seeded from the
  /// product.
  String get printedDescription => effectiveDescription.isNotEmpty
      ? effectiveDescription
      : product.description.trim();

  InvoiceLineAmount get _amounts {
    if (isJewelleryLine) {
      final split = JewelleryCalculator.frozenLineTaxSplit(
        metalBase: jewelleryMetalBase,
        makingAmount: makingAmount ?? 0.0,
        wastageAmount: wastageAmount ?? 0.0,
        treatment: jewelleryTaxTreatment,
      );
      final base = jewelleryLineBase;
      return InvoiceLineAmount(
        lineTotal: base,
        grossTotal: effectivePrice * quantity + jewelleryCharges,
        discountTotal: discountPerUnit ? discount * quantity : discount,
        taxRatePercent: jewelleryGstPercent,
        displayTotal: base,
        itemTaxOverride: split.metalTax + split.makingTax,
        useTaxOverrideInGlobal:
            jewelleryTaxTreatment == JewelleryTaxTreatment.retail3,
      );
    }
    return InvoiceTotalsCalculator.line(
      price: effectivePrice,
      quantity: quantity,
      discount: discount,
      discountPerUnit: discountPerUnit,
      extraCost: extraCost ?? 0.0,
      taxRatePercent: product.tax_rate.toDouble(),
      priceIncludesTax: product.priceIncludesTax,
    );
  }

  /// Public view of the line's GST-exclusive/inclusive amounts so callers
  /// (editor totals, PDF) can reuse the same math instead of recomputing.
  InvoiceLineAmount get lineAmounts => _amounts;

  double get grossPrice => _amounts.grossTotal;

  double get totalDiscount => _amounts.discountTotal;

  double get total => _amounts.displayTotal;

  /// Line GST: 3% on a weight-billed retail jewellery line (sell rates are
  /// GST-exclusive), or the product's own rate otherwise.
  double get taxAmount => _amounts.itemTax;

  /// (metalTax, makingTax) for rate-wise reporting; both 0 on retail lines.
  ({double metalTax, double makingTax}) get jewelleryTaxSplit => isJewelleryLine
      ? JewelleryCalculator.frozenLineTaxSplit(
          metalBase: jewelleryMetalBase,
          makingAmount: makingAmount ?? 0.0,
          wastageAmount: wastageAmount ?? 0.0,
          treatment: jewelleryTaxTreatment,
        )
      : (metalTax: 0.0, makingTax: 0.0);
}
