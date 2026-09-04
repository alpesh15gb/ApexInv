import 'package:flutter_test/flutter_test.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/customer_identity.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/domain/payment_receipt_numbers.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'package:apexbooks/utils/formatters.dart';

void main() {
  group('InvoiceTotalsCalculator', () {
    test('calculates line totals with flat and per-unit discounts', () {
      final flat = InvoiceTotalsCalculator.line(
        price: 100,
        quantity: 2,
        discount: 15,
        discountPerUnit: false,
        extraCost: 5,
        taxRatePercent: 10,
      );
      expect(flat.grossTotal, 205);
      expect(flat.discountTotal, 15);
      expect(flat.lineTotal, 190);
      expect(flat.itemTax, 19);

      final perUnit = InvoiceTotalsCalculator.line(
        price: 100,
        quantity: 2,
        discount: 15,
        discountPerUnit: true,
        extraCost: 5,
      );
      expect(perUnit.discountTotal, 30);
      expect(perUnit.lineTotal, 175);
    });

    test('backs tax out of inclusive prices without changing totals', () {
      final inclusive = InvoiceTotalsCalculator.line(
        price: 118,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 18,
        priceIncludesTax: true,
      );
      final exclusive = InvoiceTotalsCalculator.line(
        price: 100,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 18,
      );

      expect(inclusive.displayTotal, 118);
      expect(inclusive.lineTotal, closeTo(100, 0.001));
      expect(inclusive.itemTax, closeTo(18, 0.001));
      expect(inclusive.lineTotal, closeTo(exclusive.lineTotal, 0.001));
      expect(inclusive.itemTax, closeTo(exclusive.itemTax, 0.001));
      expect(
          InvoiceTotalsCalculator.netPrice(
              price: 118, taxRatePercent: 18, priceIncludesTax: true),
          closeTo(100, 0.001));
    });

    test('keeps fraction and percent global tax rates explicit', () {
      final line = InvoiceTotalsCalculator.line(
        price: 100,
        quantity: 2,
        discount: 0,
        discountPerUnit: false,
      );

      final uiTotals = InvoiceTotalsCalculator.totals(
        lines: [line],
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      final dbTotals = InvoiceTotalsCalculator.totals(
        lines: [line],
        taxMode: TaxMode.global,
        globalTaxRate: 18,
        globalTaxRateFormat: TaxRateFormat.percent,
      );

      expect(uiTotals.tax, 36);
      expect(dbTotals.tax, 36);
    });
  });

  group('PaymentReceiptNumbers', () {
    test('uses the highest existing suffix', () {
      expect(
        PaymentReceiptNumbers.nextReceiptNumber(
          invoiceId: 'INV-7',
          existingReceiptNumbers: ['INV-7-R1', 'INV-7-R9', 'bad'],
        ),
        'INV-7-R10',
      );
    });
  });

  group('CustomerIdentity', () {
    test('prefers stable id and falls back to displayable name', () {
      expect(CustomerIdentity.key(id: ' C-1 ', name: 'Acme'), 'C-1');
      expect(CustomerIdentity.key(id: '', name: ' Acme '), 'Acme');
      expect(CustomerIdentity.displayName('  '), CustomerIdentity.unknownName);
    });
  });

  group('AppDate', () {
    test('creates stable date-only keys without timestamp splitting', () {
      expect(AppDate.dateKey(DateTime(2026, 5, 3, 14, 20)), '2026-05-03');
    });
  });

  group('buildQuotedCsv', () {
    test('quotes every cell and escapes quotes', () {
      expect(
        buildQuotedCsv([
          ['Name', 'Notes'],
          ['A, B', 'He said "paid"'],
        ]),
        '"Name","Notes"\n"A, B","He said ""paid"""',
      );
    });
  });
}
