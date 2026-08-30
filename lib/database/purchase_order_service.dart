import 'package:apexbooks/models/purchase_order.dart';
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

class PurchaseOrderService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertPurchaseOrder(PurchaseOrder po, List<PurchaseOrderItem> items) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.insert('purchase_orders', po.toMap());
      for (final item in items) {
        final itemMap = item.toMap()..['purchase_order_id'] = po.id;
        await txn.insert('purchase_order_items', itemMap);
      }
    });
  }

  static Future<void> updatePurchaseOrder(PurchaseOrder po, {List<PurchaseOrderItem>? items}) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final updateMap = po.toMap()..remove('id');
      await txn.update('purchase_orders', updateMap, where: 'id = ?', whereArgs: [po.id]);
      if (items != null) {
        await txn.delete('purchase_order_items', where: 'purchase_order_id = ?', whereArgs: [po.id]);
        for (final item in items) {
          final itemMap = item.toMap()..['purchase_order_id'] = po.id;
          await txn.insert('purchase_order_items', itemMap);
        }
      }
    });
  }

  static Future<PurchaseOrder?> getPurchaseOrderById(String id) async {
    final db = await dbHelper.database;
    final maps = await db.query('purchase_orders', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    final items = await getItemsForOrder(id);
    return PurchaseOrder.fromMap(maps.first).copyWith(items: items);
  }

  static Future<List<PurchaseOrderItem>> getItemsForOrder(String orderId) async {
    final db = await dbHelper.database;
    final maps = await db.query('purchase_order_items', where: 'purchase_order_id = ?', whereArgs: [orderId]);
    return maps.map((m) => PurchaseOrderItem.fromMap(m)).toList();
  }

  static Future<List<PurchaseOrder>> getAllPurchaseOrders() async {
    final db = await dbHelper.database;
    final maps = await db.query('purchase_orders', orderBy: 'date DESC');
    final orders = <PurchaseOrder>[];
    for (final map in maps) {
      final items = await getItemsForOrder(map['id'] as String);
      orders.add(PurchaseOrder.fromMap(map).copyWith(items: items));
    }
    return orders;
  }

  static Future<List<PurchaseOrder>> getPurchaseOrdersPaginated({
    int page = 0,
    int pageSize = 50,
    String searchQuery = '',
    String? status,
  }) async {
    final db = await dbHelper.database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (searchQuery.isNotEmpty) {
      conditions.add('LOWER(vendor_name) LIKE ?');
      args.add('%${searchQuery.toLowerCase()}%');
    }
    if (status != null && status.isNotEmpty) {
      conditions.add('status = ?');
      args.add(status);
    }

    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final maps = await db.query(
      'purchase_orders',
      where: where,
      whereArgs: args,
      orderBy: 'date DESC',
      limit: pageSize,
      offset: page * pageSize,
    );

    final orders = <PurchaseOrder>[];
    for (final map in maps) {
      final items = await getItemsForOrder(map['id'] as String);
      orders.add(PurchaseOrder.fromMap(map).copyWith(items: items));
    }
    return orders;
  }

  static Future<int> getPurchaseOrderCount({String? status}) async {
    final db = await dbHelper.database;
    String? where;
    List<dynamic>? args;
    if (status != null && status.isNotEmpty) {
      where = 'status = ?';
      args = [status];
    }
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM purchase_orders ${where != null ? 'WHERE $where' : ''}',
      args,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  static Future<void> updateStatus(String id, String status) async {
    final db = await dbHelper.database;
    await db.update('purchase_orders', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deletePurchaseOrder(String id) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.delete('purchase_order_items', where: 'purchase_order_id = ?', whereArgs: [id]);
      await txn.delete('purchase_orders', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<String> generateNextId() async {
    final db = await dbHelper.database;
    final result = await db.rawQuery("SELECT MAX(CAST(id AS INTEGER)) FROM purchase_orders");
    final maxId = Sqflite.firstIntValue(result) ?? 0;
    return (maxId + 1).toString();
  }

  static Future<String> generateNextOrderNumber() async {
    final db = await dbHelper.database;
    final result = await db.rawQuery("SELECT MAX(CAST(order_number AS INTEGER)) FROM purchase_orders WHERE order_number IS NOT NULL");
    final maxNum = Sqflite.firstIntValue(result) ?? 0;
    return (maxNum + 1).toString().padLeft(6, '0');
  }

  static Future<({double totalSpent, int totalOrders, double outstanding})> getPurchaseFinancials() async {
    final db = await dbHelper.database;
    final result = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(total_amount), 0) as total_spent,
        COUNT(*) as total_orders,
        COALESCE(SUM(total_amount - amount_paid), 0) as outstanding
      FROM purchase_orders
      WHERE status != 'cancelled'
    ''');
    if (result.isEmpty) return (totalSpent: 0.0, totalOrders: 0, outstanding: 0.0);
    return (
      totalSpent: (result.first['total_spent'] as num?)?.toDouble() ?? 0.0,
      totalOrders: (result.first['total_orders'] as num?)?.toInt() ?? 0,
      outstanding: (result.first['outstanding'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
