import 'package:apexbooks/models/metal_rate.dart';

import 'label_models.dart';

/// Builds ZPL II label jobs for Zebra printers (203 dpi).
///
/// Layout per label: product name, optional price line, Code 128 barcode
/// with human-readable text. [copies] repeats the label block.
class ZplBuilder {
  const ZplBuilder();

  String buildLabels({
    required List<LabelItem> items,
    required LabelSize size,
    required String currencyCode,
    bool showPrice = true,
    LabelDesign design = const LabelDesign(),
  }) {
    final buffer = StringBuffer();
    for (final item in items) {
      final copies = item.copies < 1 ? 1 : item.copies;
      for (var i = 0; i < copies; i++) {
        buffer.write(_label(
          name: design.showName ? item.product.name : '',
          price: (showPrice && design.showPrice)
              ? '$currencyCode ${item.product.price.toStringAsFixed(2)}'
              : '',
          code: item.code,
          size: size,
          design: design,
        ));
      }
    }
    return buffer.toString();
  }

  /// Jewellery tag labels (retail.md P1) — ZPL twin of the TSPL tags.
  String buildTagLabels({
    required List<TagLabelItem> items,
    required LabelSize size,
    required String currencyCode,
  }) {
    final buffer = StringBuffer();
    for (final item in items) {
      final copies = item.copies < 1 ? 1 : item.copies;
      for (var i = 0; i < copies; i++) {
        final w = size.widthDots;
        final h = size.heightDots;
        final s = (h / 200).clamp(0.6, 3.0);
        final margin = (16 * s).round();
        var y = (10 * s).round();
        final attr = item.attributes;
        final detail =
            '${MetalRate.metalLabel(attr.metal)} ${attr.purity} · ${item.netWeight.toStringAsFixed(2)} g';
        final price = '$currencyCode ${item.price.toStringAsFixed(2)}';
        buffer.write('^XA^PW$w^LL$h^LH0,0');
        final nameH = (26 * s).round();
        buffer.write(
            '^FO$margin,$y^A0N,$nameH,$nameH^FD${sanitizeLabelText(item.product.name, (w / (nameH * 0.6)).floor())}^FS');
        y += (nameH + 8 * s).round();
        final detailH = (22 * s).round();
        buffer.write('^FO$margin,$y^A0N,$detailH,$detailH'
            '^FD${sanitizeLabelText(detail, 26)}^FS');
        y += (detailH + 8 * s).round();
        buffer.write('^FO$margin,$y^A0N,$detailH,$detailH'
            '^FD${sanitizeLabelText(price, 24)}^FS');
        y += (detailH + 10 * s).round();
        final barH = ((h - y - (10 * s)) * 0.8).round().clamp(24, 110);
        buffer.write('^FO$margin,$y^BY2^BCN,$barH,N,N,N'
            '^FD${sanitizeLabelText(item.code, 30)}^FS');
        buffer.write('^XZ');
      }
    }
    return buffer.toString();
  }

  String _label({
    required String name,
    required String price,
    required String code,
    required LabelSize size,
    required LabelDesign design,
  }) {
    final w = size.widthDots;
    final h = size.heightDots;
    // Scale typography off the 50x25 reference (400x200 dots).
    final s = (h / 200).clamp(0.6, 3.0);
    final margin = (16 * s).round();
    var y = (10 * s).round();
    final buffer = StringBuffer()..write('^XA^PW$w^LL$h^LH0,0');
    if (name.isNotEmpty) {
      final nameH = (26 * s).round();
      buffer.write(
          '^FO$margin,$y^A0N,$nameH,$nameH^FD${sanitizeLabelText(name, (w / (nameH * 0.6)).floor())}^FS');
      y += (nameH + 8 * s).round();
    }
    if (price.isNotEmpty) {
      final priceH = (22 * s).round();
      buffer.write('^FO$margin,$y^A0N,$priceH,$priceH'
          '^FD${sanitizeLabelText(price, 24)}^FS');
      y += (priceH + 8 * s).round();
    }
    final readable = design.showBarcodeText ? 'Y' : 'N';
    final barH =
        ((h - y - (18 * s)) * design.barcodeScale).round().clamp(30, 140);
    buffer.write('^FO$margin,$y^BY2^BCN,$barH,$readable,N,N'
        '^FD${sanitizeLabelText(code, 30)}^FS');
    buffer.write('^XZ');
    return buffer.toString();
  }
}
