import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/models/sale_order.dart';
import 'database_helper.dart';
import 'invoice_service.dart';

class SaleOrderService {
  static final _dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

  static Future<String> nextOrderNumber() async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT order_number FROM sale_orders
      ORDER BY CAST(REPLACE(order_number, 'SO-', '') AS INTEGER) DESC LIMIT 1
    ''');
    final last = rows.isEmpty
        ? 0
        : int.tryParse((rows.first['order_number'] as String? ?? '')
                .replaceAll(RegExp(r'\D'), '')) ??
            0;
    return 'SO-${(last + 1).toString().padLeft(5, '0')}';
  }

  static Future<List<SaleOrder>> getOrders({String? status}) async {
    final db = await _dbHelper.database;
    final headers = await db.query('sale_orders',
        where: status == null ? null : 'status = ?',
        whereArgs: status == null ? null : [status],
        orderBy: 'date DESC, rowid DESC');
    final result = <SaleOrder>[];
    for (final header in headers) {
      final items = await db.query('sale_order_items',
          where: 'sale_order_id = ?',
          whereArgs: [header['id']],
          orderBy: 'rowid');
      result.add(SaleOrder.fromMap(header,
          items: items.map(SaleOrderItem.fromMap).toList()));
    }
    return result;
  }

  static Future<SaleOrder?> getOrder(String id) async {
    final db = await _dbHelper.database;
    final rows = await db.query('sale_orders',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final items = await db.query('sale_order_items',
        where: 'sale_order_id = ?', whereArgs: [id], orderBy: 'rowid');
    return SaleOrder.fromMap(rows.first,
        items: items.map(SaleOrderItem.fromMap).toList());
  }

  static Future<void> saveOrder(SaleOrder order) async {
    if (order.customerName.trim().isEmpty || order.items.isEmpty) {
      throw ArgumentError('Customer and at least one item are required');
    }
    if (order.items.any((i) => i.quantity <= 0 || i.unitPrice < 0)) {
      throw ArgumentError('Every order line needs a positive quantity');
    }
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query('sale_orders',
          columns: ['status'],
          where: 'id = ?',
          whereArgs: [order.id],
          limit: 1);
      if (existing.isNotEmpty && existing.first['status'] != 'draft') {
        throw StateError('Only draft sale orders can be edited');
      }
      await txn.insert('sale_orders', order.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('sale_order_items',
          where: 'sale_order_id = ?', whereArgs: [order.id]);
      for (final item in order.items) {
        await txn.insert('sale_order_items', item.toMap());
      }
    });
  }

  static Future<Map<String, double>> getReservedQuantities() async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.product_id,
             COALESCE(SUM(i.quantity - i.fulfilled_quantity), 0) AS reserved
      FROM sale_order_items i
      JOIN sale_orders o ON o.id = i.sale_order_id
      WHERE o.status IN ('confirmed', 'partial')
      GROUP BY i.product_id
    ''');
    return {
      for (final row in rows)
        row['product_id'] as String:
            (row['reserved'] as num?)?.toDouble() ?? 0
    };
  }

  static Future<void> confirm(String id) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final orders = await txn.query('sale_orders',
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (orders.isEmpty) throw StateError('Sale order not found');
      if (orders.first['status'] != 'draft') {
        throw StateError('Only a draft sale order can be confirmed');
      }
      final items = await txn.query('sale_order_items',
          where: 'sale_order_id = ?', whereArgs: [id]);
      for (final item in items) {
        final productId = item['product_id'] as String;
        final products = await txn.query('products',
            columns: ['stock', 'unlimited_stock'],
            where: 'id = ?',
            whereArgs: [productId],
            limit: 1);
        if (products.isEmpty) {
          throw StateError('Product ${item['product_name']} no longer exists');
        }
        if ((products.first['unlimited_stock'] as int? ?? 0) == 1) continue;
        final reserved = await txn.rawQuery('''
          SELECT COALESCE(SUM(i.quantity - i.fulfilled_quantity), 0) AS qty
          FROM sale_order_items i JOIN sale_orders o ON o.id = i.sale_order_id
          WHERE i.product_id = ? AND i.sale_order_id <> ?
            AND o.status IN ('confirmed', 'partial')
        ''', [productId, id]);
        final available =
            (products.first['stock'] as num? ?? 0).toDouble() -
                (reserved.first['qty'] as num? ?? 0).toDouble();
        final requested = (item['quantity'] as num).toDouble();
        if (requested > available + 0.000001) {
          throw StateError(
              'Insufficient available stock for ${item['product_name']}');
        }
      }
      await txn.update('sale_orders', {'status': 'confirmed'},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> cancel(String id) async {
    final db = await _dbHelper.database;
    final rows = await db.query('sale_orders',
        columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return;
    if (rows.first['status'] == 'fulfilled') {
      throw StateError('A fulfilled order must be returned with a credit note');
    }
    await db.update('sale_orders', {'status': 'cancelled'},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteDraft(String id) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query('sale_orders',
          columns: ['status'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      if (rows.first['status'] != 'draft' &&
          rows.first['status'] != 'cancelled') {
        throw StateError('Confirmations must be cancelled before deletion');
      }
      await txn.delete('sale_order_items',
          where: 'sale_order_id = ?', whereArgs: [id]);
      await txn.delete('sale_orders', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Converts selected remaining quantities to one sales invoice. The invoice,
  /// stock deduction, and fulfillment counters commit in the same transaction.
  static Future<String> fulfillToInvoice(
    String orderId, {
    Map<String, double>? quantitiesByItemId,
  }) async {
    final order = await getOrder(orderId);
    if (order == null) throw StateError('Sale order not found');
    if (order.status != 'confirmed' && order.status != 'partial') {
      throw StateError('Confirm the sale order before fulfillment');
    }
    final selected = <SaleOrderItem, double>{};
    for (final item in order.items) {
      final qty = quantitiesByItemId?[item.id] ?? item.remainingQuantity;
      if (qty < -0.000001 || qty > item.remainingQuantity + 0.000001) {
        throw StateError('Invalid fulfillment quantity for ${item.productName}');
      }
      if (qty > 0.000001) selected[item] = qty;
    }
    if (selected.isEmpty) throw StateError('Nothing selected for fulfillment');

    final invoiceId = await InvoiceService.generateNextId();
    final invoiceNumber =
        await InvoiceService.generateNextInvoiceNumber('Invoice');
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      for (final entry in selected.entries) {
        final productRows = await txn.query('products',
            where: 'id = ?', whereArgs: [entry.key.productId], limit: 1);
        if (productRows.isEmpty) {
          throw StateError('Product ${entry.key.productName} no longer exists');
        }
        final product = productRows.first;
        if ((product['unlimited_stock'] as int? ?? 0) == 0) {
          final stock = (product['stock'] as num? ?? 0).toDouble();
          if (entry.value > stock + 0.000001) {
            throw StateError('Insufficient stock for ${entry.key.productName}');
          }
          await txn.update('products', {'stock': stock - entry.value},
              where: 'id = ?', whereArgs: [entry.key.productId]);
        }
      }

      await txn.insert('invoices', {
        'id': invoiceId,
        'invoice_number': invoiceNumber,
        'customer_id': order.customerId,
        'customer_name': order.customerName,
        'customer_email': order.customerEmail,
        'customer_phone': order.customerPhone,
        'customer_address': order.customerAddress,
        'customer_gstin': order.customerGstin,
        'customer_business_name': '',
        'date': DateTime.now().toIso8601String(),
        'notes': order.notes,
        'tax_rate': 0,
        'type': 'Invoice',
        'currency_code': order.currencyCode,
        'currency_symbol': order.currencySymbol,
        'tax_mode': 'item',
        'additional_costs': jsonEncode(<Object>[]),
        'invoice_discount_type': 'percent',
        'invoice_discount_value': 0,
        'is_interstate': 0,
        'payment_term_id': '',
        'custom_fields': '',
        'sales_channel': 'sale_order',
        'source_order_id': order.id,
      });
      for (final entry in selected.entries) {
        final item = entry.key;
        final productRows = await txn.query('products',
            where: 'id = ?', whereArgs: [item.productId], limit: 1);
        final product = productRows.first;
        await txn.insert('invoice_items', {
          'id': _uuid.v4(),
          'invoice_id': invoiceId,
          'product_id': item.productId,
          'product_name': item.productName,
          'product_description': item.description,
          'product_price': item.unitPrice,
          'product_tax_rate': item.taxRate.round(),
          'product_hsn_code': product['hsncode'] as String? ?? '',
          'quantity': entry.value,
          'discount': item.quantity <= 0
              ? 0
              : item.discount * entry.value / item.quantity,
          'unit_price': item.unitPrice,
          'extra_cost': 0,
          'discount_per_unit': 0,
          'is_product_saved': 1,
          'product_type': product['type'] as String? ?? 'product',
          'product_purchase_price':
              (product['purchase_price'] as num?)?.toDouble() ?? 0,
          'product_alias_name': product['alias_name'] as String?,
          'product_unit': product['unit'] as String? ?? '',
          'unit': product['unit'] as String? ?? '',
          'product_price_includes_tax':
              product['price_includes_tax'] as int? ?? 0,
          'description': item.description,
        });
        await txn.update(
            'sale_order_items',
            {
              'fulfilled_quantity': item.fulfilledQuantity + entry.value,
            },
            where: 'id = ?',
            whereArgs: [item.id]);
      }

      final remaining = await txn.rawQuery('''
        SELECT COALESCE(SUM(quantity - fulfilled_quantity), 0) AS qty
        FROM sale_order_items WHERE sale_order_id = ?
      ''', [order.id]);
      final fulfilled =
          (remaining.first['qty'] as num? ?? 0).toDouble() <= 0.000001;
      await txn.update(
          'sale_orders', {'status': fulfilled ? 'fulfilled' : 'partial'},
          where: 'id = ?', whereArgs: [order.id]);
    });
    return invoiceId;
  }
}
