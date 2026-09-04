import 'package:flutter_test/flutter_test.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/additional_cost.dart';

void main() {
  group('GSTR global-mode rate application', () {
    test('global mode ignores per-line product rates for tax', () {
      // Two lines with diverging product rates; global rate is 18%.
      final a = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 5,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      final b = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 28,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      // lineTotal is the taxable base (exclusive prices stay as-is).
      expect(a.lineTotal, 1000);
      expect(b.lineTotal, 1000);

      final totals = InvoiceTotalsCalculator.totals(
        lines: [a, b],
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      // subtotal 2000 * 18% = 360, NOT 5% + 28% = 330.
      expect(totals.subtotal, 2000);
      expect(totals.tax, closeTo(360, 1e-9));
      expect(totals.total, closeTo(2360, 1e-9));

      // Per-item mode would give a different answer (control case).
      final pa = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 5,
        taxMode: TaxMode.perItem,
      );
      final pb = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 28,
        taxMode: TaxMode.perItem,
      );
      final perItemTotals = InvoiceTotalsCalculator.totals(
        lines: [pa, pb],
        taxMode: TaxMode.perItem,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      expect(perItemTotals.tax, closeTo(330, 1e-9));
    });

    test('inclusive prices back out using global rate, not product rate', () {
      // Display price 1180 includes 18% global tax; product row claims 5%.
      final line = InvoiceTotalsCalculator.line(
        price: 1180,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 5,
        priceIncludesTax: true,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      // 1180 / 1.18 = 1000.
      expect(line.lineTotal, closeTo(1000, 1e-6));
      // Backing out with the (wrong) 5% product rate would give ~1123.8.
      expect(line.lineTotal, isNot(closeTo(1123.8, 1.0)));

      // lineFromDbRow honours the same rule.
      final dbRow = {
        'unit_price': 1180.0,
        'quantity': 1.0,
        'discount': 0.0,
        'discount_per_unit': 0,
        'extra_cost': 0.0,
        'product_tax_rate': 5,
        'product_price_includes_tax': 1,
      };
      final fromDb = InvoiceTotalsCalculator.lineFromDbRow(
        dbRow,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      expect(fromDb.lineTotal, closeTo(1000, 1e-6));
    });

    test('global line taxable share scales with subtotal proportion', () {
      final a = InvoiceTotalsCalculator.line(
        price: 300,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 12,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      final b = InvoiceTotalsCalculator.line(
        price: 700,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 28,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      final totals = InvoiceTotalsCalculator.totals(
        lines: [a, b],
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      // GSTR rule: line tax = share * globalRate == lineTotal * globalRate.
      final taxA = a.lineTotal * 0.18;
      final taxB = b.lineTotal * 0.18;
      expect(taxA, closeTo(54, 1e-9));
      expect(taxB, closeTo(126, 1e-9));
      expect(totals.tax, closeTo(taxA + taxB, 1e-9));
    });
  });

  group('GSTR invoice value computation', () {
    test('invoice value is computed total, not a stored column', () {
      final lines = [
        InvoiceTotalsCalculator.line(
          price: 50000,
          quantity: 5,
          discount: 0,
          discountPerUnit: false,
          taxRatePercent: 18,
          taxMode: TaxMode.global,
          globalTaxRatePercent: 18,
        ),
      ];
      final totals = InvoiceTotalsCalculator.totals(
        lines: lines,
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      // subtotal 250000, tax 45000, total 295000 -> B2CL threshold trips.
      expect(totals.subtotal, 250000);
      expect(totals.tax, closeTo(45000, 1e-6));
      expect(totals.total, closeTo(295000, 1e-6));
      expect(totals.total > 250000, isTrue);
    });

    test('small invoice stays below B2CL threshold', () {
      final lines = [
        InvoiceTotalsCalculator.line(
          price: 1000,
          quantity: 2,
          discount: 0,
          discountPerUnit: false,
          taxRatePercent: 18,
          taxMode: TaxMode.global,
          globalTaxRatePercent: 18,
        ),
      ];
      final totals = InvoiceTotalsCalculator.totals(
        lines: lines,
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
      );
      expect(totals.total, closeTo(2360, 1e-9));
      expect(totals.total > 250000, isFalse);
    });
  });

  group('GSTR discount and additional-cost handling', () {
    test('additional costs raise total untaxed; ledger net = total - tax', () {
      final lines = [
        InvoiceTotalsCalculator.line(
          price: 1000,
          quantity: 1,
          discount: 0,
          discountPerUnit: false,
          taxRatePercent: 18,
          taxMode: TaxMode.perItem,
        ),
      ];
      final addCosts =
          AdditionalCost.listFromJson('[{"label":"Shipping","amount":100}]');
      final addTotal = addCosts.fold(0.0, (s, c) => s + c.amount);
      expect(addTotal, 100);

      final totals = InvoiceTotalsCalculator.totals(
        lines: lines,
        taxMode: TaxMode.perItem,
        globalTaxRate: 0,
        additionalCostsTotal: addTotal,
      );
      // subtotal 1000, tax 180, +100 shipping = 1280.
      expect(totals.total, closeTo(1280, 1e-9));
      final net = totals.total - totals.tax;
      expect(net, closeTo(1100, 1e-9));
      // net = subtotal + additional (discount 0).
      expect(net, closeTo(totals.subtotal + addTotal, 1e-9));
    });

    test('percent invoice discount reduces taxable proportionally', () {
      final a = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 5,
        taxMode: TaxMode.perItem,
      );
      final b = InvoiceTotalsCalculator.line(
        price: 1000,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 18,
        taxMode: TaxMode.perItem,
      );
      final totals = InvoiceTotalsCalculator.totals(
        lines: [a, b],
        taxMode: TaxMode.perItem,
        globalTaxRate: 0,
        invoiceDiscountType: InvoiceDiscountType.percent,
        invoiceDiscountValue: 10,
      );
      // pre-discount = 2000 + 230 = 2230; 10% off = 223 discount.
      expect(totals.invoiceDiscountAmount, closeTo(223, 1e-9));
      expect(totals.total, closeTo(2007, 1e-9));
      final net = totals.total - totals.tax;
      // net absorbs the full discount: 2000 - 223 = 1777.
      expect(net, closeTo(1777, 1e-9));

      // GSTR allocation: rate-wise taxable scaled by net/subtotal.
      final subtotal = 2000.0;
      final factor = net / subtotal;
      final adjA = a.lineTotal * factor;
      final adjB = b.lineTotal * factor;
      expect(adjA + adjB, closeTo(net, 1e-9));
      // Tax itself is NOT rescaled by the discount.
      expect(totals.tax, closeTo(a.itemTax + b.itemTax, 1e-9));
    });

    test('amount discount + additional costs combine in global mode', () {
      final lines = [
        InvoiceTotalsCalculator.line(
          price: 1000,
          quantity: 2,
          discount: 0,
          discountPerUnit: false,
          taxRatePercent: 28, // ignored in global mode
          taxMode: TaxMode.global,
          globalTaxRatePercent: 12,
        ),
      ];
      final totals = InvoiceTotalsCalculator.totals(
        lines: lines,
        taxMode: TaxMode.global,
        globalTaxRate: 0.12,
        globalTaxRateFormat: TaxRateFormat.fraction,
        additionalCostsTotal: 200,
        invoiceDiscountType: InvoiceDiscountType.amount,
        invoiceDiscountValue: 100,
      );
      // subtotal 2000, tax 240, +200 -100 = 2340.
      expect(totals.subtotal, 2000);
      expect(totals.tax, closeTo(240, 1e-9));
      expect(totals.total, closeTo(2340, 1e-9));
      final net = totals.total - totals.tax;
      expect(net, closeTo(2100, 1e-9));
      // Single global bucket holds the whole net.
      final factor = net / totals.subtotal;
      expect(lines.first.lineTotal * factor, closeTo(net, 1e-9));
    });

    test('inclusive global lines keep ledger identity with discount', () {
      final line = InvoiceTotalsCalculator.line(
        price: 1180,
        quantity: 1,
        discount: 0,
        discountPerUnit: false,
        taxRatePercent: 5, // ignored
        priceIncludesTax: true,
        taxMode: TaxMode.global,
        globalTaxRatePercent: 18,
      );
      expect(line.lineTotal, closeTo(1000, 1e-6));
      final totals = InvoiceTotalsCalculator.totals(
        lines: [line],
        taxMode: TaxMode.global,
        globalTaxRate: 0.18,
        globalTaxRateFormat: TaxRateFormat.fraction,
        invoiceDiscountType: InvoiceDiscountType.percent,
        invoiceDiscountValue: 10,
      );
      // pre = 1000 + 180 = 1180; 10% = 118; total 1062; net 882.
      expect(totals.total, closeTo(1062, 1e-6));
      expect(totals.total - totals.tax, closeTo(882, 1e-6));
    });
  });
}
