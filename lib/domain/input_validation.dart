import 'package:apexbooks/common/common.dart';

/// Shared finite-number input guards.
///
/// `double.tryParse` returns NaN for inputs like "NaN", and NaN passes every
/// `<` / `>` / `<=` comparison as false — so validators written as
/// `n == null || n <= 0` silently accept NaN/Infinity. Every amount entry
/// point must check [isFinite] explicitly.
class InputValidation {
  const InputValidation._();

  /// Parses [raw] and returns null when unparseable or non-finite
  /// (NaN/Infinity). Use for all user-typed amounts.
  static double? tryParseFinite(String? raw) {
    if (raw == null) return null;
    final v = double.tryParse(raw.trim());
    if (v == null || !v.isFinite) return null;
    return v;
  }

  /// True only for finite numbers (rejects null/NaN/Infinity).
  static bool isFiniteAmount(double? v) => v != null && v.isFinite;

  /// Validates a purchase-bill line. Returns an error message, or null when
  /// valid. Never clamps — callers must reject on non-null.
  static String? validatePurchaseLine({
    required double quantity,
    required double rate,
    required double taxRate,
    required double discount,
  }) {
    if (!quantity.isFinite ||
        !rate.isFinite ||
        !taxRate.isFinite ||
        !discount.isFinite) {
      return 'Quantity, rate, tax and discount must be finite numbers';
    }
    if (quantity <= 0) return 'Quantity must be greater than zero';
    if (rate < 0) return 'Rate cannot be negative';
    if (taxRate < 0) return 'Tax cannot be negative';
    if (discount < 0) return 'Discount cannot be negative';
    final gross = quantity * rate;
    if (!gross.isFinite) return 'Quantity × rate is not a finite amount';
    if (discount > gross) return 'Discount cannot exceed quantity × rate';
    return null;
  }

  /// Validates a payment/allocation amount against [outstanding].
  /// Returns an error message, or null when valid.
  static String? validatePaymentAmount(
    double? amount,
    double outstanding, {
    double epsilon = 0.005,
  }) {
    if (amount == null || !amount.isFinite) {
      return 'Enter a valid amount';
    }
    if (amount <= 0) return 'Enter an amount greater than zero';
    if (!outstanding.isFinite) return 'Outstanding balance is invalid';
    if (amount > outstanding + epsilon) {
      return 'Amount exceeds the outstanding balance';
    }
    return null;
  }

  /// Normalizes a stored invoice-level discount before it feeds totals:
  /// non-finite/negative → 0, percent clamped to 0..100, flat capped at
  /// [preDiscountTotal]. Centralizes the rule so over-100% or negative
  /// stored values can never inflate or negate a total.
  static double normalizeInvoiceDiscount({
    required InvoiceDiscountType type,
    required double value,
    required double preDiscountTotal,
  }) {
    if (!value.isFinite) return 0.0;
    if (value <= 0) return 0.0;
    final pre = (!preDiscountTotal.isFinite || preDiscountTotal < 0)
        ? 0.0
        : preDiscountTotal;
    if (type == InvoiceDiscountType.percent) {
      return value.clamp(0.0, 100.0).toDouble();
    }
    return value.clamp(0.0, pre).toDouble();
  }
}
