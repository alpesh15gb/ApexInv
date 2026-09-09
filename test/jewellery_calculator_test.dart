import 'package:flutter_test/flutter_test.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';

void main() {
  test('purity factors map karat marks to fine-gold fractions', () {
    expect(purityFactor('24K'), 1.0);
    expect(purityFactor('999'), 1.0);
    expect(purityFactor('22K'), 0.916);
    expect(purityFactor('916'), 0.916);
    expect(purityFactor('18K'), 0.75);
    expect(purityFactor('14K'), 0.585);
    expect(purityFactor('925'), 0.925);
    expect(purityFactor('unknown'), 1.0);
  });

  test('net weight is gross minus stone, never negative', () {
    expect(JewelleryCalculator.netWeight(10, 2), 8);
    expect(JewelleryCalculator.netWeight(2, 5), 0);
  });

  test('making amount follows fixed / per-gram / percent modes', () {
    expect(
        JewelleryCalculator.makingAmount(
            makingType: MakingType.fixed,
            makingValue: 500,
            netWeight: 8,
            metalValue: 40000),
        500);
    expect(
        JewelleryCalculator.makingAmount(
            makingType: MakingType.perGram,
            makingValue: 100,
            netWeight: 8,
            metalValue: 40000),
        800);
    expect(
        JewelleryCalculator.makingAmount(
            makingType: MakingType.percent,
            makingValue: 10,
            netWeight: 8,
            metalValue: 40000),
        4000);
  });

  test('22K retail line applies 3% GST to the complete jewellery value', () {
    // 10g gross, 2g stones → 8g net; 22K @ ₹5000/g purity-specific rate.
    final line = JewelleryCalculator.line(
      grossWeight: 10,
      stoneWeight: 2,
      purity: '22K',
      ratePerGram: 5000,
      makingType: MakingType.percent,
      makingValue: 10,
      wastagePercent: 5,
    );
    // metal = 8 × 5000 = 40000 (rate is already purity-adjusted, BUG-05)
    expect(line.metalValue, closeTo(40000, 0.01));
    // wastage = 5% of metal = 2000
    expect(line.wastageAmount, closeTo(2000, 0.01));
    // making = 10% of metal = 4000
    expect(line.makingAmount, closeTo(4000, 0.01));
    // Retail jewellery GST is 3% of metal + making + wastage.
    expect(line.metalTax, closeTo(1380, 0.01));
    expect(line.makingTax, 0);
    expect(line.lineBase, closeTo(40000 + 2000 + 4000, 0.01));
    expect(line.lineTotal, closeTo(line.lineBase + 1380, 0.01));
  });

  test('zero weights produce a zero line, never NaN', () {
    final line = JewelleryCalculator.line(
      grossWeight: 0,
      stoneWeight: 0,
      purity: '22K',
      ratePerGram: 5000,
      makingType: MakingType.fixed,
      makingValue: 0,
      wastagePercent: 0,
    );
    expect(line.lineBase, 0);
    expect(line.lineTax, 0);
    expect(line.lineTotal, 0);
  });

  test('frozen line tax keeps all retail jewellery value in the 3% bucket', () {
    // A stored line: 8g net at a purity-adjusted ₹4580/g (=5000 × 0.916),
    // ₹3664 making, ₹1832 wastage.
    final split = JewelleryCalculator.frozenLineTaxSplit(
      metalBase: 8 * 4580,
      makingAmount: 3664,
      wastageAmount: 1832,
    );
    expect(split.metalTax, closeTo((36640 + 3664 + 1832) * 0.03, 0.01));
    expect(split.makingTax, 0);
  });

  test('lineFromDbRow uses 3% GST for stored retail jewellery rows', () {
    final amount = InvoiceTotalsCalculator.lineFromDbRow({
      'unit_price': 4580.0,
      'quantity': 8.0,
      'discount': 0.0,
      'discount_per_unit': 0,
      'metal_rate_id': 'rate-1',
      'making_amount': 3664.0,
      'wastage_amount': 1832.0,
      'product_tax_rate': 3,
      'product_price_includes_tax': 0,
      'extra_cost': 50.0,
    });
    expect(amount.lineTotal, closeTo(36640 + 3664 + 1832, 0.01));
    expect(amount.itemTax, closeTo((36640 + 3664 + 1832) * 0.03, 0.01));
    // A retail row with the same product keeps its own rate.
    final retail = InvoiceTotalsCalculator.lineFromDbRow({
      'unit_price': 100.0,
      'quantity': 2.0,
      'discount': 0.0,
      'discount_per_unit': 0,
      'product_tax_rate': 18,
      'product_price_includes_tax': 0,
    });
    expect(retail.itemTax, closeTo(36, 0.001));
    expect(retail.itemTaxOverride, isNull);
  });

  test('global tax keeps retail jewellery in its 3% tax bucket', () {
    final jewellery = InvoiceTotalsCalculator.lineFromDbRow({
      'unit_price': 100.0,
      'quantity': 10.0,
      'discount': 0.0,
      'discount_per_unit': 0,
      'metal_rate_id': 'rate-1',
      'making_amount': 0.0,
      'wastage_amount': 0.0,
    });
    final retail = InvoiceTotalsCalculator.line(
      price: 1000,
      quantity: 1,
      discount: 0,
      discountPerUnit: false,
    );
    final totals = InvoiceTotalsCalculator.totals(
      lines: [jewellery, retail],
      taxMode: TaxMode.global,
      globalTaxRate: 0.18,
    );
    expect(totals.tax, closeTo(1000 * 0.03 + 1000 * 0.18, 0.01));
  });

  test('legacy jewellery rows retain their issued tax treatment', () {
    final legacy = InvoiceTotalsCalculator.lineFromDbRow({
      'unit_price': 100.0,
      'quantity': 10.0,
      'discount': 0.0,
      'discount_per_unit': 0,
      'metal_rate_id': 'rate-1',
      'making_amount': 100.0,
      'wastage_amount': 100.0,
      'jewellery_tax_treatment': 'legacy_split',
    });
    expect(legacy.itemTax, closeTo(1000 * 0.03 + 200 * 0.05, 0.01));
    final global = InvoiceTotalsCalculator.totals(
      lines: [legacy],
      taxMode: TaxMode.global,
      globalTaxRate: 0.18,
    );
    // Legacy global invoices used the document-level rate before this fix.
    expect(global.tax, closeTo(1200 * 0.18, 0.01));
  });

  test('InvoiceItem jewellery line totals apply 3% like the calculator', () {
    final product = _product(priceIncludesTax: false, taxRate: 3);
    // quantity = net grams, unitPrice = purity-adjusted rate/gram.
    final item = InvoiceItem(
      product: product,
      quantity: 8,
      unitPrice: 4580,
      metalRateId: 'rate-1',
      netWeight: 8,
      makingAmount: 3664,
      wastageAmount: 1832,
    );
    expect(item.isJewelleryLine, isTrue);
    expect(item.jewelleryMetalBase, closeTo(36640, 0.01));
    expect(item.jewelleryLineBase, closeTo(36640 + 3664 + 1832, 0.01));
    expect(item.taxAmount, closeTo(42136 * 0.03, 0.01));
    expect(item.total, closeTo(42136, 0.01));
    final s = item.jewelleryTaxSplit;
    expect(s.metalTax, closeTo(42136 * 0.03, 0.01));
    expect(s.makingTax, 0);
  });

  test('InvoiceItem jewellery line applies 3% after its metal discount', () {
    final product = _product(priceIncludesTax: false, taxRate: 3);
    final item = InvoiceItem(
      product: product,
      quantity: 8,
      unitPrice: 4580,
      discount: 1000,
      metalRateId: 'rate-1',
      netWeight: 8,
      makingAmount: 3664,
      wastageAmount: 1832,
    );
    expect(item.jewelleryMetalBase, closeTo(35640, 0.01));
    expect(item.jewelleryLineBase, closeTo(35640 + 3664 + 1832, 0.01));
    expect(item.taxAmount, closeTo((35640 + 5496) * 0.03, 0.01));
  });

  test('plain retail line is unaffected by jewellery fields', () {
    final product = _product(priceIncludesTax: false, taxRate: 18);
    final item = InvoiceItem(product: product, quantity: 2, unitPrice: 500);
    expect(item.isJewelleryLine, isFalse);
    expect(item.total, 1000);
    expect(item.taxAmount, 180);
    expect(item.jewelleryTaxSplit.metalTax, 0);
    expect(item.jewelleryTaxSplit.makingTax, 0);
  });
}

Product _product({required bool priceIncludesTax, required int taxRate}) =>
    Product(
      id: 'p1',
      name: 'Chain',
      description: '',
      price: 4580,
      tax_rate: taxRate,
      stock: 100,
      hsncode: '7113',
      priceIncludesTax: priceIncludesTax,
    );
