import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'accounting_service.dart';
import 'audit_log_service.dart';
import 'journal_store.dart';
import 'ledger_service.dart';
import 'period_lock_service.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/purchase_bill.dart';

/// CRUD for purchase bills (inward supplies). Change-capture triggers on
/// purchase_bills/purchase_bill_items feed the sync outbox automatically —
/// same contract as invoices.
class PurchaseBillService {
  static final dbHelper = DatabaseHelper();

  /// Live payment-rows sum with the ledger's cheque filter (bounced /
  /// cancelled never count). Matches the projection's `recorded_paid`.
  static Future<double> _recordedPaid(
      DatabaseExecutor txn, String billId) async {
    final rows = await txn.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN COALESCE(cheque_status, 'none') NOT IN ('bounced', 'cancelled') THEN amount_paid ELSE 0 END), 0) AS v FROM purchase_bill_payments WHERE purchase_bill_id = ?",
        [billId]);
    return (rows.first['v'] as num?)?.toDouble() ?? 0;
  }

  /// Persisted purchase-bill posting for [bill] in the caller's transaction.
  static Future<void> _postBillJournal(
      DatabaseExecutor txn, PurchaseBill bill, double amountPaidColumn) async {
    final recorded = await _recordedPaid(txn, bill.id);
    await JournalStore.postBuilt(
        txn,
        LedgerPostings.purchaseEntry(
          date: bill.date,
          supplierName: bill.supplierName,
          currencySymbol: bill.currencySymbol,
          currencyCode: bill.currencyCode,
          total: bill.totalAmount,
          tax: bill.totalTax,
          amountPaidColumn: amountPaidColumn,
          recordedPaid: recorded,
          itcEligible: bill.itcEligible,
          reverseCharge: bill.reverseCharge,
          sourceId: bill.id,
        ));
  }

  /// Persisted purchase-payment posting for one payment row.
  static Future<void> _postPaymentJournal(
    DatabaseExecutor txn, {
    required String supplierName,
    required String currencyCode,
    required String paymentId,
    required double amount,
    required DateTime datePaid,
    String? paymentMethod,
    String? accountId,
  }) async {
    final method = paymentMethod ?? 'Cash';
    final String account;
    if (paymentMethod == 'Check') {
      account = LedgerService.accChequesIssued;
    } else {
      final rows = await txn.query('financial_accounts',
          columns: ['type', 'name'],
          where: 'id = ?',
          whereArgs: [accountId],
          limit: 1);
      account = JournalStore.accountDisplay(rows.isEmpty ? null : rows.first,
          fallback:
              method == 'Cash' ? LedgerService.accCash : LedgerService.accBank);
    }
    await JournalStore.postBuilt(
        txn,
        LedgerPostings.purchasePaymentEntry(
          date: datePaid,
          supplierName: supplierName,
          amount: amount,
          account: account,
          currencyCode: currencyCode,
          sourceId: paymentId,
        ));
  }

  static Future<void> insertBill(PurchaseBill bill, {String? actor}) async {
    // Period lock: backdated bills into a closed period are refused.
    await PeriodLockService.assertDateUnlocked(bill.date,
        entity: 'Purchase bill');
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
      // Persisted double-entry posting in the same transaction.
      await _postBillJournal(txn, bill, bill.amountPaid);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.purchaseBillCreate,
        username: AuditActor.resolve(actor),
        entity: 'purchase_bills',
        entityId: bill.id,
        details:
            '${bill.supplierName} · total: ${bill.totalAmount.toStringAsFixed(2)}',
      );
    });
  }

  static Future<void> updateBill(PurchaseBill bill, {String? actor}) async {
    final db = await dbHelper.database;
    // Period lock: refuse edits whose stored bill OR new date is closed.
    await PeriodLockService.assertDateUnlocked(bill.date,
        entity: 'Purchase bill');
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_bills', id: bill.id, entity: 'Purchase bill');
    await db.transaction((txn) async {
      final beforeRows = await txn.query('purchase_bills',
          where: 'id = ?', whereArgs: [bill.id], limit: 1);
      final beforeSupplier = beforeRows.isEmpty
          ? null
          : beforeRows.first['supplier_name'] as String?;
      final beforeTotal = beforeRows.isEmpty
          ? null
          : (beforeRows.first['total_amount'] as num?)?.toDouble();
      // Overpay guard (mirrors the sales-side updateInvoice check): the
      // header's amount_paid may be stale, so recompute what the supplier
      // already received from live payment rows and refuse to shrink the
      // payable total below it. RC bills owe the net, not the gross.
      final paidRows = await txn.rawQuery(
        "SELECT COALESCE(SUM(amount_paid), 0.0) AS paid FROM purchase_bill_payments WHERE purchase_bill_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
        [bill.id],
      );
      final livePaid = (paidRows.first['paid'] as num?)?.toDouble() ?? 0.0;
      if (livePaid > bill.payableTotal + 0.005) {
        throw StateError('Purchase bill total below amount already paid');
      }
      final oldRows = await txn.query('purchase_bill_items',
          columns: ['product_id', 'quantity'],
          where: 'purchase_bill_id = ?',
          whereArgs: [bill.id]);
      final header = _headerMap(bill)..['amount_paid'] = livePaid;
      await txn.update('purchase_bills', header,
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
      // Mirror the previous posting, then book the edited bill — same txn.
      await JournalStore.reverseSource(txn,
          sourceType: JournalStore.srcPurchaseBill, sourceId: bill.id);
      await _postBillJournal(txn, bill, livePaid);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.purchaseBillUpdate,
        username: AuditActor.resolve(actor),
        entity: 'purchase_bills',
        entityId: bill.id,
        details: AuditLogService.diff({
          'total': (beforeTotal, bill.totalAmount),
          'supplier': (beforeSupplier, bill.supplierName),
        }),
      );
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

  static Future<void> softDeleteBill(String id, {String? actor}) async {
    // purchase_bills has no deleted_at column; a remove is a hard delete and
    // the DELETE trigger tombstones it for sync.
    // Everything below commits in ONE transaction: each payment's cash
    // movement is reversed (individual movements plus any shared batch-group
    // movements, re-posted for surviving siblings of other bills), payment
    // rows are deleted, stocked quantities are given back, then items + bill
    // are deleted — leaving no orphan payments or financial_transactions.
    final db = await dbHelper.database;
    // Period lock: a closed-period bill cannot be removed.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_bills', id: id, entity: 'Purchase bill');
    await db.transaction((txn) async {
      final billRows = await txn.query('purchase_bills',
          where: 'id = ?', whereArgs: [id], limit: 1);
      final beforeSupplier = billRows.isEmpty
          ? ''
          : billRows.first['supplier_name'] as String? ?? '';
      final beforeTotal = billRows.isEmpty
          ? 0.0
          : (billRows.first['total_amount'] as num?)?.toDouble() ?? 0.0;
      final payments = await txn.query('purchase_bill_payments',
          where: 'purchase_bill_id = ?', whereArgs: [id]);
      for (final p in payments) {
        final chequeId = p['cheque_id'] as String?;
        if (chequeId != null && chequeId.isNotEmpty) {
          await AccountingService.cancelChequeInTransaction(txn, chequeId,
              reason: 'Purchase bill deleted');
          // The cheque transition mirrors the cheque-clear posting; mirror
          // the payment leg here too (idempotent).
          await JournalStore.reverseSource(txn,
              sourceType: JournalStore.srcChequeClear, sourceId: chequeId);
        } else {
          await AccountingService.reverseSourceInTransaction(txn,
              sourceType: 'purchase_bill_payment',
              sourceId: p['id'] as String,
              reason: 'Purchase bill deleted');
        }
        await JournalStore.reverseSource(txn,
            sourceType: JournalStore.srcPurchasePayment,
            sourceId: p['id'] as String);
      }
      // The bill itself leaves the ledger: mirror its posting.
      await JournalStore.reverseSource(txn,
          sourceType: JournalStore.srcPurchaseBill, sourceId: id);
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
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.purchaseBillDelete,
        username: AuditActor.resolve(actor),
        entity: 'purchase_bills',
        entityId: id,
        details:
            '$beforeSupplier · total: ${beforeTotal.toStringAsFixed(2)} → —',
      );
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
    String? actor,
  }) async {
    if (!amount.isFinite) {
      throw ArgumentError('Payment amount must be a finite number');
    }
    // Period lock: no supplier payments may be posted into a closed period.
    await PeriodLockService.assertDateUnlocked(datePaid,
        entity: 'Purchase payment');
    final db = await dbHelper.database;
    final bill = await getBill(id);
    if (bill == null) throw StateError('Purchase bill not found: $id');
    // Overpay policy matches the sales side (PaymentService.addPayment):
    // throw when amount exceeds the outstanding balance (with epsilon)
    // instead of silently clamping. The in-txn re-read below is authoritative;
    // this stale-header check is only a fast fail.
    const epsilon = 0.005;
    if (amount <= epsilon || amount > bill.outstanding + epsilon) {
      throw StateError('Payment must be within the outstanding balance');
    }
    final paymentId = const Uuid().v4();
    final isCheque = paymentMethod == 'Check';
    await db.transaction((txn) async {
      // Re-read outstanding inside the txn like the batch path does: the
      // header above may be stale if another payment committed between the
      // getBill and this transaction.
      final fresh = await txn.query('purchase_bills',
          columns: [
            'amount_paid',
            'total_amount',
            'total_tax',
            'reverse_charge',
            'itc_eligible'
          ],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1);
      if (fresh.isEmpty) throw StateError('Purchase bill no longer exists');
      final previous = (fresh.first['amount_paid'] as num? ?? 0).toDouble();
      final isRc = (fresh.first['reverse_charge'] as int? ?? 0) == 1 &&
          (fresh.first['itc_eligible'] as int? ?? 1) == 1;
      final billPayable =
          ((fresh.first['total_amount'] as num? ?? 0).toDouble()) -
              (isRc ? ((fresh.first['total_tax'] as num? ?? 0).toDouble()) : 0);
      if (amount <= epsilon || previous + amount > billPayable + epsilon) {
        throw StateError('Payment must be within the outstanding balance');
      }
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
            amount: amount,
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
            amount: -amount,
            date: datePaid,
            sourceType: 'purchase_bill_payment',
            sourceId: paymentId,
            reference: bill.billNumber ?? bill.id,
            notes: notes ?? '');
      }
      final storedPayment = PurchaseBillPayment(
        id: paymentId,
        purchaseBillId: id,
        amountPaid: amount,
        previouslyPaid: previous,
        balanceAfter: (billPayable - previous - amount)
            .clamp(0, double.infinity)
            .toDouble(),
        datePaid: datePaid,
        paymentMethod: paymentMethod,
        notes: notes,
        accountId: resolvedAccountId,
        chequeId: chequeId,
        chequeStatus: isCheque ? 'pending' : 'none',
        paymentGroupId: paymentGroupId,
      );
      await txn.insert('purchase_bill_payments', storedPayment.toMap());
      await txn.update('purchase_bills', {'amount_paid': previous + amount},
          where: 'id = ?', whereArgs: [id]);
      // Persisted purchase-payment posting in the same transaction. Cheque
      // tenders post to Cheques Issued until the cheque clears.
      await _postPaymentJournal(txn,
          supplierName: bill.supplierName,
          currencyCode: bill.currencyCode,
          paymentId: paymentId,
          amount: amount,
          datePaid: datePaid,
          paymentMethod: paymentMethod,
          accountId: resolvedAccountId);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.purchasePaymentAdd,
        username: AuditActor.resolve(actor),
        entity: 'purchase_bill_payments',
        entityId: paymentId,
        details:
            'bill: $id · amount: ${amount.toStringAsFixed(2)} · paid: ${previous.toStringAsFixed(2)} → ${(previous + amount).toStringAsFixed(2)}',
      );
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
    String? actor,
  }) async {
    if (allocations.any((a) => !a.amount.isFinite)) {
      throw ArgumentError('Allocation amounts must be finite numbers');
    }
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
    // Period lock: the whole batch posts on [datePaid].
    await PeriodLockService.assertDateUnlocked(datePaid,
        entity: 'Purchase payment');

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
            columns: [
              'amount_paid',
              'total_amount',
              'total_tax',
              'reverse_charge',
              'itc_eligible'
            ],
            where: 'id = ?',
            whereArgs: [allocation.bill.id],
            limit: 1);
        if (rows.isEmpty) throw StateError('Purchase bill no longer exists');
        final previous = (rows.first['amount_paid'] as num? ?? 0).toDouble();
        // RC bills owe the net, matching the model outstanding above.
        final isRc = (rows.first['reverse_charge'] as int? ?? 0) == 1 &&
            (rows.first['itc_eligible'] as int? ?? 1) == 1;
        final billPayable = (rows.first['total_amount'] as num? ?? 0)
                .toDouble() -
            (isRc ? ((rows.first['total_tax'] as num? ?? 0).toDouble()) : 0);
        if (previous + allocation.amount > billPayable + 0.005) {
          throw StateError('A bill changed while the payment was being saved');
        }
        final payment = PurchaseBillPayment(
          id: const Uuid().v4(),
          purchaseBillId: allocation.bill.id,
          amountPaid: allocation.amount,
          previouslyPaid: previous,
          balanceAfter: (billPayable - previous - allocation.amount)
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
        // One persisted posting per allocated row (the projection books one
        // entry per payment row, not per group movement).
        await _postPaymentJournal(txn,
            supplierName: allocation.bill.supplierName,
            currencyCode: allocation.bill.currencyCode,
            paymentId: payment.id,
            amount: allocation.amount,
            datePaid: datePaid,
            paymentMethod: paymentMethod,
            accountId: resolved);
        await AuditLogService.logInTxn(
          txn,
          action: AuditActions.purchasePaymentAdd,
          username: AuditActor.resolve(actor),
          entity: 'purchase_bill_payments',
          entityId: payment.id,
          details:
              'bill: ${allocation.bill.id} · amount: ${allocation.amount.toStringAsFixed(2)} · paid: ${previous.toStringAsFixed(2)} → ${(previous + allocation.amount).toStringAsFixed(2)}',
        );
        saved.add(payment);
      }
    });
    return saved;
  }

  static Future<void> deletePayment(PurchaseBillPayment payment,
      {String? actor}) async {
    // Single transaction throughout: reversal + row delete + amount_paid
    // recalc commit together, so cash can never drift from the register.
    final db = await dbHelper.database;
    // Period lock: a closed-period supplier payment cannot be removed.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'purchase_bill_payments',
        id: payment.id,
        dateColumn: 'date_paid',
        entity: 'Purchase payment');
    await db.transaction((txn) async {
      final rows = await txn.query('purchase_bill_payments',
          where: 'id = ?', whereArgs: [payment.id], limit: 1);
      if (rows.isEmpty) return;
      final row = rows.first;
      final billId = row['purchase_bill_id'] as String;
      final beforeAmount = (row['amount_paid'] as num?)?.toDouble() ?? 0;
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
      // Mirror the persisted purchase-payment posting (and the cheque-clear
      // posting when a cheque was involved — the cancel path above already
      // mirrors the clear leg; this is idempotent). The deleted row leaves
      // the projection, so both sides net to zero.
      await JournalStore.reverseSource(txn,
          sourceType: JournalStore.srcPurchasePayment, sourceId: payment.id);
      if (chequeId != null && chequeId.isNotEmpty) {
        await JournalStore.reverseSource(txn,
            sourceType: JournalStore.srcChequeClear, sourceId: chequeId);
      }
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.purchasePaymentDelete,
        username: AuditActor.resolve(actor),
        entity: 'purchase_bill_payments',
        entityId: payment.id,
        details:
            'bill: $billId · amount: ${beforeAmount.toStringAsFixed(2)} → —',
      );
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
