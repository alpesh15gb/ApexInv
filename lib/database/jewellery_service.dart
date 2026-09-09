import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/jewellery_piece.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/verticals.dart';

/// SQLite backing for the jewellery vertical (retail.md §4.1).
class JewelleryService {
  static final dbHelper = DatabaseHelper();

  static String _dayKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  // ── Metal rates ──────────────────────────────────────────────

  static Future<void> upsertMetalRate(MetalRate rate) async {
    final db = await dbHelper.database;
    await db.insert(
      'metal_rates',
      rate.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteMetalRate(String id) async {
    final db = await dbHelper.database;
    await db.delete('metal_rates', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<MetalRate>> getRatesForDate(DateTime date) async {
    final db = await dbHelper.database;
    final maps = await db.query(
      'metal_rates',
      where: 'effective_date = ?',
      whereArgs: [_dayKey(date)],
      orderBy: 'metal ASC, purity ASC',
    );
    return maps.map(MetalRate.fromMap).toList();
  }

  static Future<MetalRate?> getRateForDate({
    required String metal,
    required String purity,
    required DateTime date,
  }) async {
    final db = await dbHelper.database;
    final maps = await db.query(
      'metal_rates',
      where: 'metal = ? AND purity = ? AND effective_date <= ?',
      whereArgs: [metal, purity, _dayKey(date)],
      orderBy: 'effective_date DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return MetalRate.fromMap(maps.first);
  }

  static Future<DateTime?> getLatestRateDate() async {
    final db = await dbHelper.database;
    final rows = await db
        .rawQuery('SELECT MAX(effective_date) AS latest FROM metal_rates');
    final latest = rows.first['latest'] as String?;
    if (latest == null) return null;
    return DateTime.tryParse(latest);
  }

  // ── Product attributes ───────────────────────────────────────

  static Future<JewelleryAttributes?> getAttributes(String productId) async {
    final db = await dbHelper.database;
    final maps = await db.query(
      'jewellery_attributes',
      where: 'product_id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return JewelleryAttributes.fromMap(maps.first);
  }

  static Future<Map<String, JewelleryAttributes>> getAllAttributes() async {
    final db = await dbHelper.database;
    final maps = await db.query('jewellery_attributes');
    return {
      for (final map in maps)
        (map['product_id']?.toString() ?? ''): JewelleryAttributes.fromMap(map)
    }..removeWhere((key, _) => key.isEmpty);
  }

  static Future<void> upsertAttributes(JewelleryAttributes attributes) async {
    final db = await dbHelper.database;
    await db.insert(
      'jewellery_attributes',
      attributes.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteAttributes(String productId) async {
    final db = await dbHelper.database;
    await db.delete('jewellery_attributes',
        where: 'product_id = ?', whereArgs: [productId]);
  }

  // ── Tagged pieces (retail.md P2) ─────────────────────────────

  static Future<void> upsertPiece(JewelleryPiece piece) async {
    final db = await dbHelper.database;
    await db.insert(
      'jewellery_pieces',
      piece.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deletePiece(String id) async {
    final db = await dbHelper.database;
    await db.delete('jewellery_pieces', where: 'id = ?', whereArgs: [id]);
  }

  static Future<JewelleryPiece?> getPiece(String id) async {
    final db = await dbHelper.database;
    final maps = await db.query('jewellery_pieces',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isEmpty) return null;
    return JewelleryPiece.fromMap(maps.first);
  }

  static Future<List<JewelleryPiece>> getPiecesForProduct(
      String productId) async {
    final db = await dbHelper.database;
    final maps = await db.query('jewellery_pieces',
        where: 'product_id = ?', whereArgs: [productId], orderBy: 'tag_no ASC');
    return maps.map(JewelleryPiece.fromMap).toList();
  }

  static Future<Map<String, List<JewelleryPiece>>> getPiecesForProductIds(
      List<String> productIds) async {
    if (productIds.isEmpty) return {};
    final db = await dbHelper.database;
    final placeholders = List.filled(productIds.length, '?').join(',');
    final maps = await db.query(
      'jewellery_pieces',
      where: 'product_id IN ($placeholders)',
      whereArgs: productIds,
      orderBy: 'product_id ASC, tag_no ASC',
    );
    final grouped = <String, List<JewelleryPiece>>{};
    for (final map in maps) {
      final piece = JewelleryPiece.fromMap(map);
      grouped.putIfAbsent(piece.productId, () => []).add(piece);
    }
    return grouped;
  }

  /// One transaction moves every status so a crash can never leave a piece
  /// both sold and unclaimed: referenced pieces become `sold`, pieces this
  /// invoice used to own but no longer references go back to `in_stock`.
  /// Pass [txn] to join the caller's invoice transaction (sqflite cannot
  /// nest transactions); otherwise a fresh one is opened.
  static Future<void> syncPiecesForInvoice({
    required String invoiceId,
    required Set<String> pieceIds,
    DatabaseExecutor? txn,
  }) async {
    Future<void> run(DatabaseExecutor e) async {
      final previous = await e.query(
        'jewellery_pieces',
        where: 'sold_invoice_id = ?',
        whereArgs: [invoiceId],
      );
      final previousIds = {
        for (final row in previous) row['id']?.toString() ?? ''
      }..remove('');
      final toRelease = previousIds.difference(pieceIds);
      for (final id in toRelease) {
        await e.update(
          'jewellery_pieces',
          {
            'status': 'in_stock',
            'sold_invoice_id': null,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      for (final id in pieceIds) {
        if (id.isEmpty) continue;
        await e.update(
          'jewellery_pieces',
          {
            'status': 'sold',
            'sold_invoice_id': invoiceId,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }

    if (txn != null) {
      await run(txn);
    } else {
      await (await dbHelper.database).transaction(run);
    }
  }

  // ── Old gold exchange (retail.md P3) ─────────────────────────

  static Future<void> upsertOldGoldEntry(OldGoldEntry entry) async {
    final db = await dbHelper.database;
    await db.insert('old_gold_entries', entry.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteOldGoldEntry(String id) async {
    final db = await dbHelper.database;
    await db.delete('old_gold_entries', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<OldGoldEntry>> getOldGoldForInvoice(
      String invoiceId) async {
    final db = await dbHelper.database;
    final maps = await db.query('old_gold_entries',
        where: 'invoice_id = ?', whereArgs: [invoiceId]);
    return maps.map(OldGoldEntry.fromMap).toList();
  }

  /// Replaces the entries of one invoice with [entries] in one transaction
  /// and returns the fresh rows with their ids.
  static Future<List<OldGoldEntry>> replaceOldGoldForInvoice({
    required String invoiceId,
    required List<OldGoldEntry> entries,
    DatabaseExecutor? txn,
  }) async {
    Future<List<OldGoldEntry>> run(DatabaseExecutor e) async {
      await e.delete('old_gold_entries',
          where: 'invoice_id = ?', whereArgs: [invoiceId]);
      final stored = <OldGoldEntry>[];
      for (final entry in entries) {
        final row = entry.toMap();
        row['invoice_id'] = invoiceId;
        await e.insert('old_gold_entries', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
        stored.add(OldGoldEntry.fromMap(row));
      }
      return stored;
    }

    if (txn != null) return run(txn);
    return (await dbHelper.database).transaction(run);
  }

  // ── Karigar job work (retail.md P3) ──────────────────────────

  static Future<void> upsertJobWorkOrder(JobWorkOrder order) async {
    final db = await dbHelper.database;
    await db.insert('job_work_orders', order.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteJobWorkOrder(String id) async {
    final db = await dbHelper.database;
    await db.delete('job_work_orders', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<JobWorkOrder>> getJobWorkOrders({String? status}) async {
    final db = await dbHelper.database;
    final maps = await db.query(
      'job_work_orders',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'issued_date DESC, rowid DESC',
    );
    return maps.map(JobWorkOrder.fromMap).toList();
  }
}
