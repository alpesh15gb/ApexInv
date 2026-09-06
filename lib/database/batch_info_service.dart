import 'package:apexbooks/models/batch_info.dart';
import 'package:uuid/uuid.dart';
import 'database_helper.dart';

class BatchInfoService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertBatchInfo(BatchInfo batch) async {
    final db = await dbHelper.database;
    await db.insert('batch_info', batch.toMap());
  }

  static Future<void> updateBatchInfo(BatchInfo batch) async {
    final db = await dbHelper.database;
    final updateMap = batch.toMap()..remove('id');
    await db.update('batch_info', updateMap,
        where: 'id = ?', whereArgs: [batch.id]);
  }

  static Future<BatchInfo?> getBatchInfoById(String id) async {
    final db = await dbHelper.database;
    final maps = await db.query('batch_info', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return BatchInfo.fromMap(maps.first);
  }

  static Future<List<BatchInfo>> getBatchesForProduct(String productId) async {
    final db = await dbHelper.database;
    final maps = await db.query(
      'batch_info',
      where: 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'expiry_date ASC',
    );
    return maps.map((m) => BatchInfo.fromMap(m)).toList();
  }

  static Future<List<BatchInfo>> getAllBatches() async {
    final db = await dbHelper.database;
    final maps =
        await db.query('batch_info', orderBy: 'product_id, batch_number');
    return maps.map((m) => BatchInfo.fromMap(m)).toList();
  }

  static Future<List<BatchInfo>> getExpiringBatches(
      {int withinDays = 30}) async {
    final db = await dbHelper.database;
    final now = DateTime.now();
    final futureDate = now.add(Duration(days: withinDays));
    final maps = await db.rawQuery('''
      SELECT * FROM batch_info
      WHERE expiry_date IS NOT NULL
        AND expiry_date >= ?
        AND expiry_date <= ?
      ORDER BY expiry_date ASC
    ''', [now.toIso8601String(), futureDate.toIso8601String()]);
    return maps.map((m) => BatchInfo.fromMap(m)).toList();
  }

  static Future<List<BatchInfo>> getExpiredBatches() async {
    final db = await dbHelper.database;
    final maps = await db.rawQuery('''
      SELECT * FROM batch_info
      WHERE expiry_date IS NOT NULL
        AND expiry_date < ?
      ORDER BY expiry_date ASC
    ''', [DateTime.now().toIso8601String()]);
    return maps.map((m) => BatchInfo.fromMap(m)).toList();
  }

  static Future<void> deductQuantity(String batchId, double quantity) async {
    final db = await dbHelper.database;
    await db.rawUpdate('''
      UPDATE batch_info
      SET quantity = MAX(0, quantity - ?)
      WHERE id = ?
    ''', [quantity, batchId]);
  }

  static Future<void> deleteBatchInfo(String id) async {
    final db = await dbHelper.database;
    await db.delete('batch_info', where: 'id = ?', whereArgs: [id]);
  }

  /// UUID mint (was MAX+1 'batch-N'): cross-device creation cannot collide
  /// on the sync wire. Legacy 'batch-N' ids remain readable.
  static Future<String> generateNextId() async {
    return const Uuid().v4();
  }
}
