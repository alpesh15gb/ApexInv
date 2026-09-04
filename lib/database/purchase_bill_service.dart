import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'accounting_service.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/utils/app_logger.dart';

const _tag = 'PurchaseBillService';

/// CRUD for purchase bills (inward supplies). Change-capture triggers on
/// purchase_bills/purchase_bill_items feed the sync outbox automatically —
/// same contract as invoices.
class PurchaseBillService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertBill(PurchaseBill bill) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.insert('purchase_bills', _headerMap(bill));
      for (final item in bill.items) {
        await txn.insert('purchase_bill_items', item.toMap());
      }
      // Inward supply: stockable lines increase on-hand stock in the same
      // txn. Bills carry no po_id, so a bill and a PO receive for the same
      // goods would double-add — that residual risk is documented at the PO
      // Mark Received path rather than solved with schema.
      await _adjustStockInTxn(txn, _qtyByProduct(bill.items));
    });
  }

  static Future<void> updateBill(PurchaseBill bill) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final oldRows = await txn.query('purchase_bill_items',
          columns: ['product_id', 'quantity'],
          where: 'purchase_bill_id = ?',
          whereArgs: [bill.id]);
      await txn.update('purchase_bills', _headerMap(bill),
          where: 'id = ?', whereArgs: [bill.id]);
      await txn.delete('purchase_bill_items',
          where: 'purchase_bill_id = ?', whereArgs: [bill.id]);
      for (final item in bill.items) {
        await txn.insert('purchase_bill_items', item.toMap());
      }
      // Net delta vs the previous lines, so edits never double-count stock.
      final delta = _qtyByProduct(bill.items);
      for (final old in oldRows) {
        final productId = old['product_id'] as String?;
        if (productId == null || productId.isEmpty) continue;
        delta[productId] = (delta[productId] ?? 0) -
            (((old['quantity'] as num?)?.toDouble() ?? 0));
      }
      await _adjustStockInTxn(txn, delta);
    });
  }

  /// Sums stockable quantities per product. Lines without a product link are
  /// skipped (ad-hoc supplier lines that must not touch the catalogue).
  static Map<String, double> _qtyByProduct(Iterable<PurchaseBillItem> items) {
    final result = <String, double>{};
    for (final item in items) {
      final productId = item.productId;
      if (productId == null || productId.isEmpty) continue;
      result[productId] = (result[productId] ?? 0) + item.quantity;
    }
    return result;
  }

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

  static Map<String, dynamic> _headerMap(PurchaseBill bill) => {
        'id': bill.id,
        'bill_number': bill.billNumber,
        'supplier_name': bill.supplierName,
        'supplier_gstin': bill.supplierGstin,
        'supplier_phone': bill.supplierPhone,
        'supplier_email': bill.supplierEmail,
        'supplier_address': bill.supplierAddress,
        'date': bill.date.toIso8601String(),
        'due_date': bill.dueDate?.toIso8601String(),
        'total_amount': bill.totalAmount,
        'total_tax': bill.totalTax,
        'amount_paid': bill.amountPaid,
        'itc_eligible': bill.itcEligible ? 1 : 0,
        'reverse_charge': bill.reverseCharge ? 1 : 0,
        'price_includes_tax': bill.priceIncludesTax ? 1 : 0,
        'notes': bill.notes,
        'currency_code': bill.currencyCode,
        'currency_symbol': bill.currencySymbol,
      };

  static Future<void> softDeleteBill(String id) async {
    // purchase_bills has no deleted_at column; a remove is a hard delete and
    // the DELETE trigger tombstones it for sync.
    // Everything below commits in ONE transaction: each payment's cash
    // movement is reversed (individual movements plus any shared batch-group
    // movements, re-posted for surviving siblings of other bills), payment
    // rows are deleted, stocked quantities are given back, then items + bill
    // are deleted — leaving no orphan payments or financial_transactions.
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final payments = await txn.query('purchase_bill_payments',
          where: 'purchase_bill_id = ?', whereArgs: [id]);
      for (final p in payments) {
        final chequeId = p['cheque_id'] as String?;
        if (chequeId != null && chequeId.isNotEmpty) {
          await AccountingService.cancelChequeInTransaction(txn, chequeId,
              reason: 'Purchase bill deleted');
        } else {
          await AccountingService.reverseSourceInTransaction(txn,
              sourceType: 'purchase_bill_payment',
              sourceId: p['id'] as String,
              reason: 'Purchase bill deleted');
        }
      }
      final groupIds = payments
          .map((p) => p['payment_group_id'] as String?)
          .where((g) => g != null && g.isNotEmpty)
          .cast<String>()
          .toSet();
      for (final groupId in groupIds) {
        await AccountingService.reverseSourceInTransaction(txn,
            sourceType: 'payment_out_group',
            sourceId: groupId,
            reason: 'Purchase bill deleted');
      }
      await txn.delete('purchase_bill_payments',
          where: 'purchase_bill_id = ?', whereArgs: [id]);
      // A batch group can span several bills: re-post the group movement for
      // whatever sibling payments survive on other bills.
      for (final groupId in groupIds) {
        await _repostGroupMovement(txn, groupId);
      }
      final items = await txn.query('purchase_bill_items',
          columns: ['product_id', 'quantity'],
          where: 'purchase_bill_id = ?',
          whereArgs: [id]);
      final delta = <String, double>{};
      for (final item in items) {
        final productId = item['product_id'] as String?;
        if (productId == null || productId.isEmpty) continue;
        delta[productId] = (delta[productId] ?? 0) -
            (((item['quantity'] as num?)?.toDouble() ?? 0));
      }
      await _adjustStockInTxn(txn, delta);
      await txn.delete('purchase_bill_items',
          where: 'purchase_bill_id = ?', whereArgs: [id]);
      await txn.delete('purchase_bills', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<PurchaseBill?> getBill(String id) async {
    final db = await dbHelper.database;
    final rows = await db.query('purchase_bills',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final items = await db.query('purchase_bill_items',
        where: 'purchase_bill_id = ?', whereArgs: [id], orderBy: 'rowid');
    return _fromMaps(rows.first, items);
  }

  static Future<List<PurchaseBill>> getBills({
    String search = '',
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await dbHelper.database;
    final where = <String>[];
    final args = <dynamic>[];
    if (from != null) {
      where.add('date >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('date <= ?');
      args.add(to.toIso8601String());
    }
    if (where.isNotEmpty) where.join(' AND ');
    final rows = await db.query('purchase_bills',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: where.isEmpty ? null : args,
        orderBy: 'date DESC, rowid DESC');
    final result = <PurchaseBill>[];
    for (final r in rows) {
      final items = await db.query('purchase_bill_items',
          where: 'purchase_bill_id = ?',
          whereArgs: [r['id']],
          orderBy: 'rowid');
      result.add(_fromMaps(r, items));
    }
    return result;
  }

  static Future<PurchaseBillPayment> recordPayment(
    String id,
    double amount, {
    required DateTime datePaid,
    String? paymentMethod,
    String? notes,
    String? accountId,
    String? chequeNumber,
    DateTime? chequeDate,
    String? paymentGroupId,
  }) async {
    final db = await dbHelper.database;
    final bill = await getBill(id);
    if (bill == null) throw StateError('Purchase bill not found: $id');
    final recordedAmount = amount.clamp(0, bill.outstanding).toDouble();
    if (recordedAmount <= 0) throw StateError('Purchase bill is fully paid');
    final paid = bill.amountPaid + recordedAmount;
    final paymentId = const Uuid().v4();
    final isCheque = paymentMethod == 'Check';
    final payment = PurchaseBillPayment(
      id: paymentId,
      purchaseBillId: id,
      amountPaid: recordedAmount,
      previouslyPaid: bill.amountPaid,
      balanceAfter:
          (bill.totalAmount - paid).clamp(0, double.infinity).toDouble(),
      datePaid: datePaid,
      paymentMethod: paymentMethod,
      notes: notes,
      accountId: accountId,
      chequeStatus: isCheque ? 'pending' : 'none',
      paymentGroupId: paymentGroupId,
    );
    await db.transaction((txn) async {
      String? resolvedAccountId;
      String? chequeId;
      if (isCheque) {
        if ((chequeNumber?.trim().isEmpty ?? true) || chequeDate == null) {
          throw StateError('Cheque number and cheque date are required');
        }
        if (accountId != null) {
          resolvedAccountId = await AccountingService.resolveAccountId(txn,
              requestedAccountId: accountId,
              paymentMethod: 'Bank Transfer',
              currencyCode: bill.currencyCode,
              currencySymbol: bill.currencySymbol);
        }
        chequeId = await AccountingService.createCheque(txn,
            direction: 'issued',
            partyName: bill.supplierName,
            amount: recordedAmount,
            chequeNumber: chequeNumber!,
            chequeDate: chequeDate,
            sourceType: 'purchase_bill_payment',
            sourceId: paymentId,
            currencyCode: bill.currencyCode,
            currencySymbol: bill.currencySymbol,
            notes: notes ?? '');
      } else {
        resolvedAccountId = await AccountingService.resolveAccountId(txn,
            requestedAccountId: accountId,
            paymentMethod: paymentMethod,
            currencyCode: bill.currencyCode,
            currencySymbol: bill.currencySymbol);
        await AccountingService.insertMovement(txn,
            accountId: resolvedAccountId,
            kind: 'supplier_payment',
            amount: -recordedAmount,
            date: datePaid,
            sourceType: 'purchase_bill_payment',
            sourceId: paymentId,
            reference: bill.billNumber ?? bill.id,
            notes: notes ?? '');
      }
      final storedPayment = PurchaseBillPayment(
        id: payment.id,
        purchaseBillId: payment.purchaseBillId,
        amountPaid: payment.amountPaid,
        previouslyPaid: payment.previouslyPaid,
        balanceAfter: payment.balanceAfter,
        datePaid: payment.datePaid,
        paymentMethod: payment.paymentMethod,
        notes: payment.notes,
        accountId: resolvedAccountId,
        chequeId: chequeId,
        chequeStatus: payment.chequeStatus,
        paymentGroupId: payment.paymentGroupId,
      );
      await txn.insert('purchase_bill_payments', storedPayment.toMap());
      await txn.update('purchase_bills', {'amount_paid': paid},
          where: 'id = ?', whereArgs: [id]);
    });
    final rows = await db.query('purchase_bill_payments',
        where: 'id = ?', whereArgs: [paymentId], limit: 1);
    return PurchaseBillPayment.fromMap(rows.first);
  }

  static Future<List<PurchaseBillPayment>> getPayments(String billId) async {
    final db = await dbHelper.database;
    final rows = await db.query('purchase_bill_payments',
        where:
            "purchase_bill_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
        whereArgs: [billId],
        orderBy: 'date_paid ASC, rowid ASC');
    return rows.map(PurchaseBillPayment.fromMap).toList();
  }

  /// Applies one outgoing payment across several bills from the same supplier.
  /// The allocations and one cash/bank movement commit atomically.
  static Future<List<PurchaseBillPayment>> recordPaymentBatch({
    required List<({PurchaseBill bill, double amount})> allocations,
    required DateTime datePaid,
    required String paymentMethod,
    String? accountId,
    String? notes,
  }) async {
    final positive = allocations.where((a) => a.amount > 0).toList();
    if (positive.isEmpty) throw ArgumentError('Enter at least one allocation');
    if (paymentMethod == 'Check') {
      throw StateError('Issue a cheque against one bill at a time');
    }
    final suppliers = positive.map((a) => a.bill.supplierName).toSet();
    final currencies = positive.map((a) => a.bill.currencyCode).toSet();
    if (suppliers.length != 1 || currencies.length != 1) {
      throw StateError('A payment can cover one supplier and currency only');
    }
    for (final a in positive) {
      if (a.amount > a.bill.outstanding + 0.005) {
        throw StateError(
            'Allocation exceeds ${a.bill.billNumber ?? a.bill.id}');
      }
    }

    final db = await dbHelper.database;
    final groupId = const Uuid().v4();
    final saved = <PurchaseBillPayment>[];
    await db.transaction((txn) async {
      final first = positive.first.bill;
      final resolved = await AccountingService.resolveAccountId(txn,
          requestedAccountId: accountId,
          paymentMethod: paymentMethod,
          currencyCode: first.currencyCode,
          currencySymbol: first.currencySymbol);
      final total = positive.fold(0.0, (sum, a) => sum + a.amount);
      await AccountingService.insertMovement(txn,
          accountId: resolved,
          kind: 'supplier_payment',
          amount: -total,
          date: datePaid,
          sourceType: 'payment_out_group',
          sourceId: groupId,
          reference: first.supplierName,
          notes: notes ?? '');
      for (final allocation in positive) {
        final rows = await txn.query('purchase_bills',
            columns: ['amount_paid', 'total_amount'],
            where: 'id = ?',
            whereArgs: [allocation.bill.id],
            limit: 1);
        if (rows.isEmpty) throw StateError('Purchase bill no longer exists');
        final previous = (rows.first['amount_paid'] as num? ?? 0).toDouble();
        final billTotal = (rows.first['total_amount'] as num? ?? 0).toDouble();
        if (previous + allocation.amount > billTotal + 0.005) {
          throw StateError('A bill changed while the payment was being saved');
        }
        final payment = PurchaseBillPayment(
          id: const Uuid().v4(),
          purchaseBillId: allocation.bill.id,
          amountPaid: allocation.amount,
          previouslyPaid: previous,
          balanceAfter: (billTotal - previous - allocation.amount)
              .clamp(0, double.infinity)
              .toDouble(),
          datePaid: datePaid,
          paymentMethod: paymentMethod,
          notes: notes,
          accountId: resolved,
          paymentGroupId: groupId,
        );
        await txn.insert('purchase_bill_payments', payment.toMap());
        await txn.update(
            'purchase_bills', {'amount_paid': previous + allocation.amount},
            where: 'id = ?', whereArgs: [allocation.bill.id]);
        saved.add(payment);
      }
    });
    return saved;
  }

  static Future<void> deletePayment(PurchaseBillPayment payment) async {
    // Single transaction throughout: reversal + row delete + amount_paid
    // recalc commit together, so cash can never drift from the register.
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query('purchase_bill_payments',
          where: 'id = ?', whereArgs: [payment.id], limit: 1);
      if (rows.isEmpty) return;
      final row = rows.first;
      final billId = row['purchase_bill_id'] as String;
      final groupId = row['payment_group_id'] as String?;
      final chequeId = row['cheque_id'] as String?;
      if (chequeId != null && chequeId.isNotEmpty) {
        await AccountingService.cancelChequeInTransaction(txn, chequeId,
            reason: 'Purchase payment removed by administrator');
        await txn.delete('purchase_bill_payments',
            where: 'id = ?', whereArgs: [payment.id]);
      } else if (groupId != null && groupId.isNotEmpty) {
        // Batch allocation: one shared group movement covers every sibling.
        // Reverse the member (normally a no-op — batch members post no
        // individual movement) and the whole group movement, delete the row,
        // then re-post the group movement for the remaining siblings so cash
        // nets to exactly their total.
        await AccountingService.reverseSourceInTransaction(txn,
            sourceType: 'purchase_bill_payment',
            sourceId: payment.id,
            reason: 'Purchase payment removed by administrator');
        await AccountingService.reverseSourceInTransaction(txn,
            sourceType: 'payment_out_group',
            sourceId: groupId,
            reason: 'Purchase payment removed by administrator');
        await txn.delete('purchase_bill_payments',
            where: 'id = ?', whereArgs: [payment.id]);
        await _repostGroupMovement(txn, groupId);
      } else {
        await AccountingService.reverseSourceInTransaction(txn,
            sourceType: 'purchase_bill_payment',
            sourceId: payment.id,
            reason: 'Purchase payment removed by administrator');
        await txn.delete('purchase_bill_payments',
            where: 'id = ?', whereArgs: [payment.id]);
      }
      await txn.rawUpdate('''
        UPDATE purchase_bills SET amount_paid = COALESCE((
          SELECT SUM(amount_paid) FROM purchase_bill_payments
          WHERE purchase_bill_id = ?
            AND cheque_status NOT IN ('bounced', 'cancelled')
        ), 0) WHERE id = ?
      ''', [billId, billId]);
    });
  }

  /// Re-posts the shared `payment_out_group` movement for the surviving
  /// siblings of [groupId] (across all bills). The original movement row is
  /// used as a template so account/reference/notes are preserved. No-op when
  /// no live sibling remains — the full reversal then stands.
  static Future<void> _repostGroupMovement(
      DatabaseExecutor txn, String groupId) async {
    final siblings = await txn.query('purchase_bill_payments',
        where: 'payment_group_id = ?', whereArgs: [groupId]);
    final live = siblings.where((s) {
      final status = s['cheque_status'] as String? ?? 'none';
      return status != 'bounced' && status != 'cancelled';
    }).toList();
    final total = live.fold<double>(
        0, (sum, s) => sum + (((s['amount_paid'] as num?)?.toDouble() ?? 0)));
    if (total.abs() <= 0.000001) return;
    final template = await txn.query('financial_transactions',
        where: 'source_type = ? AND source_id = ? AND reversal_of IS NULL',
        whereArgs: ['payment_out_group', groupId],
        orderBy: 'rowid ASC',
        limit: 1);
    final accountId = template.isNotEmpty
        ? template.first['account_id'] as String?
        : live.first['account_id'] as String?;
    if (accountId == null || accountId.isEmpty) {
      throw StateError('Payment account no longer exists');
    }
    await AccountingService.insertMovement(txn,
        accountId: accountId,
        kind: 'supplier_payment',
        amount: -total,
        date: DateTime.tryParse(live.first['date_paid'] as String? ?? '') ??
            DateTime.now(),
        sourceType: 'payment_out_group',
        sourceId: groupId,
        reference: template.isNotEmpty
            ? (template.first['reference'] as String? ?? '')
            : '',
        notes: template.isNotEmpty
            ? (template.first['notes'] as String? ?? '')
            : '');
  }

  static PurchaseBill _fromMaps(
      Map<String, dynamic> header, List<Map<String, dynamic>> itemMaps) {
    return PurchaseBill(
      id: header['id'] as String,
      billNumber: header['bill_number'] as String?,
      supplierName: header['supplier_name'] as String? ?? '',
      supplierGstin: header['supplier_gstin'] as String? ?? '',
      supplierPhone: header['supplier_phone'] as String? ?? '',
      supplierEmail: header['supplier_email'] as String? ?? '',
      supplierAddress: header['supplier_address'] as String? ?? '',
      date:
          DateTime.tryParse(header['date'] as String? ?? '') ?? DateTime.now(),
      dueDate: DateTime.tryParse(header['due_date'] as String? ?? ''),
      totalAmount: (header['total_amount'] as num?)?.toDouble() ?? 0,
      totalTax: (header['total_tax'] as num?)?.toDouble() ?? 0,
      amountPaid: (header['amount_paid'] as num?)?.toDouble() ?? 0,
      itcEligible: (header['itc_eligible'] as int? ?? 1) == 1,
      reverseCharge: (header['reverse_charge'] as int? ?? 0) == 1,
      priceIncludesTax: (header['price_includes_tax'] as num?)?.toInt() == 1,
      notes: header['notes'] as String? ?? '',
      currencyCode: header['currency_code'] as String? ?? 'INR',
      currencySymbol: header['currency_symbol'] as String? ?? '₹',
      items: itemMaps.map(PurchaseBillItem.fromMap).toList(),
    );
  }
}

/// Audit-trail writer. Fire-and-forget — audit failures must never break a
/// business write.
class AuditLogService {
  static final dbHelper = DatabaseHelper();

  static Future<void> log({
    required String action,
    String? username,
    String? entity,
    String? entityId,
    String? details,
  }) async {
    try {
      final db = await dbHelper.database;
      await db.insert('audit_log', {
        'id': const Uuid().v4(),
        'username': username ?? 'system',
        'action': action,
        'entity': entity,
        'entity_id': entityId,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      AppLogger.e(_tag, 'audit log failed', e);
    }
  }

  static Future<List<Map<String, dynamic>>> recent({int limit = 500}) async {
    final db = await dbHelper.database;
    return db.query('audit_log', orderBy: 'created_at DESC', limit: limit);
  }
}
