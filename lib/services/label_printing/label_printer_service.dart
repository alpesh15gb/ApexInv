import 'dart:convert';

import 'package:thermal_printer/thermal_printer.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/services/backend_services.dart';
import 'label_models.dart';
import 'tspl_builder.dart';
import 'zpl_builder.dart';

/// Sends barcode-label jobs to TSC (TSPL) / Zebra (ZPL) printers.
///
/// USB goes through the platform printer channel (Android + Windows),
/// network printers receive raw bytes on TCP 9100. Printer choice and label
/// defaults persist in settings so the dialog opens ready to print.
class LabelPrinterService {
  const LabelPrinterService();

  static const _tspl = TsplBuilder();
  static const _zpl = ZplBuilder();

  Future<LabelPrinterLanguage> getLanguage() async {
    final key = await BackendServices.settings
        .getSetting(SettingKey.labelPrinterLanguage);
    return labelPrinterLanguageFromKey(key);
  }

  Future<void> setLanguage(LabelPrinterLanguage language) =>
      BackendServices.settings
          .setSetting(SettingKey.labelPrinterLanguage, language.key);

  Future<LabelPrinterConnection?> getConnection() async {
    final raw = await BackendServices.settings
        .getSetting(SettingKey.labelPrinterConnection);
    if (raw == null || raw.isEmpty) return null;
    try {
      return LabelPrinterConnection.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setConnection(LabelPrinterConnection? connection) =>
      BackendServices.settings.setSetting(
        SettingKey.labelPrinterConnection,
        connection == null ? '' : jsonEncode(connection.toJson()),
      );

  Future<LabelSize> getSize() async {
    final id = await BackendServices.settings.getSetting(SettingKey.labelSize);
    return LabelSize.fromId(id);
  }

  Future<void> setSize(String id) =>
      BackendServices.settings.setSetting(SettingKey.labelSize, id);

  Future<bool> getShowPrice() async {
    final value =
        await BackendServices.settings.getSetting(SettingKey.labelShowPrice);
    return value != 'false';
  }

  Future<void> setShowPrice(bool show) => BackendServices.settings
      .setSetting(SettingKey.labelShowPrice, show.toString());

  Future<LabelDesign> getDesign() async {
    final settings = BackendServices.settings;
    final results = await Future.wait([
      settings.getSetting(SettingKey.labelShowName),
      settings.getSetting(SettingKey.labelShowPrice),
      settings.getSetting(SettingKey.labelShowBarcodeText),
      settings.getSetting(SettingKey.labelBarcodeHeight),
    ]);
    final height = results[3];
    return LabelDesign(
      showName: results[0] != 'false',
      showPrice: results[1] != 'false',
      showBarcodeText: results[2] != 'false',
      barcodeHeight:
          LabelDesign.barcodeHeights.contains(height) ? height! : 'm',
    );
  }

  Future<void> setDesign(LabelDesign design) => Future.wait([
        BackendServices.settings
            .setSetting(SettingKey.labelShowName, design.showName.toString()),
        setShowPrice(design.showPrice),
        BackendServices.settings.setSetting(
            SettingKey.labelShowBarcodeText, design.showBarcodeText.toString()),
        BackendServices.settings
            .setSetting(SettingKey.labelBarcodeHeight, design.barcodeHeight),
      ]);

  String buildJob({
    required List<LabelItem> items,
    required LabelPrinterLanguage language,
    required LabelSize size,
    required String currencyCode,
    required bool showPrice,
    LabelDesign design = const LabelDesign(),
  }) {
    if (language == LabelPrinterLanguage.zpl) {
      return _zpl.buildLabels(
          items: items,
          size: size,
          currencyCode: currencyCode,
          showPrice: showPrice,
          design: design);
    }
    return _tspl.buildLabels(
        items: items,
        size: size,
        currencyCode: currencyCode,
        showPrice: showPrice,
        design: design);
  }

  /// Jewellery tag labels (retail.md P1): purity, net weight, frozen-rate
  /// price and the tag barcode, one per tagged product.
  String buildTagJob({
    required List<TagLabelItem> items,
    required LabelPrinterLanguage language,
    required LabelSize size,
    required String currencyCode,
  }) {
    if (language == LabelPrinterLanguage.zpl) {
      return _zpl.buildTagLabels(
          items: items, size: size, currencyCode: currencyCode);
    }
    return _tspl.buildTagLabels(
        items: items, size: size, currencyCode: currencyCode);
  }

  /// A single self-identifying label used as a connection test.
  String buildTestJob({
    required LabelPrinterLanguage language,
    required LabelSize size,
  }) {
    const probe = 'TEST-123456';
    if (language == LabelPrinterLanguage.zpl) {
      return '^XA^PW${size.widthDots}^LL${size.heightDots}^LH0,0'
          '^FO20,60^A0N,30,30^FDPrinter test $probe^FS'
          '^FO20,100^BY2^BCN,60,Y,N,N^FD$probe^FS^XZ';
    }
    return 'SIZE ${size.widthMm} mm, ${size.heightMm} mm\r\n'
        'GAP 3 mm, 0 mm\r\nDIRECTION 1\r\nCLS\r\n'
        'TEXT 20,40,"3",0,1,1,"Printer test $probe"\r\n'
        'BARCODE 20,80,"128",60,1,0,2,2,"$probe"\r\n'
        'PRINT 1,1\r\n';
  }

  Future<List<UsbPrinterInfo>> discoverUsbPrinters() async {
    final found = await UsbPrinterConnector.discoverPrinters();
    return [for (final printer in found) printer.detail];
  }

  Future<bool> printBytes({
    required LabelPrinterConnection connection,
    required String payload,
  }) async {
    final manager = PrinterManager.instance;
    final bytes = payload.codeUnits;
    if (connection.kind == 'network') {
      final model = TcpPrinterInput(
          ipAddress: (connection.ip ?? '').trim(), port: connection.port);
      await manager.connect(type: PrinterType.network, model: model);
      try {
        return await manager.send(type: PrinterType.network, bytes: bytes);
      } finally {
        await manager.disconnect(type: PrinterType.network);
      }
    }
    final model = UsbPrinterInput(
      name: connection.name,
      vendorId: connection.vendorId,
      productId: connection.productId,
    );
    await manager.connect(type: PrinterType.usb, model: model);
    try {
      return await manager.send(type: PrinterType.usb, bytes: bytes);
    } finally {
      await manager.disconnect(type: PrinterType.usb);
    }
  }
}
