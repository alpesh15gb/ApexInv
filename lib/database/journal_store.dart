import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'ledger_service.dart';

/// Persisted double-entry journal (v56).
///
/// Every business posting (sale, credit/debit note, receipt, purchase bill,
/// purchase payment, cheque clear, transfer, adjustment, loan drawdown /
/// repayment, expense, account opening) writes immutable balanced rows here
/// in the SAME database transaction as its source mutation. Corrections and
/// deletions never update or delete journal rows — they post mirror entries
/// (see [reverseSource]) dated at the original entry's date, so every
/// period-filtered read nets exactly as the former live projection did.
///
/// Reads ([LedgerService.getJournal] and everything derived from it:
/// trial balance, P&L, balance sheet) prefer these persisted rows. Sources
/// that were written without a journal post (raw test seeds, sync
/// pull-apply, bulk imports, pre-v56 leftovers missed by backfill) fall back
/// to the deterministic projection for those sources only, keyed by
/// `(source_type, source_id)` — so reported figures are identical either
/// way. The journal tables are deliberately NOT sync-registered: each device
/// derives the same rows from the synced source rows, so journal content
/// must never travel the sync wire (it would double-post on peers).
class JournalStore {
  static const entriesTable = 'journal_entries';
  static const linesTable = 'journal_lines';

  /// Per-entry balance tolerance. Posting math keeps debit/credit sums equal
  /// to ~1e-12; anything above a paise is a programmer error and aborts.
  static const balanceEpsilon = 0.01;

  static const _uuid = Uuid();

  // ── Source-type keys shared by writers, the backfill, and the read union ──

  static const srcInvoice = 'invoice';
  static const srcReceipt = 'invoice_payment';
  static const srcExpense = 'expense';
  static const srcPurchaseBill = 'purchase_bill';
  static const srcPurchasePayment = 'purchase_payment';
  static const srcChequeClear = 'cheque_clear';
  static const srcTransfer = 'transfer';
  static const srcAdjustment = 'adjustment';
  static const srcLoanMovement = 'loan_movement';
  static const srcAccountOpening = 'account_opening';

  /// Journal source type for a cheque's linked payment row.
  static String? paymentSourceForCheque(String chequeSourceType) {
    switch (chequeSourceType) {
      case 'invoice_payment':
        return srcReceipt;
      case 'purchase_bill_payment':
        return srcPurchasePayment;
      default:
        return null;
    }
  }

  // ── Schema ────────────────────────────────────────────────────────────────

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $entriesTable (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        currency_code TEXT NOT NULL DEFAULT 'INR',
        reversal_of TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $linesTable (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        account TEXT NOT NULL,
        debit REAL NOT NULL DEFAULT 0,
        credit REAL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_journal_entries_source ON $entriesTable(source_type, source_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON $entriesTable(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_journal_lines_entry ON $linesTable(entry_id)');
  }

  static Future<bool> hasTables(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name IN (?, ?)",
        [entriesTable, linesTable]);
    return ((rows.first['c'] as num?)?.toInt() ?? 0) == 2;
  }

  static Future<bool> _tableExists(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name=?",
        [table]);
    return ((rows.first['c'] as num?)?.toInt() ?? 0) == 1;
  }

  static Future<Set<String>> _columns(DatabaseExecutor db, String table) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      return {for (final r in rows) r['name'] as String};
    } catch (_) {
      return const {};
    }
  }

  // ── Writes (always inside the caller's transaction) ───────────────────────

  /// Posts one balanced entry. Throws [StateError] (aborting the caller's
  /// transaction loudly) when debits != credits beyond [balanceEpsilon].
  static Future<String> postEntry(
    DatabaseExecutor txn, {
    required DateTime date,
    required String description,
    required String sourceType,
    required String sourceId,
    String currencyCode = 'INR',
    String? reversalOf,
    required List<LedgerLine> lines,
  }) async {
    final debits = lines.fold(0.0, (s, l) => s + l.debit);
    final credits = lines.fold(0.0, (s, l) => s + l.credit);
    if ((debits - credits).abs() > balanceEpsilon) {
      throw StateError(
          'Refusing unbalanced journal entry for $sourceType/$sourceId: '
          'debits $debits != credits $credits ($description)');
    }
    final id = _uuid.v4();
    await txn.insert(entriesTable, {
      'id': id,
      'date': date.toIso8601String(),
      'description': description,
      'source_type': sourceType,
      'source_id': sourceId,
      'currency_code': currencyCode,
      'reversal_of': reversalOf,
      'created_at': DateTime.now().toIso8601String(),
    });
    for (final line in lines) {
      await txn.insert(linesTable, {
        'id': _uuid.v4(),
        'entry_id': id,
        'account': line.account,
        'debit': line.debit,
        'credit': line.credit,
      });
    }
    return id;
  }

  /// Posts a fully built [JournalEntry] (from [LedgerPostings]).
  static Future<String> postBuilt(
      DatabaseExecutor txn, JournalEntry entry) async {
    return postEntry(
      txn,
      date: entry.date,
      description: entry.description,
      sourceType: entry.sourceType,
      sourceId: entry.sourceId,
      currencyCode: entry.currencyCode,
      reversalOf: entry.reversalOf,
      lines: entry.lines,
    );
  }

  /// True when at least one journal entry exists for [sourceType]/[sourceId].
  static Future<bool> hasPosted(DatabaseExecutor txn,
      {required String sourceType, required String sourceId}) async {
    final rows = await txn.query(entriesTable,
        columns: ['id'],
        where: 'source_type = ? AND source_id = ?',
        whereArgs: [sourceType, sourceId],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Writes mirror entries (debit/credit swapped) for every live entry of
  /// [sourceType]/[sourceId] that has no mirror yet. Mirrors are dated at
  /// the ORIGINAL entry's date so period-filtered reads net exactly as the
  /// former live projection (which drops deleted/voided sources entirely).
  /// Idempotent: already-mirrored entries are skipped, so shared delete
  /// paths can call this unconditionally.
  static Future<void> reverseSource(
    DatabaseExecutor txn, {
    required String sourceType,
    required String sourceId,
  }) async {
    final originals = await txn.query(entriesTable,
        where: 'source_type = ? AND source_id = ? AND reversal_of IS NULL',
        whereArgs: [sourceType, sourceId]);
    for (final original in originals) {
      final existing = await txn.query(entriesTable,
          columns: ['id'],
          where: 'reversal_of = ?',
          whereArgs: [original['id']],
          limit: 1);
      if (existing.isNotEmpty) continue;
      final lines = await txn.query(linesTable,
          where: 'entry_id = ?', whereArgs: [original['id']]);
      await postEntry(
        txn,
        date: DateTime.tryParse(original['date'] as String? ?? '') ??
            DateTime.now(),
        description: 'Reversal — ${original['description'] as String? ?? ''}',
        sourceType: sourceType,
        sourceId: sourceId,
        currencyCode: original['currency_code'] as String? ?? 'INR',
        reversalOf: original['id'] as String,
        lines: [
          for (final l in lines)
            LedgerLine(
              account: l['account'] as String,
              debit: (l['credit'] as num).toDouble(),
              credit: (l['debit'] as num).toDouble(),
            ),
        ],
      );
    }
  }

  // ── Reads ─────────────────────────────────────────────────────────────────

  /// Persisted entries for the range, oldest first. Callers union these with
  /// the projection fallback for sources without persisted rows.
  static Future<List<JournalEntry>> readEntries(
    DatabaseExecutor db, {
    DateTime? from,
    DateTime? to,
    String? currencyCode,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('e.date >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('e.date <= ?');
      args.add(to.toIso8601String());
    }
    if (currencyCode != null) {
      where.add('e.currency_code = ?');
      args.add(currencyCode);
    }
    final rows = await db.rawQuery('''
      SELECT e.id, e.date, e.description, e.source_type, e.source_id,
             e.currency_code, e.reversal_of,
             l.account, l.debit, l.credit
      FROM $entriesTable e JOIN $linesTable l ON l.entry_id = e.id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY e.date, e.rowid, l.rowid
    ''', args);
    final byEntry = <String, JournalEntry>{};
    final order = <String>[];
    for (final r in rows) {
      final id = r['id'] as String;
      if (!byEntry.containsKey(id)) {
        order.add(id);
        byEntry[id] = JournalEntry(
          date: DateTime.tryParse(r['date'] as String? ?? '') ?? DateTime.now(),
          description: r['description'] as String? ?? '',
          lines: [],
          sourceType: r['source_type'] as String? ?? '',
          sourceId: r['source_id'] as String? ?? '',
          currencyCode: r['currency_code'] as String? ?? 'INR',
          reversalOf: r['reversal_of'] as String?,
        );
      }
      byEntry[id]!.lines.add(LedgerLine(
            account: r['account'] as String,
            debit: (r['debit'] as num?)?.toDouble() ?? 0,
            credit: (r['credit'] as num?)?.toDouble() ?? 0,
          ));
    }
    return [for (final id in order) byEntry[id]!];
  }

  /// Display name for a cash/bank register, mirroring the ledger's
  /// `accountName` (bank/cash prefix + register name).
  static String accountDisplay(Map<String, dynamic>? row,
      {required String fallback}) {
    if (row == null) return fallback;
    final prefix =
        row['type'] == 'bank' ? LedgerService.accBank : LedgerService.accCash;
    return '$prefix: ${row['name']}';
  }

  // ── Backfill (v56 migration) ──────────────────────────────────────────────
  //
  // Deterministically rebuilds journal rows from the source tables using the
  // same [LedgerPostings] builders as the live write paths and the
  // projection. Skips sources that already have persisted rows (re-run
  // safe) and missing tables (minimal/legacy databases). Every posted entry
  // is balance-verified by [postEntry]; an unbalanced entry aborts loudly.

  static Future<int> backfill(DatabaseExecutor db) async {
    var posted = 0;

    Future<Map<String, Map<String, dynamic>>> loadAccounts() async {
      if (!await _tableExists(db, 'financial_accounts')) return {};
      final rows = await db.query('financial_accounts');
      return {for (final r in rows) r['id'] as String: r};
    }

    final accounts = await loadAccounts();
    String display(String? id, {required String fallback}) =>
        accountDisplay(accounts[id], fallback: fallback);
    String currencyOf(String? id, {String fallback = 'INR'}) =>
        accounts[id]?['currency_code'] as String? ?? fallback;

    Future<void> postIfMissing(JournalEntry? entry) async {
      if (entry == null) return;
      if (await hasPosted(db,
          sourceType: entry.sourceType, sourceId: entry.sourceId)) {
        return;
      }
      await postBuilt(db, entry);
      posted++;
    }

    // 1. Sales / credit / debit notes.
    // Column-guarded: minimal/legacy databases (e.g. the v53/v54 dedup
    // regression fixture) may lack modern invoice columns; absence means
    // there is nothing projectable, so the section is skipped.
    if (await _tableExists(db, 'invoices') &&
        (await _columns(db, 'invoices'))
            .containsAll(['id', 'type', 'date', 'deleted_at'])) {
      final invRows = await db.query('invoices',
          where:
              "deleted_at IS NULL AND type IN ('Invoice', 'Credit Note', 'Debit Note')",
          orderBy: 'date');
      if (invRows.isNotEmpty && await _tableExists(db, 'invoice_items')) {
        final ids = invRows.map((r) => r['id'] as String).toList();
        final itemsByInv = <String, List<Map<String, dynamic>>>{};
        for (var i = 0; i < ids.length; i += 500) {
          final chunk =
              ids.sublist(i, (i + 500 > ids.length) ? ids.length : i + 500);
          final ph = List.filled(chunk.length, '?').join(',');
          final itemRows = await db.query('invoice_items',
              where: 'invoice_id IN ($ph)', whereArgs: chunk);
          for (final r in itemRows) {
            (itemsByInv[r['invoice_id'] as String] ??= []).add(r);
          }
        }
        for (final header in invRows) {
          await postIfMissing(LedgerPostings.saleEntryFromMaps(
              header, itemsByInv[header['id'] as String] ?? []));
        }
      }
    }

    // 2. Receipts.
    if (await _tableExists(db, 'invoice_payments') &&
        await _tableExists(db, 'invoices') &&
        (await _columns(db, 'invoice_payments')).containsAll([
          'id',
          'invoice_id',
          'date_paid',
          'amount_paid',
          'payment_method',
          'account_id',
          'cheque_status'
        ]) &&
        (await _columns(db, 'invoices'))
            .containsAll(['id', 'date', 'deleted_at', 'type'])) {
      final payRows = await db.rawQuery('''
        SELECT p.id, p.date_paid AS d, p.amount_paid, p.payment_method,
               p.account_id, p.cheque_status, i.customer_name, i.currency_code
        FROM invoice_payments p
        JOIN invoices i ON i.id = p.invoice_id
        WHERE i.deleted_at IS NULL AND i.type IN ('Invoice', 'Credit Note', 'Debit Note')
          AND COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled')
        ORDER BY d
      ''');
      for (final p in payRows) {
        final method = p['payment_method'] as String? ?? 'Cash';
        final account = method == 'Check'
            ? LedgerService.accChequesInHand
            : display(p['account_id'] as String?,
                fallback: method == 'Cash'
                    ? LedgerService.accCash
                    : LedgerService.accBank);
        await postIfMissing(LedgerPostings.receiptEntry(
          date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
          customerName: p['customer_name'] as String? ?? '',
          method: method,
          amount: (p['amount_paid'] as num?)?.toDouble() ?? 0,
          account: account,
          currencyCode: p['currency_code'] as String? ?? 'INR',
          sourceId: p['id'] as String,
        ));
      }
    }

    // 3. Expenses.
    if (await _tableExists(db, 'expenses') &&
        (await _columns(db, 'expenses'))
            .containsAll(['id', 'date', 'amount'])) {
      final categoryNames = <String, String>{};
      if (await _tableExists(db, 'expense_categories')) {
        for (final c in await db.query('expense_categories')) {
          categoryNames[c['id'] as String] = c['name'] as String? ?? 'General';
        }
      }
      final expRows = await db.query('expenses', orderBy: 'date');
      for (final e in expRows) {
        final category = categoryNames[e['category_id'] as String] ?? 'General';
        final accountId = e['account_id'] as String?;
        await postIfMissing(LedgerPostings.expenseEntry(
          date: DateTime.tryParse(e['date'] as String? ?? '') ?? DateTime.now(),
          description: e['description'] as String?,
          category: category,
          amount: (e['amount'] as num?)?.toDouble() ?? 0,
          account: display(accountId, fallback: LedgerService.accCash),
          currencyCode: currencyOf(accountId),
          sourceId: e['id'] as String,
        ));
      }
    }

    // 4. Purchase bills (with the legacy aggregate-paid rule).
    if (await _tableExists(db, 'purchase_bills') &&
        (await _columns(db, 'purchase_bills')).containsAll(['id', 'date'])) {
      final billRows = await db.query('purchase_bills', orderBy: 'date');
      for (final b in billRows) {
        double recordedPaid = 0;
        if (await _tableExists(db, 'purchase_bill_payments') &&
            (await _columns(db, 'purchase_bill_payments')).containsAll(
                ['purchase_bill_id', 'amount_paid', 'cheque_status'])) {
          final sumRows = await db.rawQuery(
              "SELECT COALESCE(SUM(CASE WHEN COALESCE(cheque_status, 'none') NOT IN ('bounced', 'cancelled') THEN amount_paid ELSE 0 END), 0) AS v FROM purchase_bill_payments WHERE purchase_bill_id = ?",
              [b['id']]);
          recordedPaid = (sumRows.first['v'] as num?)?.toDouble() ?? 0;
        }
        await postIfMissing(LedgerPostings.purchaseEntry(
          date: DateTime.tryParse(b['date'] as String? ?? '') ?? DateTime.now(),
          supplierName: b['supplier_name'] as String? ?? '',
          currencySymbol: b['currency_symbol'] as String? ?? '',
          currencyCode: b['currency_code'] as String? ?? 'INR',
          total: (b['total_amount'] as num?)?.toDouble() ?? 0,
          tax: (b['total_tax'] as num?)?.toDouble() ?? 0,
          amountPaidColumn: (b['amount_paid'] as num?)?.toDouble() ?? 0,
          recordedPaid: recordedPaid,
          itcEligible: (b['itc_eligible'] as int? ?? 1) == 1,
          reverseCharge: (b['reverse_charge'] as int? ?? 0) == 1,
          sourceId: b['id'] as String,
        ));
      }
    }

    // 5. Purchase payments.
    if (await _tableExists(db, 'purchase_bill_payments') &&
        await _tableExists(db, 'purchase_bills') &&
        (await _columns(db, 'purchase_bill_payments')).containsAll([
          'id',
          'purchase_bill_id',
          'date_paid',
          'amount_paid',
          'payment_method',
          'account_id',
          'cheque_status'
        ]) &&
        (await _columns(db, 'purchase_bills'))
            .containsAll(['id', 'date', 'supplier_name', 'currency_code'])) {
      final payRows = await db.rawQuery('''
        SELECT p.id, p.date_paid AS d, p.amount_paid, p.payment_method,
               p.account_id, p.cheque_status,
               b.supplier_name, b.currency_code
        FROM purchase_bill_payments p
        JOIN purchase_bills b ON b.id = p.purchase_bill_id
        WHERE COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled')
        ORDER BY d
      ''');
      for (final p in payRows) {
        final method = p['payment_method'] as String? ?? 'Cash';
        final account = method == 'Check'
            ? LedgerService.accChequesIssued
            : display(p['account_id'] as String?,
                fallback: method == 'Cash'
                    ? LedgerService.accCash
                    : LedgerService.accBank);
        await postIfMissing(LedgerPostings.purchasePaymentEntry(
          date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
          supplierName: p['supplier_name'] as String? ?? '',
          amount: (p['amount_paid'] as num?)?.toDouble() ?? 0,
          account: account,
          currencyCode: p['currency_code'] as String? ?? 'INR',
          sourceId: p['id'] as String,
        ));
      }
    }

    // 6. Cleared cheques.
    if (await _tableExists(db, 'cheques') &&
        (await _columns(db, 'cheques'))
            .containsAll(['id', 'status', 'cleared_at'])) {
      final cleared = await db.query('cheques',
          where: "status = 'cleared'", orderBy: 'cleared_at');
      for (final c in cleared) {
        final received = c['direction'] == 'received';
        await postIfMissing(LedgerPostings.chequeClearEntry(
          date: DateTime.tryParse(c['cleared_at'] as String? ?? '') ??
              DateTime.now(),
          chequeNumber: c['cheque_number'] as String? ?? '',
          amount: (c['amount'] as num?)?.toDouble() ?? 0,
          bankAccount: display(c['bank_account_id'] as String?,
              fallback: LedgerService.accBank),
          received: received,
          currencyCode: c['currency_code'] as String? ?? 'INR',
          sourceId: c['id'] as String,
        ));
      }
    }

    // 7. Transfers + adjustments.
    if (await _tableExists(db, 'financial_transactions') &&
        (await _columns(db, 'financial_transactions')).containsAll([
          'id',
          'account_id',
          'amount',
          'date',
          'source_type',
          'source_id',
          'voided_at'
        ])) {
      final regRows = await db.query('financial_transactions',
          where:
              "voided_at IS NULL AND source_type IN ('transfer', 'adjustment')",
          orderBy: 'date, rowid');
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final row in regRows) {
        if (row['source_type'] == 'adjustment') {
          final amount = (row['amount'] as num).toDouble();
          final accountId = row['account_id'] as String;
          await postIfMissing(LedgerPostings.adjustmentEntry(
            date: DateTime.parse(row['date'] as String),
            notes: row['notes'] as String?,
            amount: amount,
            account: display(accountId, fallback: LedgerService.accCash),
            currencyCode: currencyOf(accountId),
            sourceId: row['id'] as String,
          ));
        } else {
          groups.putIfAbsent(row['source_id'] as String, () => []).add(row);
        }
      }
      for (final g in groups.entries) {
        await postIfMissing(LedgerPostings.transferEntry(
          date: DateTime.parse(g.value.first['date'] as String),
          legs: [
            for (final row in g.value)
              (
                account: display(row['account_id'] as String,
                    fallback: LedgerService.accCash),
                amount: (row['amount'] as num).toDouble(),
              ),
          ],
          currencyCode: currencyOf(g.value.first['account_id'] as String),
          sourceId: g.key,
        ));
      }
    }

    // 8. Loan movements.
    if (await _tableExists(db, 'loan_movements') &&
        await _tableExists(db, 'loan_accounts') &&
        (await _columns(db, 'loan_movements')).containsAll(
            ['id', 'date', 'type', 'account_id', 'voided_at', 'loan_id']) &&
        (await _columns(db, 'loan_accounts')).containsAll(['id'])) {
      final loanRows = await db.rawQuery('''
        SELECT m.*, l.name AS loan_name, l.currency_code
        FROM loan_movements m JOIN loan_accounts l ON l.id = m.loan_id
        WHERE m.voided_at IS NULL
        ORDER BY m.date
      ''');
      for (final m in loanRows) {
        final drawdown = m['type'] == 'drawdown';
        await postIfMissing(drawdown
            ? LedgerPostings.loanDrawdownEntry(
                date: DateTime.parse(m['date'] as String),
                loanName: m['loan_name'] as String? ?? '',
                principal: (m['principal_amount'] as num?)?.toDouble() ?? 0,
                account: display(m['account_id'] as String?,
                    fallback: LedgerService.accCash),
                currencyCode: m['currency_code'] as String? ?? 'INR',
                sourceId: m['id'] as String,
              )
            : LedgerPostings.loanRepaymentEntry(
                date: DateTime.parse(m['date'] as String),
                loanName: m['loan_name'] as String? ?? '',
                principal: (m['principal_amount'] as num?)?.toDouble() ?? 0,
                interest: (m['interest_amount'] as num?)?.toDouble() ?? 0,
                fees: (m['fee_amount'] as num?)?.toDouble() ?? 0,
                account: display(m['account_id'] as String?,
                    fallback: LedgerService.accCash),
                currencyCode: m['currency_code'] as String? ?? 'INR',
                sourceId: m['id'] as String,
              ));
      }
    }

    // 9. Account opening balances (equity-funded forwards). The legacy
    // single `opening_capital` settings key has no write path in the app and
    // stays projection-only by design (see LedgerService.getJournal).
    if (await _tableExists(db, 'financial_accounts') &&
        (await _columns(db, 'financial_accounts'))
            .containsAll(['id', 'opening_balance'])) {
      for (final a in await db.query('financial_accounts')) {
        final opening = (a['opening_balance'] as num?)?.toDouble() ?? 0;
        if (opening.abs() <= 0.000001) continue;
        await postIfMissing(LedgerPostings.accountOpeningEntry(
          date: DateTime.tryParse(a['opening_date'] as String? ?? '') ??
              DateTime(2000),
          accountName: a['name'] as String? ?? '',
          opening: opening,
          account: display(a['id'] as String, fallback: LedgerService.accCash),
          currencyCode: a['currency_code'] as String? ?? 'INR',
          sourceId: a['id'] as String,
        ));
      }
    }

    return posted;
  }
}
