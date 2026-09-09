import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/verticals.dart';

/// Product variants (size/colour — retail.md P4). The catalog product is
/// the shared design; variants are sellable options with their own stock.
class ProductVariantService {
  static final dbHelper = DatabaseHelper();

  static Future<void> upsert(ProductVariant variant) async {
    final db = await dbHelper.database;
    await db.insert('product_variants', variant.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    final db = await dbHelper.database;
    await db.delete('product_variants', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<ProductVariant>> getForProduct(String productId) async {
    final db = await dbHelper.database;
    final maps = await db.query('product_variants',
        where: 'product_id = ?',
        whereArgs: [productId],
        orderBy: 'name ASC, value ASC');
    return maps.map(ProductVariant.fromMap).toList();
  }

  static Future<Map<String, List<ProductVariant>>> getForProductIds(
      List<String> productIds) async {
    if (productIds.isEmpty) return {};
    final db = await dbHelper.database;
    final placeholders = List.filled(productIds.length, '?').join(',');
    final maps = await db.query(
      'product_variants',
      where: 'product_id IN ($placeholders)',
      whereArgs: productIds,
      orderBy: 'product_id ASC, name ASC, value ASC',
    );
    final grouped = <String, List<ProductVariant>>{};
    for (final map in maps) {
      final variant = ProductVariant.fromMap(map);
      grouped.putIfAbsent(variant.productId, () => []).add(variant);
    }
    return grouped;
  }

  /// Replaces a product's whole variant list (product form save path).
  static Future<void> replaceForProduct({
    required String productId,
    required List<ProductVariant> variants,
  }) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.delete('product_variants',
          where: 'product_id = ?', whereArgs: [productId]);
      for (final variant in variants) {
        await txn.insert('product_variants', variant.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
