import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/product.dart';

/// Barcode label printing for TSC (TSPL) and Zebra (ZPL) printers.
///
/// Labels are described here; [ZplBuilder]/[TsplBuilder] (see
/// `zpl_builder.dart` / `tspl_builder.dart`) turn them into raw printer
/// bytes, which [LabelPrinterService] sends over USB or TCP port 9100.

/// Printer command language. TSC printers speak TSPL, Zebra printers ZPL.
enum LabelPrinterLanguage { tspl, zpl }

LabelPrinterLanguage labelPrinterLanguageFromKey(String? key) {
  switch (key) {
    case 'zpl':
      return LabelPrinterLanguage.zpl;
    default:
      return LabelPrinterLanguage.tspl;
  }
}

extension LabelPrinterLanguageKey on LabelPrinterLanguage {
  String get key => switch (this) {
        LabelPrinterLanguage.tspl => 'tspl',
        LabelPrinterLanguage.zpl => 'zpl',
      };

  String get label => switch (this) {
        LabelPrinterLanguage.tspl => 'TSC (TSPL)',
        LabelPrinterLanguage.zpl => 'Zebra (ZPL)',
      };
}

/// Physical label stock preset. Rendered at 203 dpi (8 dots per mm).
class LabelSize {
  final String id;
  final String label;
  final double widthMm;
  final double heightMm;

  const LabelSize({
    required this.id,
    required this.label,
    required this.widthMm,
    required this.heightMm,
  });

  int get widthDots => (widthMm * 8).round();
  int get heightDots => (heightMm * 8).round();

  static const List<LabelSize> presets = [
    LabelSize(id: '50x25', label: '50 × 25 mm', widthMm: 50, heightMm: 25),
    LabelSize(id: '50x30', label: '50 × 30 mm', widthMm: 50, heightMm: 30),
    LabelSize(id: '38x25', label: '38 × 25 mm', widthMm: 38, heightMm: 25),
    LabelSize(id: '100x50', label: '100 × 50 mm', widthMm: 100, heightMm: 50),
  ];

  static LabelSize fromId(String? id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    // Custom sizes persist as 'custom:<width>x<height>' in millimetres.
    final match = RegExp(r'^custom:(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$')
        .firstMatch(id ?? '');
    if (match != null) {
      final w = double.tryParse(match.group(1)!) ?? 0;
      final h = double.tryParse(match.group(2)!) ?? 0;
      if (w >= 10 && w <= 300 && h >= 10 && h <= 300) {
        return LabelSize(
            id: id!,
            label: 'Custom ${_trimNum(w)} × ${_trimNum(h)} mm',
            widthMm: w,
            heightMm: h);
      }
    }
    return presets.first;
  }

  static String customId(double widthMm, double heightMm) =>
      'custom:${widthMm}x$heightMm';

  bool get isCustom => id.startsWith('custom:');
}

String _trimNum(double v) => v % 1 == 0 ? v.toInt().toString() : v.toString();

/// User-configurable label design: which elements print and how tall the
/// barcode bars are.
class LabelDesign {
  final bool showName;
  final bool showPrice;
  final bool showBarcodeText;
  final String barcodeHeight; // 's' | 'm' | 'l'

  const LabelDesign({
    this.showName = true,
    this.showPrice = true,
    this.showBarcodeText = true,
    this.barcodeHeight = 'm',
  });

  /// 0..1 scale applied to the barcode band left over by the text lines.
  double get barcodeScale => switch (barcodeHeight) {
        's' => 0.6,
        'l' => 1.0,
        _ => 0.8,
      };

  LabelDesign copyWith({
    bool? showName,
    bool? showPrice,
    bool? showBarcodeText,
    String? barcodeHeight,
  }) {
    return LabelDesign(
      showName: showName ?? this.showName,
      showPrice: showPrice ?? this.showPrice,
      showBarcodeText: showBarcodeText ?? this.showBarcodeText,
      barcodeHeight: barcodeHeight ?? this.barcodeHeight,
    );
  }

  static const List<String> barcodeHeights = ['s', 'm', 'l'];

  static String barcodeHeightLabel(String value) => switch (value) {
        's' => 'Short',
        'l' => 'Tall',
        _ => 'Medium',
      };
}

/// One printable label line: a product plus how many copies to print.
class LabelItem {
  final Product product;
  final int copies;

  const LabelItem({required this.product, this.copies = 1});

  /// Barcode payload: the stored barcode, falling back to the product id
  /// (Code 128 accepts any ASCII, so there is always something printable).
  String get code =>
      product.barcode.trim().isNotEmpty ? product.barcode.trim() : product.id;
}

/// One jewellery tag label (retail.md P1): product + attributes + the rate
/// the retail sell rate the tag is priced with. Tags always print purity, net
/// weight and price.
class TagLabelItem {
  final Product product;
  final JewelleryAttributes attributes;
  final MetalRate? rate;
  final int copies;

  const TagLabelItem({
    required this.product,
    required this.attributes,
    this.rate,
    this.copies = 1,
  });

  String get code =>
      product.barcode.trim().isNotEmpty ? product.barcode.trim() : product.id;

  /// Net grams: the stored (editable) net weight, else gross − stone.
  double get netWeight => attributes.netWeight > 0
      ? attributes.netWeight
      : JewelleryCalculator.netWeight(
          attributes.grossWeight, attributes.stoneWeight);

  /// Tag price = metal + wastage + making (GST-exclusive), from the frozen
  /// rate when one exists (no rate ⇒ weight-only components at 0 rate).
  double get price {
    final net = netWeight;
    final metal = JewelleryCalculator.metalValue(
      netWeight: net,
      purity: attributes.purity,
      ratePerGram: rate?.sellRatePerGram ?? 0,
    );
    final wastage = JewelleryCalculator.wastageAmount(
        metalValue: metal, wastagePercent: attributes.wastagePercent);
    final making = JewelleryCalculator.makingAmount(
      makingType: makingTypeFromKey(attributes.makingType),
      makingValue: attributes.makingValue,
      netWeight: net,
      metalValue: metal,
    );
    return metal + wastage + making;
  }
}

/// Where to send the label bytes.
class LabelPrinterConnection {
  final String kind; // 'usb' | 'network'
  final String? name; // USB printer name (Windows) — Android uses vid/pid
  final String? vendorId; // Android USB
  final String? productId; // Android USB
  final String? ip; // network
  final int port; // network, default 9100

  const LabelPrinterConnection({
    required this.kind,
    this.name,
    this.vendorId,
    this.productId,
    this.ip,
    this.port = 9100,
  });

  bool get isConfigured =>
      (kind == 'usb' && (name ?? '').isNotEmpty) ||
      (kind == 'network' && (ip ?? '').isNotEmpty);

  String describe() {
    if (kind == 'network') return 'Network ${(ip ?? '').trim()}:$port';
    return 'USB ${(name ?? '').trim()}';
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (name != null) 'name': name,
        if (vendorId != null) 'vendorId': vendorId,
        if (productId != null) 'productId': productId,
        if (ip != null) 'ip': ip,
        'port': port,
      };

  static LabelPrinterConnection? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final String kind = json['kind'] as String? ?? '';
    if (kind != 'usb' && kind != 'network') return null;
    return LabelPrinterConnection(
      kind: kind,
      name: json['name'] as String?,
      vendorId: json['vendorId'] as String?,
      productId: json['productId'] as String?,
      ip: json['ip'] as String?,
      port: (json['port'] as num?)?.toInt() ?? 9100,
    );
  }
}

/// Strips characters label firmware cannot render (quotes break the command
/// syntax; non-ASCII glyphs are absent from built-in printer fonts).
String sanitizeLabelText(String input, [int maxLength = 32]) {
  final ascii = input.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
  final unquoted =
      ascii.replaceAll('"', "'").trim().replaceAll(RegExp(r'\s+'), ' ');
  if (unquoted.length <= maxLength) return unquoted;
  return unquoted.substring(0, maxLength);
}
