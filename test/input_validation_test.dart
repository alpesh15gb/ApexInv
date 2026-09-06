import 'package:flutter_test/flutter_test.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/input_validation.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/purchase_bill.dart';

void main() {
  group('A5a purchase line validation', () {
    test('compute throws on NaN/Infinity/negative/discount> gross', () {
      PurchaseBillItem valid() => PurchaseBillItem.compute(
            id: 'i',
            purchaseBillId: 'b',
            productName: 'Widget',
            quantity: 2,
            rate: 50,
            taxRate: 18,
            discount: 10,
            interState: false,
          );
      expect(valid, returnsNormally);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: double.nan,
                rate: 50,
                taxRate: 18,
                discount: 0,
                interState: false,
              ),
          throwsArgumentError);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: double.infinity,
                rate: 50,
                taxRate: 18,
                discount: 0,
                interState: false,
              ),
          throwsArgumentError);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: -1,
                rate: 50,
                taxRate: 18,
                discount: 0,
                interState: false,
              ),
          throwsArgumentError);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: 1,
                rate: -5,
                taxRate: 18,
                discount: 0,
                interState: false,
              ),
          throwsArgumentError);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: 1,
                rate: 50,
                taxRate: -1,
                discount: 0,
                interState: false,
              ),
          throwsArgumentError);
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: 1,
                rate: 50,
                taxRate: 18,
                discount: -1,
                interState: false,
              ),
          throwsArgumentError);
      // discount 60 > gross 50 → error, never silently clamped.
      expect(
          () => PurchaseBillItem.compute(
                id: 'i',
                purchaseBillId: 'b',
                productName: 'Widget',
                quantity: 1,
                rate: 50,
                taxRate: 18,
                discount: 60,
                interState: false,
              ),
          throwsArgumentError);
      // Shared helper agrees.
      expect(
          InputValidation.validatePurchaseLine(
              quantity: 1, rate: 10, taxRate: 0, discount: 11),
          isNotNull);
      expect(
          InputValidation.validatePurchaseLine(
              quantity: 1, rate: 10, taxRate: 0, discount: 5),
          isNull);
    });
  });

  group('A5b finite-amount guards', () {
    test('tryParseFinite rejects NaN/Infinity/garbage', () {
      expect(InputValidation.tryParseFinite('NaN'), isNull);
      expect(InputValidation.tryParseFinite('Infinity'), isNull);
      expect(InputValidation.tryParseFinite('abc'), isNull);
      expect(InputValidation.tryParseFinite('12.5'), 12.5);
    });

    test('payment validator rejects NaN/Infinity and overpay', () {
      expect(InputValidation.validatePaymentAmount(double.nan, 100), isNotNull);
      expect(InputValidation.validatePaymentAmount(double.infinity, 100),
          isNotNull);
      expect(InputValidation.validatePaymentAmount(-5, 100), isNotNull);
      expect(InputValidation.validatePaymentAmount(0, 100), isNotNull);
      expect(InputValidation.validatePaymentAmount(101, 100), isNotNull);
      expect(InputValidation.validatePaymentAmount(100, 100), isNull);
      expect(InputValidation.validatePaymentAmount(40, 100), isNull);
    });
  });

  group('A5c invoice-level discount normalization', () {
    InvoiceTotals totalsWith(InvoiceDiscountType type, double value) {
      final line = InvoiceTotalsCalculator.line(
        price: 100,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
      );
      return InvoiceTotalsCalculator.totals(
        lines: [line],
        taxMode: TaxMode.none,
        globalTaxRate: 0,
        invoiceDiscountType: type,
        invoiceDiscountValue: value,
      );
    }

    test('percent clamps 0..100', () {
      expect(totalsWith(InvoiceDiscountType.percent, 150).total, 0.0);
      expect(totalsWith(InvoiceDiscountType.percent, -10).total, 100.0);
      expect(
          totalsWith(InvoiceDiscountType.percent, 10).total, closeTo(90, 1e-9));
    });

    test('flat caps at preDiscountTotal, negatives normalize', () {
      expect(totalsWith(InvoiceDiscountType.amount, 500).total, 0.0);
      expect(totalsWith(InvoiceDiscountType.amount, -20).total, 100.0);
      expect(
          totalsWith(InvoiceDiscountType.amount, 30).total, closeTo(70, 1e-9));
    });

    test('NaN discount normalizes to no discount', () {
      expect(totalsWith(InvoiceDiscountType.percent, double.nan).total,
          closeTo(100, 1e-9));
      expect(totalsWith(InvoiceDiscountType.amount, double.infinity).total,
          closeTo(100, 1e-9));
    });

    test('shared normalizer agrees', () {
      expect(
          InputValidation.normalizeInvoiceDiscount(
              type: InvoiceDiscountType.percent,
              value: 150,
              preDiscountTotal: 100),
          100.0);
      expect(
          InputValidation.normalizeInvoiceDiscount(
              type: InvoiceDiscountType.amount,
              value: 500,
              preDiscountTotal: 100),
          100.0);
      expect(
          InputValidation.normalizeInvoiceDiscount(
              type: InvoiceDiscountType.percent,
              value: double.nan,
              preDiscountTotal: 100),
          0.0);
    });
  });
}
