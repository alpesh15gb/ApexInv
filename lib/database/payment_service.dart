import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/payment_receipt_numbers.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_payment.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'package:apexbooks/utils/app_logger.dart';
import 'accounting_service.dart';
import 'audit_log_service.dart';
import 'database_helper.dart';
import 'journal_store.dart';
import 'ledger_service.dart';
import 'period_lock_service.dart';

const _tag = 'PaymentService';

class PaymentService {
  static final _dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

  /// True when [e] is a UNIQUE failure on the receipt-number index (concurrent
  /// MAX-suffix reads picked the same next suffix). Callers retry the whole
  /// transaction so the loser re-reads MAX and takes the next suffix.
  static bool _isReceiptNumberConflict(Object e) {
    if (e is! DatabaseException) return false;
    final msg = e.toString();
    return msg.contains('UNIQUE constraint failed') &&
        msg.contains('receipt_number');
  }

  /// Posts the persisted receipt entry for one invoice payment, resolving
  /// the same cash/bank display account the projection derives. Cheque
  /// tenders post to Cheques In Hand until the cheque clears.
  static Future<void> _postReceiptJournal(
    DatabaseExecutor txn, {
    required Invoice invoice,
    required String paymentId,
    required double amountPaid,
    required DateTime datePaid,
    String? paymentMethod,
    String? accountId,
  }) async {
    final method = paymentMethod ?? 'Cash';
    final String account;
    if (paymentMethod == 'Check') {
      account = LedgerService.accChequesInHand;
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
        LedgerPostings.receiptEntry(
          date: datePaid,
          customerName: invoice.customer.name,
          method: method,
          amount: amountPaid,
          account: account,
          currencyCode: invoice.currencyCode,
          sourceId: paymentId,
        ));
  }

  // ─────────────────────────────────────────────
  // Add a payment — all snapshot fields computed inside a transaction.
  // Returns the fully populated InvoicePayment that was persisted.
  static Future<InvoicePayment> addPayment({
    required Invoice invoice,
    required double amountPaid,
    required DateTime datePaid,
    String? paymentMethod,
    String? notes,
    String? chequeNumber,
    DateTime? chequeDate,
    String? accountId,
    String? actor,
  }) async {
    if (!amountPaid.isFinite) {
      throw ArgumentError('Payment amount must be a finite number');
    }
    // Period lock: no receipts may be posted into a closed period.
    await PeriodLockService.assertDateUnlocked(datePaid, entity: 'Payment');
    final db = await _dbHelper.database;
    // Retry on receipt-number UNIQUE conflicts: two concurrent txns can read
    // the same MAX suffix and pick the same next number; the loser re-reads
    // MAX and takes the next suffix. Bounded so a real bug still surfaces.
    for (var attempt = 0;; attempt++) {
      try {
        late InvoicePayment saved;

        await db.transaction((txn) async {
          // 1. Snapshot: total already paid before this installment
          final sumResult = await txn.rawQuery(
            "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
            [invoice.id],
          );
          final previouslyPaid = (sumResult.first['total'] as num).toDouble();

          // 2. Determine next receipt suffix using MAX to avoid reuse after deletions
          final suffixResult = await txn.rawQuery(
            'SELECT receipt_number FROM invoice_payments WHERE invoice_id = ?',
            [invoice.id],
          );
          final receiptNumber = PaymentReceiptNumbers.nextReceiptNumber(
            invoiceId: invoice.id,
            existingReceiptNumbers:
                suffixResult.map((row) => row['receipt_number'] as String?),
          );

          // Payable (rounded when the invoice opts in) is what the customer
          // owes; the tax split stays proportional to exact figures.
          final payable = invoice.payableTotal;
          // 3. Compute tax portion proportionally
          final taxAmountPaid = invoice.total > 0
              ? (amountPaid * (invoice.tax / invoice.total))
              : 0.0;

          // 4. Snapshot: balance remaining after this installment
          final balanceAfter = InvoiceCalculator.outstanding(
            total: payable,
            paid: previouslyPaid + amountPaid,
          );

          if (amountPaid <= InvoiceCalculator.moneyEpsilon ||
              amountPaid >
                  payable - previouslyPaid + InvoiceCalculator.moneyEpsilon) {
            throw StateError('Payment must be within the outstanding balance');
          }
          final paymentId = _uuid.v4();
          final isCheque = paymentMethod == 'Check';
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
                  currencyCode: invoice.currencyCode,
                  currencySymbol: invoice.currencySymbol);
            }
            chequeId = await AccountingService.createCheque(txn,
                direction: 'received',
                partyName: invoice.customer.name,
                amount: amountPaid,
                chequeNumber: chequeNumber!,
                chequeDate: chequeDate,
                sourceType: 'invoice_payment',
                sourceId: paymentId,
                currencyCode: invoice.currencyCode,
                currencySymbol: invoice.currencySymbol,
                notes: notes ?? '');
          } else {
            resolvedAccountId = await AccountingService.resolveAccountId(txn,
                requestedAccountId: accountId,
                paymentMethod: paymentMethod,
                currencyCode: invoice.currencyCode,
                currencySymbol: invoice.currencySymbol);
            await AccountingService.insertMovement(txn,
                accountId: resolvedAccountId,
                kind: 'customer_receipt',
                amount: amountPaid,
                date: datePaid,
                sourceType: 'invoice_payment',
                sourceId: paymentId,
                reference: receiptNumber,
                notes: notes ?? '');
          }

          saved = InvoicePayment(
            id: paymentId,
            invoiceId: invoice.id,
            invoiceNumber: invoice.invoiceNumber ?? invoice.id,
            receiptNumber: receiptNumber,
            amountPaid: amountPaid,
            taxAmountPaid: taxAmountPaid,
            previouslyPaid: previouslyPaid,
            balanceAfter: balanceAfter,
            datePaid: datePaid,
            paymentMethod: paymentMethod,
            notes: notes,
            chequeNumber: chequeNumber,
            chequeDate: chequeDate,
            chequeCleared: false,
            accountId: resolvedAccountId,
            chequeId: chequeId,
            chequeStatus: isCheque ? 'pending' : 'none',
          );

          await txn.insert('invoice_payments', saved.toMap());
          await _postReceiptJournal(txn,
              invoice: invoice,
              paymentId: paymentId,
              amountPaid: amountPaid,
              datePaid: datePaid,
              paymentMethod: paymentMethod,
              accountId: resolvedAccountId);
          await AuditLogService.logInTxn(
            txn,
            action: AuditActions.paymentAdd,
            username: AuditActor.resolve(actor),
            entity: 'invoice_payments',
            entityId: paymentId,
            details:
                'invoice: ${invoice.invoiceNumber ?? invoice.id} · amount: ${amountPaid.toStringAsFixed(2)} · paid: ${previouslyPaid.toStringAsFixed(2)} → ${(previouslyPaid + amountPaid).toStringAsFixed(2)} · balance: ${balanceAfter.toStringAsFixed(2)}',
          );
          AppLogger.d(
              _tag, 'Payment added: ${saved.receiptNumber} — ₹$amountPaid');
        });

        return saved;
      } on DatabaseException catch (e) {
        if (attempt >= 4 || !_isReceiptNumberConflict(e)) rethrow;
      }
    }
  }

  // ─────────────────────────────────────────────
  // Batch mark-as-paid: single DB transaction for N invoices.
  // Skips invoices that are already paid within the standard money tolerance.
  static Future<int> addPaymentBatch({
    required List<Invoice> invoices,
    required DateTime datePaid,
    String? paymentMethod,
    String? notes,
    String? accountId,
    String? actor,
  }) async {
    if (paymentMethod == 'Check') {
      throw StateError('Record cheque payments individually');
    }
    // Period lock: the whole batch posts on [datePaid].
    await PeriodLockService.assertDateUnlocked(datePaid, entity: 'Payment');
    final db = await _dbHelper.database;
    for (var attempt = 0;; attempt++) {
      try {
        int count = 0;
        await db.transaction((txn) async {
          for (final invoice in invoices) {
            final paidResult = await txn.rawQuery(
              "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
              [invoice.id],
            );
            final previouslyPaid =
                (paidResult.first['total'] as num).toDouble();
            final amountPaid = InvoiceCalculator.outstanding(
                total: invoice.payableTotal, paid: previouslyPaid);
            if (amountPaid <= InvoiceCalculator.moneyEpsilon) continue;

            final suffixResult = await txn.rawQuery(
              'SELECT receipt_number FROM invoice_payments WHERE invoice_id = ?',
              [invoice.id],
            );
            final receiptNumber = PaymentReceiptNumbers.nextReceiptNumber(
              invoiceId: invoice.id,
              existingReceiptNumbers:
                  suffixResult.map((row) => row['receipt_number'] as String?),
            );

            final taxAmountPaid = invoice.total > 0
                ? (amountPaid * (invoice.tax / invoice.total))
                : 0.0;

            final payment = InvoicePayment(
              id: _uuid.v4(),
              invoiceId: invoice.id,
              invoiceNumber: invoice.invoiceNumber ?? invoice.id,
              receiptNumber: receiptNumber,
              amountPaid: amountPaid,
              taxAmountPaid: taxAmountPaid,
              previouslyPaid: previouslyPaid,
              balanceAfter: 0.0,
              datePaid: datePaid,
              paymentMethod: paymentMethod,
              notes: notes,
              accountId: await AccountingService.resolveAccountId(txn,
                  requestedAccountId: accountId,
                  paymentMethod: paymentMethod,
                  currencyCode: invoice.currencyCode,
                  currencySymbol: invoice.currencySymbol),
            );

            await txn.insert('invoice_payments', payment.toMap());
            await AccountingService.insertMovement(txn,
                accountId: payment.accountId!,
                kind: 'customer_receipt',
                amount: amountPaid,
                date: datePaid,
                sourceType: 'invoice_payment',
                sourceId: payment.id,
                reference: receiptNumber,
                notes: notes ?? '');
            await _postReceiptJournal(txn,
                invoice: invoice,
                paymentId: payment.id,
                amountPaid: amountPaid,
                datePaid: datePaid,
                paymentMethod: paymentMethod,
                accountId: payment.accountId);
            await AuditLogService.logInTxn(
              txn,
              action: AuditActions.paymentAdd,
              username: AuditActor.resolve(actor),
              entity: 'invoice_payments',
              entityId: payment.id,
              details:
                  'invoice: ${invoice.invoiceNumber ?? invoice.id} · amount: ${amountPaid.toStringAsFixed(2)} · paid: ${previouslyPaid.toStringAsFixed(2)} → ${(previouslyPaid + amountPaid).toStringAsFixed(2)}',
            );
            count++;
          }
        });
        AppLogger.d(_tag, 'Batch payment: $count invoice(s) marked as paid.');
        return count;
      } on DatabaseException catch (e) {
        if (attempt >= 4 || !_isReceiptNumberConflict(e)) rethrow;
      }
    }
  }

  // ─────────────────────────────────────────────
  // Apply one payment split across multiple invoices (e.g. FIFO-allocated
  // against a customer's oldest open invoices). Amounts are decided by the
  // caller; this only persists them, one InvoicePayment per invoice with a
  // positive amount, snapshotting previouslyPaid/balanceAfter per invoice
  // the same way addPayment does.
  static Future<List<InvoicePayment>> applyPaymentAcrossInvoices({
    required List<({Invoice invoice, double amount})> allocations,
    required DateTime datePaid,
    String? paymentMethod,
    String? notes,
    String? accountId,
    String? actor,
  }) async {
    if (paymentMethod == 'Check') {
      throw StateError('Record cheque payments individually');
    }
    // Period lock: every allocation posts on [datePaid].
    await PeriodLockService.assertDateUnlocked(datePaid, entity: 'Payment');
    final db = await _dbHelper.database;
    for (var attempt = 0;; attempt++) {
      try {
        final saved = <InvoicePayment>[];
        await db.transaction((txn) async {
          for (final a in allocations) {
            final invoice = a.invoice;
            final amountPaid = a.amount;
            if (!amountPaid.isFinite) {
              throw ArgumentError('Payment amount must be a finite number');
            }
            if (amountPaid <= InvoiceCalculator.moneyEpsilon) continue;

            final sumResult = await txn.rawQuery(
              "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
              [invoice.id],
            );
            final previouslyPaid = (sumResult.first['total'] as num).toDouble();
            final outstanding = InvoiceCalculator.outstanding(
                total: invoice.payableTotal, paid: previouslyPaid);
            if (amountPaid > outstanding + InvoiceCalculator.moneyEpsilon) {
              throw StateError(
                  'Payment must be within the outstanding balance');
            }

            final suffixResult = await txn.rawQuery(
              'SELECT receipt_number FROM invoice_payments WHERE invoice_id = ?',
              [invoice.id],
            );
            final receiptNumber = PaymentReceiptNumbers.nextReceiptNumber(
              invoiceId: invoice.id,
              existingReceiptNumbers:
                  suffixResult.map((row) => row['receipt_number'] as String?),
            );

            final taxAmountPaid = invoice.total > 0
                ? (amountPaid * (invoice.tax / invoice.total))
                : 0.0;

            final balanceAfter = InvoiceCalculator.outstanding(
              total: invoice.payableTotal,
              paid: previouslyPaid + amountPaid,
            );

            final payment = InvoicePayment(
              id: _uuid.v4(),
              invoiceId: invoice.id,
              invoiceNumber: invoice.invoiceNumber ?? invoice.id,
              receiptNumber: receiptNumber,
              amountPaid: amountPaid,
              taxAmountPaid: taxAmountPaid,
              previouslyPaid: previouslyPaid,
              balanceAfter: balanceAfter,
              datePaid: datePaid,
              paymentMethod: paymentMethod,
              notes: notes,
              accountId: await AccountingService.resolveAccountId(txn,
                  requestedAccountId: accountId,
                  paymentMethod: paymentMethod,
                  currencyCode: invoice.currencyCode,
                  currencySymbol: invoice.currencySymbol),
            );

            await txn.insert('invoice_payments', payment.toMap());
            await AccountingService.insertMovement(txn,
                accountId: payment.accountId!,
                kind: 'customer_receipt',
                amount: amountPaid,
                date: datePaid,
                sourceType: 'invoice_payment',
                sourceId: payment.id,
                reference: receiptNumber,
                notes: notes ?? '');
            await _postReceiptJournal(txn,
                invoice: invoice,
                paymentId: payment.id,
                amountPaid: amountPaid,
                datePaid: datePaid,
                paymentMethod: paymentMethod,
                accountId: payment.accountId);
            await AuditLogService.logInTxn(
              txn,
              action: AuditActions.paymentAdd,
              username: AuditActor.resolve(actor),
              entity: 'invoice_payments',
              entityId: payment.id,
              details:
                  'invoice: ${invoice.invoiceNumber ?? invoice.id} · amount: ${amountPaid.toStringAsFixed(2)} · paid: ${previouslyPaid.toStringAsFixed(2)} → ${(previouslyPaid + amountPaid).toStringAsFixed(2)} · balance: ${balanceAfter.toStringAsFixed(2)}',
            );
            saved.add(payment);
          }
        });
        AppLogger.d(_tag, 'Applied payment across ${saved.length} invoice(s).');
        return saved;
      } on DatabaseException catch (e) {
        if (attempt >= 4 || !_isReceiptNumberConflict(e)) rethrow;
      }
    }
  }

  // ─────────────────────────────────────────────
  // Fetch all payments for an invoice, oldest first
  static Future<List<InvoicePayment>> getPaymentsForInvoice(
      String invoiceId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'invoice_payments',
      where: "invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
      whereArgs: [invoiceId],
      orderBy: 'date_paid ASC, rowid ASC',
    );
    return rows.map(InvoicePayment.fromMap).toList();
  }

  // ─────────────────────────────────────────────
  // Aggregate: total amount paid for an invoice
  static Future<double> getTotalPaidForInvoice(String invoiceId) async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
      "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
      [invoiceId],
    );
    return (result.first['total'] as num).toDouble();
  }

  // ─────────────────────────────────────────────
  // Batch fetch: map of invoiceId → totalPaid for a list of invoice IDs.
  // Used by the list view to avoid N+1 queries.
  static Future<Map<String, double>> getTotalPaidBatch(
      List<String> invoiceIds) async {
    if (invoiceIds.isEmpty) return {};
    final db = await _dbHelper.database;
    final placeholders = List.filled(invoiceIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT invoice_id, COALESCE(SUM(amount_paid), 0.0) AS total '
      'FROM invoice_payments '
      "WHERE invoice_id IN ($placeholders) AND cheque_status NOT IN ('bounced', 'cancelled') "
      'GROUP BY invoice_id',
      invoiceIds,
    );
    return {
      for (final row in rows)
        row['invoice_id'] as String: (row['total'] as num).toDouble()
    };
  }

  // ─────────────────────────────────────────────
  // Delete a single payment (admin action). The cash/bank effect is reversed
  // first, so removing a receipt can never leave the account register stale.
  // Single transaction throughout (mirrors PurchaseBillService.deletePayment):
  // a crash between the reversal and the row delete can no longer orphan
  // cash movements. Bounced/cancelled cheques are terminal in the state
  // machine, so their delete skips the cheque transition (safe no-op) and
  // only reverses the cash leg once + deletes the row.
  static Future<void> deletePayment(String paymentId, {String? actor}) async {
    final db = await _dbHelper.database;
    // Period lock: a closed-period receipt cannot be removed.
    await PeriodLockService.assertStoredDateUnlocked(db,
        table: 'invoice_payments',
        id: paymentId,
        dateColumn: 'date_paid',
        entity: 'Payment');
    await db.transaction((txn) async {
      final rows = await txn.query('invoice_payments',
          where: 'id = ?', whereArgs: [paymentId], limit: 1);
      if (rows.isEmpty) return;
      final beforeAmount = (rows.first['amount_paid'] as num?)?.toDouble() ?? 0;
      final beforeInvoice = rows.first['invoice_id'] as String? ?? '';
      final beforeReceipt =
          rows.first['receipt_number'] as String? ?? paymentId;
      final chequeId = rows.first['cheque_id'] as String?;
      final chequeStatus = (rows.first['cheque_status'] as String?) ?? 'none';
      if (chequeId != null && chequeId.isNotEmpty) {
        if (chequeStatus == 'bounced' || chequeStatus == 'cancelled') {
          await AccountingService.reverseSourceInTransaction(txn,
              sourceType: 'invoice_payment',
              sourceId: paymentId,
              reason: 'Payment removed by administrator');
        } else {
          await AccountingService.cancelChequeInTransaction(txn, chequeId,
              reason: 'Payment removed by administrator');
          // Legacy cleared cheques posted a customer_receipt under
          // invoice_payment (not a cheque movement); reversing it here nets
          // cash exactly once (no-op for new cheque rows that post none).
          await AccountingService.reverseSourceInTransaction(txn,
              sourceType: 'invoice_payment',
              sourceId: paymentId,
              reason: 'Payment removed by administrator');
        }
      } else {
        await AccountingService.reverseSourceInTransaction(txn,
            sourceType: 'invoice_payment',
            sourceId: paymentId,
            reason: 'Payment removed by administrator');
      }
      // Mirror the persisted receipt posting (and the cheque-clear posting
      // when a cheque was involved); the deleted row leaves the projection,
      // so both sides net to zero. Idempotent — already-mirrored entries
      // are skipped.
      await JournalStore.reverseSource(txn,
          sourceType: JournalStore.srcReceipt, sourceId: paymentId);
      if (chequeId != null && chequeId.isNotEmpty) {
        await JournalStore.reverseSource(txn,
            sourceType: JournalStore.srcChequeClear, sourceId: chequeId);
      }
      await txn
          .delete('invoice_payments', where: 'id = ?', whereArgs: [paymentId]);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.paymentDelete,
        username: AuditActor.resolve(actor),
        entity: 'invoice_payments',
        entityId: paymentId,
        details:
            'invoice: $beforeInvoice · receipt: $beforeReceipt · amount: ${beforeAmount.toStringAsFixed(2)} → —',
      );
    });
    AppLogger.d(_tag, 'Payment deleted: $paymentId');
  }

  // ─────────────────────────────────────────────
  // Reporting: all payments in a date range. Inclusive day bounds via
  // substr(date, 1, 10): invoice_payments mixes date-only rows (PaymentService)
  // and full-ISO rows (Vyapar import), so a plain dateKey upper bound drops
  // same-day ISO rows while a plain dateKeyStart lower bound drops date-only
  // rows. Comparing the 10-char date part is the Start/End day-range
  // equivalent that covers both formats.
  static Future<List<InvoicePayment>> getAllPaymentsBetween(
      DateTime from, DateTime to) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'invoice_payments',
      where:
          "substr(date_paid, 1, 10) >= substr(?, 1, 10) AND substr(date_paid, 1, 10) <= substr(?, 1, 10) AND cheque_status NOT IN ('bounced', 'cancelled')",
      whereArgs: [
        AppDate.dateKeyStart(from),
        AppDate.dateKeyEnd(to),
      ],
      orderBy: 'date_paid ASC',
    );
    return rows.map(InvoicePayment.fromMap).toList();
  }

  // Reporting: total tax collected in a date range
  static Future<double> getTaxPaidBetween(DateTime from, DateTime to) async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(tax_amount_paid), 0.0) AS total '
      'FROM invoice_payments '
      "WHERE substr(date_paid, 1, 10) >= substr(?, 1, 10) AND substr(date_paid, 1, 10) <= substr(?, 1, 10) AND cheque_status NOT IN ('bounced', 'cancelled')",
      [
        AppDate.dateKeyStart(from),
        AppDate.dateKeyEnd(to),
      ],
    );
    return (result.first['total'] as num).toDouble();
  }
}
