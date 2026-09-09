import 'package:flutter_test/flutter_test.dart';

import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/services/label_printing/label_models.dart';
import 'package:apexbooks/services/label_printing/tspl_builder.dart';
import 'package:apexbooks/services/label_printing/zpl_builder.dart';

Product _product(String id, String name,
        {double price = 250, String barcode = ''}) =>
    Product(
      id: id,
      name: name,
      description: '',
      price: price,
      stock: 5,
      hsncode: '',
      tax_rate: 18,
      barcode: barcode,
    );

void main() {
  const size =
      LabelSize(id: '50x25', label: '50 × 25 mm', widthMm: 50, heightMm: 25);

  test('label code prefers the stored barcode, falls back to id', () {
    expect(LabelItem(product: _product('p1', 'Widget', barcode: '890123')).code,
        '890123');
    expect(LabelItem(product: _product('p1', 'Widget')).code, 'p1');
  });

  test('sanitize strips quotes and non-ascii for printer firmware', () {
    expect(sanitizeLabelText('Say "hi" ₹100'), 'Say \'hi\' 100');
    expect(sanitizeLabelText('  spaced   out  '), 'spaced out');
  });

  test('ZPL job carries name, price, barcode and copies', () {
    const builder = ZplBuilder();
    final job = builder.buildLabels(
      items: [
        LabelItem(product: _product('p1', 'DLink Router', barcode: 'DLINK1')),
      ],
      size: size,
      currencyCode: 'INR',
      showPrice: true,
    );
    expect(job, contains('^XA'));
    expect(job, contains('^XZ'));
    expect(job, contains('DLink Router'));
    expect(job, contains('INR 250.00'));
    expect(job, contains('^FDDLINK1^FS'));
  });

  test('ZPL copies repeat the label block', () {
    const builder = ZplBuilder();
    final job = builder.buildLabels(
      items: [LabelItem(product: _product('p1', 'Widget'), copies: 3)],
      size: size,
      currencyCode: 'INR',
      showPrice: false,
    );
    expect('^XA'.allMatches(job).length, 3);
    expect(job, isNot(contains('INR')));
  });

  test('TSPL job carries setup, content, and copy count', () {
    const builder = TsplBuilder();
    final job = builder.buildLabels(
      items: [
        LabelItem(
            product: _product('p1', 'DLink Router', barcode: 'DLINK1'),
            copies: 2),
      ],
      size: size,
      currencyCode: 'INR',
      showPrice: true,
    );
    expect(job, contains('SIZE 50'));
    expect(job, contains('CLS'));
    expect(job, contains('DLink Router'));
    expect(job, contains('INR 250.00'));
    expect(job, contains('BARCODE'));
    expect(job, contains('PRINT 2,1'));
  });

  test('design toggles control ZPL content', () {
    const builder = ZplBuilder();
    const design =
        LabelDesign(showName: false, showPrice: false, showBarcodeText: false);
    final job = builder.buildLabels(
      items: [LabelItem(product: _product('p1', 'Widget', barcode: 'W1'))],
      size: size,
      currencyCode: 'INR',
      showPrice: true,
      design: design,
    );
    expect(job, isNot(contains('Widget')));
    expect(job, isNot(contains('INR')));
    expect(job, contains('^BCN,'));
    expect(job, contains(',N,N'));
  });

  test('design toggles control TSPL content', () {
    const builder = TsplBuilder();
    const design =
        LabelDesign(showName: false, showPrice: false, showBarcodeText: false);
    final job = builder.buildLabels(
      items: [LabelItem(product: _product('p1', 'Widget', barcode: 'W1'))],
      size: size,
      currencyCode: 'INR',
      showPrice: true,
      design: design,
    );
    expect(job, isNot(contains('Widget')));
    expect(job, isNot(contains('INR')));
    expect(job, contains('"128",'));
    expect(job, contains(',0,0,2,2,'));
  });

  test('custom sizes parse from settings keys', () {
    final custom = LabelSize.fromId('custom:60x40');
    expect(custom.isCustom, isTrue);
    expect(custom.widthMm, 60);
    expect(custom.heightMm, 40);
    expect(LabelSize.fromId('bogus'), LabelSize.presets.first);
    expect(LabelSize.fromId('custom:5x5'), LabelSize.presets.first);
  });

  test('connection round-trips through json', () {
    const connection =
        LabelPrinterConnection(kind: 'network', ip: '192.168.1.50', port: 9100);
    final restored = LabelPrinterConnection.fromJson(connection.toJson());
    expect(restored?.kind, 'network');
    expect(restored?.ip, '192.168.1.50');
    expect(restored?.port, 9100);
    expect(restored?.isConfigured, isTrue);
    expect(const LabelPrinterConnection(kind: 'usb').isConfigured, isFalse);
  });

  test('tag price uses the frozen retail sell rate, not buyback rate', () {
    final tag = TagLabelItem(
      product: _product('p1', 'Chain', barcode: 'TAG1'),
      attributes: const JewelleryAttributes(
        productId: 'p1',
        metal: 'gold',
        purity: '22K',
        grossWeight: 10,
        stoneWeight: 2,
        netWeight: 8,
        makingType: 'fixed',
        makingValue: 500,
        wastagePercent: 5,
      ),
      rate: MetalRate.create(
          metal: 'gold',
          purity: '22K',
          sellRatePerGram: 5000,
          buyRatePerGram: 4500,
          effectiveDate: DateTime(2026, 9, 9)),
    );
    // net = stored 8g; metal = 8 × 5000 = 40000 (purity-specific rate)
    expect(tag.netWeight, 8);
    expect(tag.price, closeTo(40000 + 2000 + 500, 0.01));
    expect(tag.code, 'TAG1');
  });

  test('tag jobs print purity, weight and price in both languages', () {
    final tag = TagLabelItem(
      product: _product('p1', 'Chain', barcode: 'TAG1'),
      attributes: const JewelleryAttributes(
          productId: 'p1', metal: 'gold', purity: '22K', netWeight: 8),
      rate: MetalRate.create(
          metal: 'gold',
          purity: '22K',
          sellRatePerGram: 5000,
          buyRatePerGram: 4500,
          effectiveDate: DateTime(2026, 9, 9)),
    );
    const zpl = ZplBuilder();
    final zplJob =
        zpl.buildTagLabels(items: [tag], size: size, currencyCode: 'INR');
    expect(zplJob, contains('Chain'));
    expect(zplJob, contains('Gold 22K 8.00 g'));
    // Printer labels show metal value from the frozen purity-specific rate:
    // 8 × 5000 = 40000 (making/wastage are not printed on the tag).
    expect(zplJob, contains('INR 40000.00'));
    expect(zplJob, contains('^FDTAG1^FS'));

    const tspl = TsplBuilder();
    final tsplJob =
        tspl.buildTagLabels(items: [tag], size: size, currencyCode: 'INR');
    expect(tsplJob, contains('Gold 22K 8.00 g'));
    expect(tsplJob, contains('INR 40000.00'));
    expect(tsplJob, contains('PRINT 1,1'));
  });

  test('tag price uses the purity-specific rate like invoice lines', () {
    // Rate board stores a rate per purity: no further purity conversion
    // (BUG-05 — the factor was applied twice and undercharged 22K lines).
    final tag = TagLabelItem(
      product: _product('p2', 'Ring'),
      attributes: const JewelleryAttributes(
          productId: 'p2', metal: 'gold', purity: '916', netWeight: 4),
      rate: MetalRate.create(
          metal: 'gold',
          purity: '916',
          sellRatePerGram: 5000,
          buyRatePerGram: 4500,
          effectiveDate: DateTime(2026, 9, 9)),
    );
    expect(purityFactor('916'), 0.916);
    expect(tag.price, closeTo(4 * 5000, 0.01));
  });
}
