import 'package:apexbooks/models/purchase_order.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'database_helper.dart';
import 'period_lock_service.dart';

class PurchaseOrderService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertPurchaseOrder(
      PurchaseOrder po, List<PurchaseOrderItem> items) async {
    // Period lock: backdated orders into a closed period are refused.
    await PeriodLockService.assertDateUnlocked(po.date,
        entity: 'Purchase order');
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.insert('purchase_orders', po.toMap());
      for (final item in items) {
        final itemMap = item.toMap()..['purchase_order_id'] = po.id;
        await txn.insert('purchase_order_items', itemMap);
      }
    });
  }

  static Future<void> updatePurchaseOrder(PurchaseOrder po,
      {List<PurchaseOrderItem>? items}) async {
    final db = await dbHelper.database;
    // Period lock: refuse edits whose stored order OR new date is closed.
    await PeriodLockService.assertDateUnlocked(po.date,
        entity: 'Purchase order');
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_orders', id: po.id, entity: 'Purchase order');
    await db.transaction((txn) async {
      final oldRows = await txn.query('purchase_orders',
          columns: ['status', 'amount_paid'],
          where: 'id = ?',
          whereArgs: [po.id],
          limit: 1);
      if (oldRows.isEmpty) throw StateError('Purchase order not found');
      final oldStatus = oldRows.first['status'] as String? ?? 'draft';
      // amount_paid on a PO is append-only bookkeeping: an edit must never
      // silently drop what the vendor was already paid.
      final storedPaid = (oldRows.first['amount_paid'] as num? ?? 0).toDouble();
      final oldItems = await txn.query('purchase_order_items',
          columns: ['product_id', 'quantity'],
          where: 'purchase_order_id = ?',
          whereArgs: [po.id]);
      final wasReceived = oldStatus == 'received';
      final isReceivedNow = po.status == 'received';
      final oldQty = _qtyByProduct(oldItems.map(PurchaseOrderItem.fromMap));
      if (!wasReceived && isReceivedNow) {
        // Draft/confirmed → received via edit: stock the NEW lines once.
        // When no replacement lines are supplied the stored lines stay, so
        // stock those instead.
        await _adjustStockInTxn(
            txn, items != null ? _qtyByProduct(items) : oldQty);
      } else if (wasReceived && !isReceivedNow) {
        // Received → anything else via edit: give back the OLD lines.
        await _adjustStockInTxn(txn, _negate(oldQty));
      } else if (wasReceived && isReceivedNow && items != null) {
        // Received → received with new lines: net delta only.
        final delta = _qtyByProduct(items);
        for (final entry in oldQty.entries) {
          delta[entry.key] = (delta[entry.key] ?? 0) - entry.value;
        }
        await _adjustStockInTxn(txn, delta);
      }
      final updateMap = po.toMap()
        ..remove('id')
        ..['amount_paid'] = storedPaid;
      await txn.update('purchase_orders', updateMap,
          where: 'id = ?', whereArgs: [po.id]);
      if (items != null) {
        await txn.delete('purchase_order_items',
            where: 'purchase_order_id = ?', whereArgs: [po.id]);
        for (final item in items) {
          final itemMap = item.toMap()..['purchase_order_id'] = po.id;
          await txn.insert('purchase_order_items', itemMap);
        }
      }
    });
  }

  static Future<PurchaseOrder?> getPurchaseOrderById(String id) async {
    final db = await dbHelper.database;
    final maps =
        await db.query('purchase_orders', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    final items = await getItemsForOrder(id);
    return PurchaseOrder.fromMap(maps.first).copyWith(items: items);
  }

  static Future<List<PurchaseOrderItem>> getItemsForOrder(
      String orderId) async {
    final db = await dbHelper.database;
    final maps = await db.query('purchase_order_items',
        where: 'purchase_order_id = ?', whereArgs: [orderId]);
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

  /// Guarded status transition. Stock-moving states always go through the
  /// same transactional paths as [markAsReceived]/[cancelPurchaseOrder]:
  /// 'received' adds stock exactly once (idempotent), leaving 'received'
  /// for 'cancelled' reverses it. Non-stock transitions just restamp.
  static Future<void> updateStatus(String id, String status) async {
    if (status == 'received') {
      await markAsReceived(id);
      return;
    }
    final db = await dbHelper.database;
    // Period lock: status changes rewrite the order.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_orders', id: id, entity: 'Purchase order');
    await db.transaction((txn) async {
      final rows = await txn.query('purchase_orders',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw StateError('Purchase order not found');
      final current = rows.first['status'] as String? ?? 'draft';
      if (current == status) return;
      if (status == 'cancelled' && current == 'received') {
        final items = await txn.query('purchase_order_items',
            columns: ['product_id', 'quantity'],
            where: 'purchase_order_id = ?',
            whereArgs: [id]);
        await _adjustStockInTxn(
            txn, _negate(_qtyByProduct(items.map(PurchaseOrderItem.fromMap))));
      }
      await txn.update('purchase_orders', {'status': status},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Cancels a purchase order. A received order gives its lines back to
  /// on-hand stock in the same transaction that restamps it, so cancelling
  /// can never leak phantom stock. No-op when already cancelled.
  static Future<void> cancelPurchaseOrder(String id) async {
    final db = await dbHelper.database;
    // Period lock: cancelling restamps (and possibly de-stocks) the order.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_orders', id: id, entity: 'Purchase order');
    await db.transaction((txn) async {
      final rows = await txn.query('purchase_orders',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw StateError('Purchase order not found');
      final current = rows.first['status'] as String? ?? 'draft';
      if (current == 'cancelled') return;
      if (current == 'received') {
        final items = await txn.query('purchase_order_items',
            columns: ['product_id', 'quantity'],
            where: 'purchase_order_id = ?',
            whereArgs: [id]);
        await _adjustStockInTxn(
            txn, _negate(_qtyByProduct(items.map(PurchaseOrderItem.fromMap))));
      }
      await txn.update('purchase_orders', {'status': 'cancelled'},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Sums stockable quantities per product. Lines without a product link are
  /// skipped (ad-hoc lines that must not touch the catalogue).
  static Map<String, double> _qtyByProduct(Iterable<PurchaseOrderItem> items) {
    final result = <String, double>{};
    for (final item in items) {
      if (item.productId.isEmpty) continue;
      result[item.productId] = (result[item.productId] ?? 0) + item.quantity;
    }
    return result;
  }

  static Map<String, double> _negate(Map<String, double> delta) =>
      {for (final e in delta.entries) e.key: -e.value};

  /// Stock helper — all reads/writes go through [txn] so callers stay atomic.
  /// Skips missing products and products flagged unlimited_stock.
  static Future<void> _adjustStockInTxn(
    DatabaseExecutor txn,
    Map<String, double> deltaByProductId,
  ) async {
    for (final entry in deltaByProductId.entries) {
      if (entry.value.abs() <= 0.000001) continue;
      final rows = await txn.query('products',
          columns: ['stock', 'unlimited_stock'],
          where: 'id = ?',
          whereArgs: [entry.key],
          limit: 1);
      if (rows.isEmpty || (rows.first['unlimited_stock'] as int? ?? 0) == 1) {
        continue;
      }
      final stock = (rows.first['stock'] as num? ?? 0).toDouble();
      await txn.update('products', {'stock': stock + entry.value},
          where: 'id = ?', whereArgs: [entry.key]);
    }
  }

  /// Marks a purchase order received AND adds its lines to on-hand stock in a
  /// single transaction. Idempotent: returns false without touching stock
  /// when the order is already received (or cancelled), so a double-tap or a
  /// stale detail view can never double-add. Only lines linked to a product
  /// with limited stock move the needle.
  ///
  /// No schema change (stays db v51): bills carry no po_id, so a PO receive
  /// plus a separate purchase bill booked for the same goods would still
  /// double-add. That residual risk is inherent to the missing PO↔bill
  /// linkage, not to this path — each path is individually single-counting.
  static Future<bool> markAsReceived(String id) async {
    final db = await dbHelper.database;
    // Period lock: receiving books stock against the order date.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_orders', id: id, entity: 'Purchase order');
    var applied = false;
    await db.transaction((txn) async {
      final orders = await txn.query('purchase_orders',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (orders.isEmpty) throw StateError('Purchase order not found');
      final status = orders.first['status'] as String? ?? 'draft';
      if (status == 'received' || status == 'cancelled') return;
      final items = await txn.query('purchase_order_items',
          columns: ['product_id', 'quantity'],
          where: 'purchase_order_id = ?',
          whereArgs: [id]);
      for (final item in items) {
        final productId = item['product_id'] as String?;
        if (productId == null || productId.isEmpty) continue;
        final products = await txn.query('products',
            columns: ['stock', 'unlimited_stock'],
            where: 'id = ?',
            whereArgs: [productId],
            limit: 1);
        if (products.isEmpty ||
            (products.first['unlimited_stock'] as int? ?? 0) == 1) {
          continue;
        }
        final stock = (products.first['stock'] as num? ?? 0).toDouble();
        final qty = (item['quantity'] as num? ?? 0).toDouble();
        if (qty.abs() <= 0.000001) continue;
        await txn.update('products', {'stock': stock + qty},
            where: 'id = ?', whereArgs: [productId]);
      }
      await txn.update('purchase_orders', {'status': 'received'},
          where: 'id = ?', whereArgs: [id]);
      applied = true;
    });
    return applied;
  }

  static Future<void> deletePurchaseOrder(String id) async {
    final db = await dbHelper.database;
    // Period lock: a closed-period order cannot be removed.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_orders', id: id, entity: 'Purchase order');
    await db.transaction((txn) async {
      // A received order still holds its lines in on-hand stock: reverse
      // them (negative delta) in the same txn that removes the order, so a
      // delete can never leak phantom stock.
      final header = await txn.query('purchase_orders',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      final wasReceived = header.isNotEmpty &&
          (header.first['status'] as String? ?? 'draft') == 'received';
      if (wasReceived) {
        final items = await txn.query('purchase_order_items',
            columns: ['product_id', 'quantity'],
            where: 'purchase_order_id = ?',
            whereArgs: [id]);
        await _adjustStockInTxn(
            txn, _negate(_qtyByProduct(items.map(PurchaseOrderItem.fromMap))));
      }
      await txn.delete('purchase_order_items',
          where: 'purchase_order_id = ?', whereArgs: [id]);
      await txn.delete('purchase_orders', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// UUID mint (was MAX(CAST(id))+1): cross-device creation cannot collide
  /// on the sync wire. Legacy numeric-string ids remain readable.
  /// Display numbering stays in [generateNextOrderNumber] (untouched).
  static Future<String> generateNextId() async {
    return const Uuid().v4();
  }

  static Future<String> generateNextOrderNumber() async {
    final db = await dbHelper.database;
    final result = await db.rawQuery(
        "SELECT MAX(CAST(order_number AS INTEGER)) FROM purchase_orders WHERE order_number IS NOT NULL");
    final maxNum = Sqflite.firstIntValue(result) ?? 0;
    return (maxNum + 1).toString().padLeft(6, '0');
  }

  static Future<({double totalSpent, int totalOrders, double outstanding})>
      getPurchaseFinancials() async {
    final db = await dbHelper.database;
    final result = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(total_amount), 0) as total_spent,
        COUNT(*) as total_orders,
        COALESCE(SUM(total_amount - amount_paid), 0) as outstanding
      FROM purchase_orders
      WHERE status != 'cancelled'
    ''');
    if (result.isEmpty)
      return (totalSpent: 0.0, totalOrders: 0, outstanding: 0.0);
    return (
      totalSpent: (result.first['total_spent'] as num?)?.toDouble() ?? 0.0,
      totalOrders: (result.first['total_orders'] as num?)?.toInt() ?? 0,
      outstanding: (result.first['outstanding'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
