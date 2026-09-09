import 'package:apexbooks/models/metal_rate.dart';

import 'label_models.dart';

// Re-exported for callers building tag jobs from the service facade.
export 'label_models.dart' show TagLabelItem;

/// Builds TSPL label jobs for TSC printers (203 dpi).
///
/// Layout per label: product name, optional price line, Code 128 barcode
/// with human-readable text. One `PRINT n,1` per product honors [copies].
class TsplBuilder {
  const TsplBuilder();

  String buildLabels({
    required List<LabelItem> items,
    required LabelSize size,
    required String currencyCode,
    bool showPrice = true,
    LabelDesign design = const LabelDesign(),
    double gapMm = 3,
  }) {
    final buffer = StringBuffer();
    for (final item in items) {
      final copies = item.copies < 1 ? 1 : item.copies;
      buffer.write(_label(
        name: design.showName ? item.product.name : '',
        price: (showPrice && design.showPrice)
            ? '$currencyCode ${item.product.price.toStringAsFixed(2)}'
            : '',
        code: item.code,
        size: size,
        design: design,
        gapMm: gapMm,
        copies: copies,
      ));
    }
    return buffer.toString();
  }

  /// Jewellery tag labels (retail.md P1): name, purity + net weight, price
  /// at the frozen rate, and a short Code 128 tag barcode.
  String buildTagLabels({
    required List<TagLabelItem> items,
    required LabelSize size,
    required String currencyCode,
    double gapMm = 3,
  }) {
    const eol = '\r\n';
    final buffer = StringBuffer();
    for (final item in items) {
      final copies = item.copies < 1 ? 1 : item.copies;
      final s = (size.heightDots / 200).clamp(0.6, 3.0);
      final margin = (16 * s).round();
      var y = (10 * s).round();
      final attr = item.attributes;
      final detail =
          '${MetalRate.metalLabel(attr.metal)} ${attr.purity} · ${item.netWeight.toStringAsFixed(2)} g';
      final price = '$currencyCode ${item.price.toStringAsFixed(2)}';
      buffer
        ..write('SIZE ${size.widthMm} mm, ${size.heightMm} mm$eol')
        ..write('GAP $gapMm mm, 0 mm$eol')
        ..write('DIRECTION 1$eol')
        ..write('CLS$eol')
        ..write('TEXT $margin,$y,"3",0,1,1,'
            '"${sanitizeLabelText(item.product.name, 24)}"$eol');
      y += (30 * s).round();
      buffer.write('TEXT $margin,$y,"2",0,1,1,'
          '"${sanitizeLabelText(detail, 26)}"$eol');
      y += (26 * s).round();
      buffer.write('TEXT $margin,$y,"2",0,1,1,'
          '"${sanitizeLabelText(price, 24)}"$eol');
      y += (28 * s).round();
      final barH =
          ((size.heightDots - y - (10 * s)) * 0.8).round().clamp(24, 110);
      buffer.write('BARCODE $margin,$y,"128",$barH,0,0,2,2,'
          '"${sanitizeLabelText(item.code, 30)}"$eol');
      buffer.write('PRINT $copies,1$eol');
    }
    return buffer.toString();
  }

  String _label({
    required String name,
    required String price,
    required String code,
    required LabelSize size,
    required LabelDesign design,
    required double gapMm,
    required int copies,
  }) {
    const eol = '\r\n';
    final s = (size.heightDots / 200).clamp(0.6, 3.0);
    final margin = (16 * s).round();
    var y = (10 * s).round();
    final buffer = StringBuffer()
      ..write('SIZE ${size.widthMm} mm, ${size.heightMm} mm$eol')
      ..write('GAP $gapMm mm, 0 mm$eol')
      ..write('DIRECTION 1$eol')
      ..write('CLS$eol');
    // TSC built-in fonts: "2" = 12x20 dots, "3" = 16x24 dots.
    if (name.isNotEmpty) {
      final nameFont = s >= 1.4 ? '4' : '3';
      buffer.write('TEXT $margin,$y,"$nameFont",0,1,1,'
          '"${sanitizeLabelText(name, 28)}"$eol');
      y += (30 * s).round();
    }
    if (price.isNotEmpty) {
      buffer.write('TEXT $margin,$y,"2",0,1,1,'
          '"${sanitizeLabelText(price, 24)}"$eol');
      y += (26 * s).round();
    }
    final readable = design.showBarcodeText ? 1 : 0;
    final barH = ((size.heightDots - y - (20 * s)) * design.barcodeScale)
        .round()
        .clamp(30, 140);
    buffer.write('BARCODE $margin,$y,"128",$barH,$readable,0,2,2,'
        '"${sanitizeLabelText(code, 30)}"$eol');
    buffer.write('PRINT $copies,1$eol');
    return buffer.toString();
  }
}
