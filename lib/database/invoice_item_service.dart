import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/domain/jewellery/jewellery_calculator.dart';
import 'package:apexbooks/utils/app_logger.dart';
import 'database_helper.dart';

const _tag = 'InvoiceItemService';

class InvoiceItemService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertInvoiceItems(String invId, InvoiceItem item) async {
    final db = await dbHelper.database;
    await db.insert('invoice_items', {
      'id': item.id,
      'invoice_id': invId,
      'product_id': item.product.id,
      'product_name': item.product.name,
      'product_description': item.product.description,
      'product_price': item.product.price,
      'product_tax_rate': item.product.tax_rate,
      'product_price_includes_tax': item.product.priceIncludesTax ? 1 : 0,
      'product_hsn_code': item.product.hsncode,
      'quantity': item.quantity,
      'discount': item.discount,
      'unit_price': item.unitPrice,
      'extra_cost': item.extraCost,
      'discount_per_unit': item.discountPerUnit ? 1 : 0,
      'is_product_saved': item.isProductSaved ? 1 : 0,
      'product_type': item.product.type,
      'product_purchase_price': item.product.purchasePrice,
      'product_unit': item.product.unit,
      'unit': item.unit,
      'description': item.description,
      'metal_rate_id': item.metalRateId,
      'net_weight': item.netWeight,
      'making_amount': item.makingAmount,
      'wastage_amount': item.wastageAmount,
      'jewellery_tax_treatment': item.jewelleryTaxTreatment.key,
      'jewellery_piece_id': item.jewelleryPieceId,
    });
  }

  static Future<List<InvoiceItem>> getInvoiceItemsByInvoiceId(
      String invoiceId) async {
    final grouped = await getInvoiceItemsByInvoiceIds([invoiceId]);
    return grouped[invoiceId] ?? [];
  }

  /// Batch-loads items for many invoices in one query (avoids N+1 when
  /// hydrating list pages). Rows keep `rowid` order within each invoice.
  static Future<Map<String, List<InvoiceItem>>> getInvoiceItemsByInvoiceIds(
      List<String> invoiceIds) async {
    if (invoiceIds.isEmpty) return {};
    final db = await dbHelper.database;
    final placeholders = List.filled(invoiceIds.length, '?').join(',');
    final maps = await db.query(
      'invoice_items',
      where: 'invoice_id IN ($placeholders)',
      whereArgs: invoiceIds,
      orderBy: 'invoice_id ASC, rowid ASC',
    );
    final grouped = <String, List<InvoiceItem>>{};
    for (var map in maps) {
      final item = _itemFromRow(map);
      if (item == null) continue;
      grouped.putIfAbsent(map['invoice_id'] as String, () => []).add(item);
    }
    return grouped;
  }

  static InvoiceItem? _itemFromRow(Map<String, dynamic> map) {
    try {
      final product = Product.fromInvoiceItemsMap(map);
      final rawUnitPrice = map['unit_price'];
      final unitPrice = rawUnitPrice == null
          ? null
          : (rawUnitPrice is int
              ? rawUnitPrice.toDouble()
              : rawUnitPrice as double);
      final rawExtraCost = map['extra_cost'];
      final extraCost = rawExtraCost == null
          ? null
          : (rawExtraCost is int
              ? rawExtraCost.toDouble()
              : rawExtraCost as double);
      return InvoiceItem(
        id: map['id'] as String?,
        product: product,
        quantity: (map['quantity'] is int)
            ? (map['quantity'] as int).toDouble()
            : (map['quantity'] ?? 1.0) as double,
        discount: (map['discount'] is int)
            ? (map['discount'] as int).toDouble()
            : (map['discount'] ?? 0.0) as double,
        unitPrice: unitPrice,
        extraCost: extraCost,
        unit: map['unit'] as String?,
        description: map['description'] as String?,
        discountPerUnit: (map['discount_per_unit'] as int? ?? 0) == 1,
        isProductSaved: (map['is_product_saved'] as int? ?? 0) == 1,
        metalRateId: map['metal_rate_id'] as String?,
        netWeight: (map['net_weight'] as num?)?.toDouble(),
        makingAmount: (map['making_amount'] as num?)?.toDouble(),
        wastageAmount: (map['wastage_amount'] as num?)?.toDouble(),
        jewelleryTaxTreatment: jewelleryTaxTreatmentFromKey(
            map['jewellery_tax_treatment'] as String?),
        jewelleryPieceId: map['jewellery_piece_id'] as String?,
      );
    } catch (e, stackTrace) {
      AppLogger.e(_tag, 'Error parsing invoice item row', e, stackTrace);
      return null;
    }
  }

  static Future<void> markProductSaved(
      String invoiceId, String productId) async {
    final db = await dbHelper.database;
    await db.update(
      'invoice_items',
      {'is_product_saved': 1},
      where: 'invoice_id = ? AND product_id = ?',
      whereArgs: [invoiceId, productId],
    );
  }
}
