import 'package:uuid/uuid.dart';

import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/payment_receipt_numbers.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_payment.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'package:apexbooks/utils/app_logger.dart';
import 'accounting_service.dart';
import 'database_helper.dart';

const _tag = 'PaymentService';

class PaymentService {
  static final _dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

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
  }) async {
    final db = await _dbHelper.database;
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

      // 3. Compute tax portion proportionally
      final taxAmountPaid = invoice.total > 0
          ? (amountPaid * (invoice.tax / invoice.total))
          : 0.0;

      // 4. Snapshot: balance remaining after this installment
      final balanceAfter = InvoiceCalculator.outstanding(
        total: invoice.total,
        paid: previouslyPaid + amountPaid,
      );

      if (amountPaid <= InvoiceCalculator.moneyEpsilon ||
          amountPaid >
              invoice.total - previouslyPaid + InvoiceCalculator.moneyEpsilon) {
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
      AppLogger.d(_tag, 'Payment added: ${saved.receiptNumber} — ₹$amountPaid');
    });

    return saved;
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
  }) async {
    if (paymentMethod == 'Check') {
      throw StateError('Record cheque payments individually');
    }
    final db = await _dbHelper.database;
    int count = 0;
    await db.transaction((txn) async {
      for (final invoice in invoices) {
        final paidResult = await txn.rawQuery(
          "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
          [invoice.id],
        );
        final previouslyPaid = (paidResult.first['total'] as num).toDouble();
        final amountPaid = InvoiceCalculator.outstanding(
            total: invoice.total, paid: previouslyPaid);
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
        count++;
      }
    });
    AppLogger.d(_tag, 'Batch payment: $count invoice(s) marked as paid.');
    return count;
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
  }) async {
    if (paymentMethod == 'Check') {
      throw StateError('Record cheque payments individually');
    }
    final db = await _dbHelper.database;
    final saved = <InvoicePayment>[];
    await db.transaction((txn) async {
      for (final a in allocations) {
        final invoice = a.invoice;
        final amountPaid = a.amount;
        if (amountPaid <= InvoiceCalculator.moneyEpsilon) continue;

        final sumResult = await txn.rawQuery(
          "SELECT COALESCE(SUM(amount_paid), 0.0) AS total FROM invoice_payments WHERE invoice_id = ? AND cheque_status NOT IN ('bounced', 'cancelled')",
          [invoice.id],
        );
        final previouslyPaid = (sumResult.first['total'] as num).toDouble();
        final outstanding = InvoiceCalculator.outstanding(
            total: invoice.total, paid: previouslyPaid);
        if (amountPaid > outstanding + InvoiceCalculator.moneyEpsilon) {
          throw StateError('Payment must be within the outstanding balance');
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
          total: invoice.total,
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
        saved.add(payment);
      }
    });
    AppLogger.d(_tag, 'Applied payment across ${saved.length} invoice(s).');
    return saved;
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
  static Future<void> deletePayment(String paymentId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('invoice_payments',
        columns: ['cheque_id', 'cheque_status'],
        where: 'id = ?',
        whereArgs: [paymentId],
        limit: 1);
    if (rows.isEmpty) return;
    final chequeId = rows.first['cheque_id'] as String?;
    if (chequeId != null && chequeId.isNotEmpty) {
      final wasCleared = rows.first['cheque_status'] == 'cleared';
      await AccountingService.transitionCheque(
          chequeId: chequeId,
          status: wasCleared ? 'bounced' : 'cancelled',
          notes: 'Payment removed by administrator');
    } else {
      await AccountingService.reverseSource(
          sourceType: 'invoice_payment',
          sourceId: paymentId,
          reason: 'Payment removed by administrator');
    }
    await db
        .delete('invoice_payments', where: 'id = ?', whereArgs: [paymentId]);
    AppLogger.d(_tag, 'Payment deleted: $paymentId');
  }

  // ─────────────────────────────────────────────
  // Reporting: all payments in a date range
  static Future<List<InvoicePayment>> getAllPaymentsBetween(
      DateTime from, DateTime to) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'invoice_payments',
      where:
          "date_paid >= ? AND date_paid <= ? AND cheque_status NOT IN ('bounced', 'cancelled')",
      whereArgs: [
        AppDate.dateKey(from),
        AppDate.dateKey(to),
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
      "WHERE date_paid >= ? AND date_paid <= ? AND cheque_status NOT IN ('bounced', 'cancelled')",
      [
        AppDate.dateKey(from),
        AppDate.dateKey(to),
      ],
    );
    return (result.first['total'] as num).toDouble();
  }
}
