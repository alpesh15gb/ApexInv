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
    });
  }

  static Future<void> updateBill(PurchaseBill bill) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await txn.update('purchase_bills', _headerMap(bill),
          where: 'id = ?', whereArgs: [bill.id]);
      await txn.delete('purchase_bill_items',
          where: 'purchase_bill_id = ?', whereArgs: [bill.id]);
      for (final item in bill.items) {
        await txn.insert('purchase_bill_items', item.toMap());
      }
    });
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
        'notes': bill.notes,
        'currency_code': bill.currencyCode,
        'currency_symbol': bill.currencySymbol,
      };

  static Future<void> softDeleteBill(String id) async {
    // purchase_bills has no deleted_at column; a remove is a hard delete and
    // the DELETE trigger tombstones it for sync.
    final db = await dbHelper.database;
    await db.transaction((txn) async {
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
        throw StateError('Allocation exceeds ${a.bill.billNumber ?? a.bill.id}');
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
    final db = await dbHelper.database;
    if (payment.chequeId != null) {
      await AccountingService.transitionCheque(
          chequeId: payment.chequeId!,
          status: payment.chequeStatus == 'cleared' ? 'bounced' : 'cancelled',
          notes: 'Purchase payment removed by administrator');
    } else {
      await AccountingService.reverseSource(
          sourceType: 'purchase_bill_payment',
          sourceId: payment.id,
          reason: 'Purchase payment removed by administrator');
    }
    await db.transaction((txn) async {
      await txn.delete('purchase_bill_payments',
          where: 'id = ?', whereArgs: [payment.id]);
      await txn.rawUpdate('''
        UPDATE purchase_bills SET amount_paid = COALESCE((
          SELECT SUM(amount_paid) FROM purchase_bill_payments
          WHERE purchase_bill_id = ?
            AND cheque_status NOT IN ('bounced', 'cancelled')
        ), 0) WHERE id = ?
      ''', [payment.purchaseBillId, payment.purchaseBillId]);
    });
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
