import '../database/database_helper.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/additional_cost.dart';
import 'invoice_service.dart';
import 'journal_store.dart';

/// Double-entry ledger engine (v47 reports): derives a general journal from
/// the operational tables and serves trial balance + balance sheet.
///
/// Design: the ledger is a *projection*, not a store — every run rebuilds
/// from invoices/payments/expenses/purchase_bills, so it can never drift
/// from the business data and needs no sync of its own. Posting rules
/// (single-company cash+accrual hybrid, standard Indian chart of accounts):
///
///   Sale (invoice/Debit Note) Dr AR (payable, rounded if enabled) /
///     Cr Sales (exact) + Cr GST Output (exact) + Round Off delta
///   Credit Note (sale reversal) Dr Sales + Dr GST Output / Cr AR (payable),
///     with the Round Off delta mirrored
///   Receipt (payment, incl. note-linked) Dr Cash/Bank / Cr Accounts Receivable
///   Expense             Dr <category expense> / Cr Cash
///   Purchase bill (eligible) Dr Purchases net + Dr GST Input / Cr Payables total
///   Purchase bill (ITC ineligible) Dr Purchases FULL total / Cr Payables
///   Purchase bill (reverse charge) Dr Purchases net + Dr GST Input /
///     Cr GST Output (self-assessed) + Cr Payables net
///   Purchase payment    Dr Accounts Payable / Cr Cash
///
/// The projection is deterministic: same DB → same ledger.
class LedgerService {
  static final _db = DatabaseHelper();

  // ── Chart of accounts ──

  static const accCash = '1000 Cash';
  static const accBank = '1010 Bank';
  static const accChequesInHand = '1050 Cheques In Hand';
  static const accChequesIssued = '2050 Cheques Issued';
  static const accLoanLiability = '2300 Loan Liability';
  static const accInterestExpense = '6100 Interest Expense';
  static const accBankFees = '6110 Bank and Loan Fees';
  static const accReceivable = '1100 Accounts Receivable';
  static const accOldGold = '1300 Old Gold Stock';
  static const accPayable = '2000 Accounts Payable';
  static const accGstOutput = '2200 GST Output Payable';
  static const accGstInput = '1400 GST Input Credit (ITC)';
  static const accCapital = '3000 Owner Capital (Opening)';
  static const accRetained = '3100 Retained Earnings';
  static const accSales = '4000 Sales';
  static const accRoundOff = '6200 Round Off';
  static const accOtherIncome = '4100 Other Income';
  static const accPurchases = '5000 Purchases';
  static const accExpenses = '6000 Operating Expenses';

  /// Payment method that books metal received from the customer instead of
  /// cash (old-gold exchange, retail.md P3). The receipt leg debits Old
  /// Gold Stock so AR still nets to the printed payable total.
  static const receiptMethodOldGold = 'Old gold exchange';

  /// Historical/manual RCM rate retained to replay existing journal entries.
  /// New customer old-gold exchanges never infer RCM from a GSTIN.
  static const double oldGoldRcmPercent = 3.0;

  /// Opening balance source: settings key 'opening_capital' (default 0).
  static Future<double> getOpeningCapital() async {
    final db = await _db.database;
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: ['opening_capital'], limit: 1);
    final v = rows.isEmpty ? null : rows.first['value'] as String?;
    return double.tryParse(v ?? '') ?? 0;
  }

  /// Full journal for the given range (or everything when null).
  ///
  /// Persisted-first: entries posted at transaction time ([JournalStore])
  /// win; sources without persisted rows (raw seeds, sync pull-apply, bulk
  /// imports, pre-backfill data) fall back to the deterministic projection
  /// for those sources only. Both sides share the [LedgerPostings] builders,
  /// so figures are identical either way.
  static Future<List<JournalEntry>> getJournal({
    DateTime? from,
    DateTime? to,
    String? currencyCode,
  }) async {
    final projected = await getProjectedJournal(
        from: from, to: to, currencyCode: currencyCode);
    final db = await _db.database;
    if (!await JournalStore.hasTables(db)) return projected;
    final persisted = await JournalStore.readEntries(db,
        from: from, to: to, currencyCode: currencyCode);
    if (persisted.isEmpty) return projected;
    final keys = <String>{
      for (final e in persisted) '${e.sourceType}\x00${e.sourceId}'
    };
    final merged = [
      ...persisted,
      for (final e in projected)
        if (!keys.contains('${e.sourceType}\x00${e.sourceId}')) e,
    ]..sort((a, b) => a.date.compareTo(b.date));
    return merged;
  }

  /// Deterministic live projection of the journal from the source tables.
  /// This is the fallback for unposted sources and the oracle for the
  /// parity test; every persisted posting replicates one of these entries.
  static Future<List<JournalEntry>> getProjectedJournal({
    DateTime? from,
    DateTime? to,
    String? currencyCode,
  }) async {
    final db = await _db.database;
    final entries = <JournalEntry>[];
    final fromS = from?.toIso8601String();
    final toS = to?.toIso8601String();
    String dateFilter(String col) => [
          if (fromS != null) "$col >= '$fromS'",
          if (toS != null) "$col <= '$toS'",
        ].isEmpty
            ? ''
            : ' AND ${[
                if (fromS != null) "$col >= '$fromS'",
                if (toS != null) "$col <= '$toS'"
              ].join(' AND ')}';

    bool inRange(DateTime date) =>
        (from == null || !date.isBefore(from)) &&
        (to == null || !date.isAfter(to));
    String currencyFilter(String column) =>
        currencyCode == null ? '' : ' AND $column = ?';

    final accountRows = await db.query('financial_accounts');
    final accountById = <String, Map<String, dynamic>>{
      for (final row in accountRows) row['id'] as String: row
    };
    String accountName(String? id, {String fallback = accCash}) {
      final row = id == null ? null : accountById[id];
      if (row == null) return fallback;
      final prefix = row['type'] == 'bank' ? accBank : accCash;
      return '$prefix: ${row['name']}';
    }

    // 1. Sales invoices + Debit/Credit Notes → AR / Sales + GST Output.
    // Invoice totals are computed by the same domain calculator as the
    // UI/PDF; they are not stale denormalized columns in SQLite.
    // Credit Note reverses a sale (Dr Sales net + Dr GST Output / Cr AR);
    // Debit Note is an additional sale (same posting as an Invoice).
    final invoices = (await InvoiceService.getAllInvoices())
        .where((invoice) =>
            (invoice.type == 'Invoice' ||
                invoice.type == 'Credit Note' ||
                invoice.type == 'Debit Note') &&
            (currencyCode == null || invoice.currencyCode == currencyCode) &&
            inRange(invoice.date))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    for (final inv in invoices) {
      // AR settles at the payable total (rounded when the invoice opts in);
      // Sales and GST stay exact and the paise difference posts explicitly
      // to Round Off so the trial balance still proves out.
      final salePosting = LedgerPostings.saleEntry(
        date: inv.date,
        type: inv.type,
        customerName: inv.customer.name,
        currencySymbol: inv.currencySymbol,
        currencyCode: inv.currencyCode,
        total: inv.total,
        payable: inv.payableTotal,
        tax: inv.tax,
        sourceId: inv.id,
      );
      if (salePosting != null) entries.add(salePosting);
    }

    // 2. Receipts → Cash/Bank / AR
    final payments = await db.rawQuery('''
      SELECT p.id, p.date_paid AS d, p.amount_paid, p.payment_method,
             p.account_id, p.cheque_status, i.customer_name, i.currency_code
      FROM invoice_payments p
      JOIN invoices i ON i.id = p.invoice_id
      WHERE i.deleted_at IS NULL AND i.type IN ('Invoice', 'Credit Note', 'Debit Note')
        AND COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled')
      ${currencyFilter('i.currency_code')}
      ${dateFilter('p.date_paid')}
      ORDER BY d
    ''', [if (currencyCode != null) currencyCode]);
    for (final p in payments) {
      final method = p['payment_method'] as String? ?? 'Cash';
      final account = method == receiptMethodOldGold
          ? accOldGold
          : method == 'Check'
              ? accChequesInHand
              : accountName(p['account_id'] as String?,
                  fallback: method == 'Cash' ? accCash : accBank);
      entries.add(LedgerPostings.receiptEntry(
        date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
        customerName: p['customer_name'] as String? ?? '',
        method: method,
        amount: (p['amount_paid'] as num?)?.toDouble() ?? 0,
        account: account,
        currencyCode: p['currency_code'] as String? ?? 'INR',
        sourceId: p['id'] as String,
      ));
    }

    // 2b. Historical/manual old-gold RCM rows. New exchanges write zero; this
    // replay preserves the audit trail of pre-policy-change entries.
    final oldGoldTable = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name='old_gold_entries'");
    final invoiceDateCol = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM pragma_table_info('invoices') WHERE name='date'");
    if ((oldGoldTable.first['n'] as int? ?? 0) == 1 &&
        (invoiceDateCol.first['n'] as int? ?? 0) == 1) {
      final rcmRows = await db.rawQuery('''
        SELECT o.id, o.rcm_tax, o.customer_name,
               i.date AS d, i.currency_code
        FROM old_gold_entries o
        LEFT JOIN invoices i ON i.id = o.invoice_id
        WHERE o.rcm_tax > 0
        ${dateFilter('i.date')}
        ${currencyCode == null ? '' : 'AND i.currency_code = ?'}
        ORDER BY d
      ''', [if (currencyCode != null) currencyCode]);
      for (final r in rcmRows) {
        final rcmTax = (r['rcm_tax'] as num?)?.toDouble() ?? 0;
        if (rcmTax <= 0) continue;
        entries.add(LedgerPostings.oldGoldRcmEntry(
          date: DateTime.tryParse(r['d'] as String? ?? '') ?? DateTime.now(),
          customerName: r['customer_name'] as String? ?? '',
          amount: rcmTax,
          currencyCode: r['currency_code'] as String? ?? 'INR',
          sourceId: r['id'] as String,
        ));
      }
    }

    // 3. Expenses → expense / Cash
    final expenses = await db.rawQuery('''
      SELECT e.id, e.date, e.description, e.amount, e.account_id,
             c.name AS category
              , a.currency_code, COALESCE(a.currency_code, 'INR') AS cur
      FROM expenses e
      LEFT JOIN expense_categories c ON c.id = e.category_id
      LEFT JOIN financial_accounts a ON a.id = e.account_id
      WHERE 1 = 1 ${dateFilter('e.date')} ${currencyCode == null ? '' : "AND COALESCE(a.currency_code, 'INR') = ?"}
      ORDER BY e.date
    ''', [if (currencyCode != null) currencyCode]);
    for (final e in expenses) {
      final category = e['category'] as String? ?? 'General';
      final amount = (e['amount'] as num?)?.toDouble() ?? 0;
      entries.add(LedgerPostings.expenseEntry(
        date: DateTime.tryParse(e['date'] as String? ?? '') ?? DateTime.now(),
        description: e['description'] as String?,
        category: category,
        amount: amount,
        account: accountName(e['account_id'] as String?),
        currencyCode: e['cur'] as String? ?? 'INR',
        sourceId: e['id'] as String,
      ));
    }

    // 4. Purchase bills → Purchases + ITC / Payables, honouring ITC
    // eligibility and reverse charge (columns itc_eligible/reverse_charge,
    // same meaning as GstrExportService._loadItc):
    //   eligible non-RC → Dr Purchases net + Dr GST Input / Cr Payables total
    //   ineligible      → Dr Purchases FULL total (no ITC split)
    //   eligible RC     → Dr Purchases net + Dr GST Input / Cr GST Output
    //     (self-assessed RC liability, net zero payable effect but visible);
    //     only the supplier net is owed, so Cr Payables is net, not total.
    // Ineligible takes precedence over RC (no ITC claimed at all).
    // Consequently BalanceSheet gstInput accumulates only eligible ITC
    // (non-RC net asset plus RC gross offset by the paired Output).
    final bills = await db.rawQuery('''
      SELECT b.id, b.date, b.supplier_name, b.total_amount, b.total_tax,
             b.amount_paid, b.currency_symbol, b.currency_code,
             b.itc_eligible, b.reverse_charge,
             COALESCE(SUM(CASE WHEN COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled') THEN p.amount_paid ELSE 0 END), 0) AS recorded_paid
      FROM purchase_bills b
      LEFT JOIN purchase_bill_payments p ON p.purchase_bill_id = b.id
      WHERE 1 = 1
      ${currencyFilter('b.currency_code')}
      ${dateFilter('b.date')}
      GROUP BY b.id
      ORDER BY b.date
    ''', [if (currencyCode != null) currencyCode]);
    for (final b in bills) {
      final total = (b['total_amount'] as num?)?.toDouble() ?? 0;
      final tax = (b['total_tax'] as num?)?.toDouble() ?? 0;
      final isEligible = (b['itc_eligible'] as int? ?? 1) == 1;
      // Supplier payable: RC tax goes to the government, not the supplier.
      // Pre-v47 bills stored only an aggregate paid amount. Preserve that
      // historical payment as a bill-date cash movement when no payment
      // records exist, while newer bills use the dated payment rows below.
      final recordedPaid = (b['recorded_paid'] as num?)?.toDouble() ?? 0;
      final date =
          DateTime.tryParse(b['date'] as String? ?? '') ?? DateTime.now();
      entries.add(LedgerPostings.purchaseEntry(
        date: date,
        supplierName: b['supplier_name'] as String? ?? '',
        currencySymbol: b['currency_symbol'] as String? ?? '',
        currencyCode: b['currency_code'] as String? ?? 'INR',
        total: total,
        tax: tax,
        amountPaidColumn: (b['amount_paid'] as num?)?.toDouble() ?? 0,
        recordedPaid: recordedPaid,
        itcEligible: isEligible,
        reverseCharge: (b['reverse_charge'] as int? ?? 0) == 1,
        sourceId: b['id'] as String,
      ));
    }

    // Purchase payments settle payables on their actual payment date.
    final purchasePayments = await db.rawQuery('''
      SELECT p.id, p.date_paid AS d, p.amount_paid, p.payment_method,
             p.account_id, p.cheque_status,
             b.supplier_name, b.currency_code
      FROM purchase_bill_payments p
      JOIN purchase_bills b ON b.id = p.purchase_bill_id
      WHERE 1 = 1
      AND COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled')
      ${currencyFilter('b.currency_code')}
      ${dateFilter('p.date_paid')}
      ORDER BY d
    ''', [if (currencyCode != null) currencyCode]);
    for (final p in purchasePayments) {
      final amount = (p['amount_paid'] as num?)?.toDouble() ?? 0;
      final method = p['payment_method'] as String? ?? 'Cash';
      final paymentAccount = method == 'Check'
          ? accChequesIssued
          : accountName(p['account_id'] as String?,
              fallback: method == 'Cash' ? accCash : accBank);
      entries.add(LedgerPostings.purchasePaymentEntry(
        date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
        supplierName: p['supplier_name'] as String? ?? '',
        amount: amount,
        account: paymentAccount,
        currencyCode: p['currency_code'] as String? ?? 'INR',
        sourceId: p['id'] as String,
      ));
    }

    // 5. Cheque clearing moves value between the clearing register and the
    // selected bank; the original receipt/payment remains on its own date.
    final clearedCheques = await db.rawQuery('''
      SELECT c.*, a.name AS bank_name
      FROM cheques c LEFT JOIN financial_accounts a ON a.id = c.bank_account_id
      WHERE c.status = 'cleared'
      ${currencyFilter('c.currency_code')}
      ${dateFilter('c.cleared_at')}
      ORDER BY c.cleared_at
    ''', [if (currencyCode != null) currencyCode]);
    for (final cheque in clearedCheques) {
      final amount = (cheque['amount'] as num).toDouble();
      final bank =
          accountName(cheque['bank_account_id'] as String?, fallback: accBank);
      final received = cheque['direction'] == 'received';
      entries.add(LedgerPostings.chequeClearEntry(
        date: DateTime.tryParse(cheque['cleared_at'] as String? ?? '') ??
            DateTime.now(),
        chequeNumber: cheque['cheque_number'] as String? ?? '',
        amount: amount,
        bankAccount: bank,
        received: received,
        currencyCode: cheque['currency_code'] as String? ?? 'INR',
        sourceId: cheque['id'] as String,
      ));
    }

    // 6. Cash/bank transfers and explicit balance adjustments.
    final registerRows = await db.rawQuery('''
      SELECT * FROM financial_transactions
      WHERE voided_at IS NULL
        AND source_type IN ('transfer', 'adjustment')
      ${currencyCode == null ? '' : "AND account_id IN (SELECT id FROM financial_accounts WHERE currency_code = ?)"}
      ${dateFilter('date')}
      ORDER BY date, rowid
    ''', [if (currencyCode != null) currencyCode]);
    final transferGroups = <String, List<Map<String, dynamic>>>{};
    for (final row in registerRows) {
      if (row['source_type'] == 'adjustment') {
        final amount = (row['amount'] as num).toDouble();
        final accountId = row['account_id'] as String;
        entries.add(LedgerPostings.adjustmentEntry(
          date: DateTime.parse(row['date'] as String),
          notes: row['notes'] as String?,
          amount: amount,
          account: accountName(accountId),
          currencyCode:
              accountById[accountId]?['currency_code'] as String? ?? 'INR',
          sourceId: row['id'] as String,
        ));
      } else {
        transferGroups
            .putIfAbsent(row['source_id'] as String, () => [])
            .add(row);
      }
    }
    for (final group in transferGroups.entries) {
      entries.add(LedgerPostings.transferEntry(
        date: DateTime.parse(group.value.first['date'] as String),
        legs: [
          for (final row in group.value)
            (
              account: accountName(row['account_id'] as String),
              amount: (row['amount'] as num).toDouble(),
            ),
        ],
        currencyCode: accountById[group.value.first['account_id'] as String]
                ?['currency_code'] as String? ??
            'INR',
        sourceId: group.key,
      ));
    }

    // 7. Borrowed-loan principal and repayment splits.
    final loanRows = await db.rawQuery('''
      SELECT m.*, l.name AS loan_name, l.currency_code
      FROM loan_movements m JOIN loan_accounts l ON l.id = m.loan_id
      WHERE m.voided_at IS NULL
      ${currencyFilter('l.currency_code')}
      ${dateFilter('m.date')}
      ORDER BY m.date
    ''', [if (currencyCode != null) currencyCode]);
    for (final movement in loanRows) {
      final principal = (movement['principal_amount'] as num?)?.toDouble() ?? 0;
      final interest = (movement['interest_amount'] as num?)?.toDouble() ?? 0;
      final fees = (movement['fee_amount'] as num?)?.toDouble() ?? 0;
      final account = accountName(movement['account_id'] as String?);
      final drawdown = movement['type'] == 'drawdown';
      final loanName = movement['loan_name'] as String? ?? '';
      entries.add(drawdown
          ? LedgerPostings.loanDrawdownEntry(
              date: DateTime.parse(movement['date'] as String),
              loanName: loanName,
              principal: principal,
              account: account,
              currencyCode: movement['currency_code'] as String? ?? 'INR',
              sourceId: movement['id'] as String,
            )
          : LedgerPostings.loanRepaymentEntry(
              date: DateTime.parse(movement['date'] as String),
              loanName: loanName,
              principal: principal,
              interest: interest,
              fees: fees,
              account: account,
              currencyCode: movement['currency_code'] as String? ?? 'INR',
              sourceId: movement['id'] as String,
            ));
    }

    // Account-level opening balances are equity-funded balance forwards, not
    // income. They are distinct from the legacy single opening_capital key.
    for (final accountRow in accountRows) {
      final opening = (accountRow['opening_balance'] as num?)?.toDouble() ?? 0;
      final openingDate =
          DateTime.tryParse(accountRow['opening_date'] as String? ?? '') ??
              DateTime(2000);
      if (opening.abs() <= 0.000001 ||
          (currencyCode != null &&
              accountRow['currency_code'] != currencyCode) ||
          !inRange(openingDate)) {
        continue;
      }
      final account = accountName(accountRow['id'] as String);
      entries.add(LedgerPostings.accountOpeningEntry(
        date: openingDate,
        accountName: accountRow['name'] as String? ?? '',
        opening: opening,
        account: account,
        currencyCode: accountRow['currency_code'] as String? ?? 'INR',
        sourceId: accountRow['id'] as String,
      ));
    }

    // 8. Opening capital is a real opening entry, never omitted because other
    // transactions exist. Anchor it to the earliest business date so it is
    // stable and appears before subsequent activity in the full journal.
    final capital = currencyCode == null || currencyCode == 'INR'
        ? await getOpeningCapital()
        : 0.0;
    if (capital > 0) {
      final openingDate = entries.isEmpty
          ? DateTime.now()
          : entries.map((e) => e.date).reduce((a, b) => a.isBefore(b) ? a : b);
      entries.add(JournalEntry(
        date: openingDate,
        description: 'Opening capital',
        lines: [
          LedgerLine(account: accCash, debit: capital, credit: 0),
          LedgerLine(account: accCapital, debit: 0, credit: capital),
        ],
        sourceType: LedgerPostings.srcOpeningCapital,
        sourceId: LedgerPostings.srcOpeningCapital,
        currencyCode: 'INR',
      ));
    }

    entries.sort((a, b) => a.date.compareTo(b.date));
    return entries;
  }

  /// Trial balance across the full ledger (or a period).
  static Future<TrialBalance> getTrialBalance({
    DateTime? from,
    DateTime? to,
    String? currencyCode,
  }) async {
    final journal =
        await getJournal(from: from, to: to, currencyCode: currencyCode);
    final byAccount = <String, ({double debit, double credit})>{};
    for (final entry in journal) {
      for (final line in entry.lines) {
        final cur = byAccount[line.account] ?? (debit: 0, credit: 0);
        byAccount[line.account] = (
          debit: cur.debit + line.debit,
          credit: cur.credit + line.credit,
        );
      }
    }
    final rows = byAccount.entries
        .map((e) => TrialBalanceRow(
              account: e.key,
              debit: e.value.debit,
              credit: e.value.credit,
            ))
        .toList()
      ..sort((a, b) => a.account.compareTo(b.account));
    final totalDebit = rows.fold(0.0, (s, r) => s + r.debit);
    final totalCredit = rows.fold(0.0, (s, r) => s + r.credit);
    return TrialBalance(
        rows: rows,
        totalDebit: totalDebit,
        totalCredit: totalCredit,
        balanced: (totalDebit - totalCredit).abs() < 0.01);
  }

  /// Balance sheet from the full ledger: assets = liabilities + equity.
  /// Point-in-time as of [to] (all activity through the end date); there is
  /// intentionally no `from` — a balance sheet has no period.
  static Future<BalanceSheet> getBalanceSheet({
    DateTime? to,
    String? currencyCode,
  }) async {
    // A balance sheet is a point-in-time statement. Use all activity through
    // the selected end date, rather than only movements inside the period.
    final tb = await getTrialBalance(to: to, currencyCode: currencyCode);
    double getNet(String prefix) {
      double net = 0;
      for (final r in tb.rows) {
        if (r.account.startsWith(prefix)) {
          net += r.debit - r.credit;
        }
      }
      return net;
    }

    final opening = -getNet(accCapital);
    double salesCredit = 0;
    double purchasesDebit = 0;
    double expensesDebit = 0;
    double gstOutputCredit = 0;
    double roundOffNet = 0;
    for (final r in tb.rows) {
      if (r.account == accSales) salesCredit += r.credit - r.debit;
      if (r.account == accPurchases) purchasesDebit += r.debit - r.credit;
      if (r.account.startsWith(accExpenses))
        expensesDebit += r.debit - r.credit;
      if (r.account == accInterestExpense || r.account == accBankFees) {
        expensesDebit += r.debit - r.credit;
      }
      if (r.account == accGstOutput) gstOutputCredit += r.credit - r.debit;
      // Round-off paise: credit balance is income, debit balance an expense.
      if (r.account == accRoundOff) roundOffNet += r.credit - r.debit;
    }
    // Net income = Sales (credit) − Purchases (debit) − Expenses (debit)
    // + Round Off (net).
    final netProfit =
        salesCredit - purchasesDebit - expensesDebit + roundOffNet;

    final receivable = getNet(accReceivable);
    final chequesInHand = getNet(accChequesInHand);
    final chequesIssued = -getNet(accChequesIssued);
    final loans = -getNet(accLoanLiability);
    final cash = getNet(accCash) + getNet(accBank);
    final payable = -(getNet(accPayable));
    // ITC asset: ineligible bills post no GST Input, so only eligible ITC
    // lands here. RC bills post a paired Dr Input / Cr Output (net zero
    // payable effect, both visible); the Output leg sits in gstOutput.
    final gstInput = getNet(accGstInput);

    return BalanceSheet(
      cash: cash,
      chequesInHand: chequesInHand,
      receivable: receivable,
      gstInput: gstInput,
      gstOutput: gstOutputCredit,
      payables: payable,
      chequesIssued: chequesIssued,
      loans: loans,
      openingCapital: opening,
      netProfit: netProfit,
      totalDebit: tb.totalDebit,
      totalCredit: tb.totalCredit,
    );
  }
}

/// One journal entry with its lines; balanced by construction.
class JournalEntry {
  final DateTime date;
  final String description;
  final List<LedgerLine> lines;

  /// Persisted-journal identity: (sourceType, sourceId) keys the source
  /// mutation that posted this entry, so reads can prefer persisted rows
  /// over the projection fallback per source. [currencyCode] is the
  /// entry's reporting currency; [reversalOf] links mirror entries.
  final String sourceType;
  final String sourceId;
  final String currencyCode;
  final String? reversalOf;

  const JournalEntry({
    required this.date,
    required this.description,
    required this.lines,
    this.sourceType = '',
    this.sourceId = '',
    this.currencyCode = 'INR',
    this.reversalOf,
  });

  double get total => lines.fold(0, (s, l) => s + l.debit);
}

class LedgerLine {
  final String account;
  final double debit;
  final double credit;
  const LedgerLine({
    required this.account,
    required this.debit,
    required this.credit,
  });
}

class TrialBalanceRow {
  final String account;
  final double debit;
  final double credit;
  const TrialBalanceRow({
    required this.account,
    required this.debit,
    required this.credit,
  });

  /// Signed balance: positive = debit balance, negative = credit balance.
  double get net => debit - credit;
}

class TrialBalance {
  final List<TrialBalanceRow> rows;
  final double totalDebit;
  final double totalCredit;
  final bool balanced;
  const TrialBalance({
    required this.rows,
    required this.totalDebit,
    required this.totalCredit,
    required this.balanced,
  });
}

class BalanceSheet {
  final double cash;
  final double chequesInHand;
  final double receivable;
  final double gstInput;
  final double gstOutput;
  final double payables;
  final double chequesIssued;
  final double loans;
  final double openingCapital;
  final double netProfit;
  final double totalDebit;
  final double totalCredit;
  const BalanceSheet({
    required this.cash,
    this.chequesInHand = 0,
    required this.receivable,
    required this.gstInput,
    required this.gstOutput,
    required this.payables,
    this.chequesIssued = 0,
    this.loans = 0,
    required this.openingCapital,
    required this.netProfit,
    required this.totalDebit,
    required this.totalCredit,
  });

  double get assets => cash + chequesInHand + receivable + gstInput;
  double get liabilitiesAndEquity =>
      payables + chequesIssued + loans + gstOutput + openingCapital + netProfit;
}

/// Pure posting-rule builders shared by the live projection
/// ([LedgerService.getProjectedJournal]), the transaction-time writers, and
/// the v56 backfill — one definition of every debit/credit so persisted
/// rows and projected rows agree paise-for-paise. Builders never touch the
/// database; callers supply already-loaded values.
class LedgerPostings {
  static const srcOpeningCapital = 'opening_capital';

  static bool isPostingType(String type) =>
      type == 'Invoice' || type == 'Credit Note' || type == 'Debit Note';

  static LedgerLine? _roundOffLine(double roundOff) {
    if (roundOff.abs() < 0.005) return null;
    return roundOff > 0
        ? LedgerLine(
            account: LedgerService.accRoundOff, debit: 0, credit: roundOff)
        : LedgerLine(
            account: LedgerService.accRoundOff, debit: -roundOff, credit: 0);
  }

  /// Sale / credit-note / debit-note entry. Null unless [type] posts.
  static JournalEntry? saleEntry({
    required DateTime date,
    required String type,
    required String customerName,
    required String currencySymbol,
    required String currencyCode,
    required double total,
    required double payable,
    required double tax,
    required String sourceId,
  }) {
    if (!isPostingType(type)) return null;
    final net = total - tax;
    final roundOffLine = _roundOffLine(payable - total);
    if (type == 'Credit Note') {
      return JournalEntry(
        date: date,
        description:
            'Credit Note — $customerName ($currencySymbol${payable.toStringAsFixed(2)})',
        lines: [
          LedgerLine(account: LedgerService.accSales, debit: net, credit: 0),
          LedgerLine(
              account: LedgerService.accGstOutput, debit: tax, credit: 0),
          if (roundOffLine != null)
            LedgerLine(
                account: roundOffLine.account,
                debit: roundOffLine.credit,
                credit: roundOffLine.debit),
          LedgerLine(
              account: LedgerService.accReceivable, debit: 0, credit: payable),
        ],
        sourceType: JournalStore.srcInvoice,
        sourceId: sourceId,
        currencyCode: currencyCode,
      );
    }
    return JournalEntry(
      date: date,
      description:
          '${type == 'Debit Note' ? 'Debit Note' : 'Sale'} — $customerName ($currencySymbol${payable.toStringAsFixed(2)})',
      lines: [
        LedgerLine(
            account: LedgerService.accReceivable, debit: payable, credit: 0),
        LedgerLine(account: LedgerService.accSales, debit: 0, credit: net),
        LedgerLine(account: LedgerService.accGstOutput, debit: 0, credit: tax),
        if (roundOffLine != null) roundOffLine,
      ],
      sourceType: JournalStore.srcInvoice,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  /// Sale entry from raw `invoices` + `invoice_items` row maps (restore,
  /// backfill, sale-order conversion, recurring engine). Null unless the
  /// header type posts to the ledger.
  static JournalEntry? saleEntryFromMaps(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> itemRows,
  ) {
    final type = header['type'] as String? ?? '';
    if (!isPostingType(type)) return null;
    final taxMode = TaxModeExtension.fromKey(header['tax_mode'] as String?);
    final taxRate = (header['tax_rate'] as num?)?.toDouble() ?? 0.0;
    final additional =
        AdditionalCost.listFromJson(header['additional_costs'] as String?)
            .fold(0.0, (sum, c) => sum + c.amount);
    final totals = InvoiceTotalsCalculator.totals(
      lines: itemRows.map((r) => InvoiceTotalsCalculator.lineFromDbRow(r,
          taxMode: taxMode, globalTaxRatePercent: taxRate * 100)),
      taxMode: taxMode,
      globalTaxRate: taxRate,
      globalTaxRateFormat: TaxRateFormat.fraction,
      additionalCostsTotal: additional,
      invoiceDiscountType: InvoiceDiscountTypeExtension.fromKey(
          header['invoice_discount_type'] as String?),
      invoiceDiscountValue:
          (header['invoice_discount_value'] as num?)?.toDouble() ?? 0.0,
    );
    final payable = InvoiceTotalsCalculator.payableTotal(totals.total,
        enabled: (header['round_off'] as int?) == 1);
    return saleEntry(
      date:
          DateTime.tryParse(header['date'] as String? ?? '') ?? DateTime.now(),
      type: type,
      customerName: header['customer_name'] as String? ?? '',
      currencySymbol: header['currency_symbol'] as String? ?? '₹',
      currencyCode: header['currency_code'] as String? ?? 'INR',
      total: totals.total,
      payable: payable,
      tax: totals.tax,
      sourceId: header['id'] as String,
    );
  }

  static JournalEntry receiptEntry({
    required DateTime date,
    required String customerName,
    required String method,
    required double amount,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Receipt — $customerName ($method)',
      lines: [
        LedgerLine(account: account, debit: amount, credit: 0),
        LedgerLine(
            account: LedgerService.accReceivable, debit: 0, credit: amount),
      ],
      sourceType: JournalStore.srcReceipt,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry expenseEntry({
    required DateTime date,
    required String? description,
    required String category,
    required double amount,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Expense — ${description ?? category}',
      lines: [
        LedgerLine(
            account: '${LedgerService.accExpenses}: $category',
            debit: amount,
            credit: 0),
        LedgerLine(account: account, debit: 0, credit: amount),
      ],
      sourceType: JournalStore.srcExpense,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  /// Historical/manual old-gold RCM booked as an ITC / RCM-payable pair on
  /// the invoice date. New customer exchanges must not create this entry from
  /// the customer's registration status alone. Source id is the old-gold row.
  static JournalEntry oldGoldRcmEntry({
    required DateTime date,
    required String customerName,
    required double amount,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Old gold RCM — $customerName (sec 9(4))',
      lines: [
        LedgerLine(
            account: LedgerService.accGstInput, debit: amount, credit: 0),
        LedgerLine(account: '2250 GST RCM Payable', debit: 0, credit: amount),
      ],
      sourceType: JournalStore.srcOldGold,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  /// Purchase-bill entry honouring ITC eligibility and reverse charge.
  /// [recordedPaid] is the live payment-rows sum (cheque-filtered);
  /// [amountPaidColumn] the header aggregate kept for pre-v47 bills.
  static JournalEntry purchaseEntry({
    required DateTime date,
    required String supplierName,
    required String currencySymbol,
    required String currencyCode,
    required double total,
    required double tax,
    required double amountPaidColumn,
    required double recordedPaid,
    required bool itcEligible,
    required bool reverseCharge,
    required String sourceId,
  }) {
    final net = total - tax;
    final isEligible = itcEligible;
    final isRC = reverseCharge && isEligible;
    final payableTotal = isRC ? net : total;
    final purchaseDebit = isEligible ? net : total;
    final legacyPaid = recordedPaid <= 0
        ? amountPaidColumn.clamp(0, payableTotal).toDouble()
        : 0.0;
    final tag = isRC ? ' [RC]' : (!isEligible ? ' [ITC ineligible]' : '');
    final description =
        'Purchase — $supplierName ($currencySymbol${total.toStringAsFixed(2)})$tag';
    final cashLeg = legacyPaid > 0
        ? [
            LedgerLine(
                account: LedgerService.accCash, debit: 0, credit: legacyPaid)
          ]
        : <LedgerLine>[];
    if (!isEligible) {
      return JournalEntry(
        date: date,
        description: description,
        lines: [
          LedgerLine(
              account: LedgerService.accPurchases,
              debit: purchaseDebit,
              credit: 0),
          ...cashLeg,
          LedgerLine(
              account: LedgerService.accPayable,
              debit: 0,
              credit: payableTotal - legacyPaid),
        ],
        sourceType: JournalStore.srcPurchaseBill,
        sourceId: sourceId,
        currencyCode: currencyCode,
      );
    }
    if (isRC) {
      return JournalEntry(
        date: date,
        description: description,
        lines: [
          LedgerLine(
              account: LedgerService.accPurchases, debit: net, credit: 0),
          LedgerLine(account: LedgerService.accGstInput, debit: tax, credit: 0),
          LedgerLine(
              account: LedgerService.accGstOutput, debit: 0, credit: tax),
          ...cashLeg,
          LedgerLine(
              account: LedgerService.accPayable,
              debit: 0,
              credit: payableTotal - legacyPaid),
        ],
        sourceType: JournalStore.srcPurchaseBill,
        sourceId: sourceId,
        currencyCode: currencyCode,
      );
    }
    return JournalEntry(
      date: date,
      description: description,
      lines: [
        LedgerLine(account: LedgerService.accPurchases, debit: net, credit: 0),
        LedgerLine(account: LedgerService.accGstInput, debit: tax, credit: 0),
        ...cashLeg,
        LedgerLine(
            account: LedgerService.accPayable,
            debit: 0,
            credit: total - legacyPaid),
      ],
      sourceType: JournalStore.srcPurchaseBill,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry purchasePaymentEntry({
    required DateTime date,
    required String supplierName,
    required double amount,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Purchase payment — $supplierName',
      lines: [
        LedgerLine(account: LedgerService.accPayable, debit: amount, credit: 0),
        LedgerLine(account: account, debit: 0, credit: amount),
      ],
      sourceType: JournalStore.srcPurchasePayment,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry chequeClearEntry({
    required DateTime date,
    required String chequeNumber,
    required double amount,
    required String bankAccount,
    required bool received,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Cheque cleared — $chequeNumber',
      lines: received
          ? [
              LedgerLine(account: bankAccount, debit: amount, credit: 0),
              LedgerLine(
                  account: LedgerService.accChequesInHand,
                  debit: 0,
                  credit: amount),
            ]
          : [
              LedgerLine(
                  account: LedgerService.accChequesIssued,
                  debit: amount,
                  credit: 0),
              LedgerLine(account: bankAccount, debit: 0, credit: amount),
            ],
      sourceType: JournalStore.srcChequeClear,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry transferEntry({
    required DateTime date,
    required List<({String account, double amount})> legs,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Account transfer',
      lines: [
        for (final leg in legs)
          LedgerLine(
              account: leg.account,
              debit: leg.amount > 0 ? leg.amount : 0,
              credit: leg.amount < 0 ? -leg.amount : 0),
      ],
      sourceType: JournalStore.srcTransfer,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry adjustmentEntry({
    required DateTime date,
    required String? notes,
    required double amount,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Balance adjustment — ${notes ?? ''}',
      lines: amount >= 0
          ? [
              LedgerLine(account: account, debit: amount, credit: 0),
              LedgerLine(
                  account: LedgerService.accCapital, debit: 0, credit: amount),
            ]
          : [
              LedgerLine(
                  account: LedgerService.accCapital, debit: -amount, credit: 0),
              LedgerLine(account: account, debit: 0, credit: -amount),
            ],
      sourceType: JournalStore.srcAdjustment,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry loanDrawdownEntry({
    required DateTime date,
    required String loanName,
    required double principal,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Loan drawdown — $loanName',
      lines: [
        LedgerLine(account: account, debit: principal, credit: 0),
        LedgerLine(
            account: '${LedgerService.accLoanLiability}: $loanName',
            debit: 0,
            credit: principal),
      ],
      sourceType: JournalStore.srcLoanMovement,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry loanRepaymentEntry({
    required DateTime date,
    required String loanName,
    required double principal,
    required double interest,
    required double fees,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Loan repayment — $loanName',
      lines: [
        LedgerLine(
            account: '${LedgerService.accLoanLiability}: $loanName',
            debit: principal,
            credit: 0),
        if (interest > 0)
          LedgerLine(
              account: LedgerService.accInterestExpense,
              debit: interest,
              credit: 0),
        if (fees > 0)
          LedgerLine(
              account: LedgerService.accBankFees, debit: fees, credit: 0),
        LedgerLine(
            account: account, debit: 0, credit: principal + interest + fees),
      ],
      sourceType: JournalStore.srcLoanMovement,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }

  static JournalEntry accountOpeningEntry({
    required DateTime date,
    required String accountName,
    required double opening,
    required String account,
    required String currencyCode,
    required String sourceId,
  }) {
    return JournalEntry(
      date: date,
      description: 'Opening balance — $accountName',
      lines: opening >= 0
          ? [
              LedgerLine(account: account, debit: opening, credit: 0),
              LedgerLine(
                  account: LedgerService.accCapital, debit: 0, credit: opening),
            ]
          : [
              LedgerLine(
                  account: LedgerService.accCapital,
                  debit: -opening,
                  credit: 0),
              LedgerLine(account: account, debit: 0, credit: -opening),
            ],
      sourceType: JournalStore.srcAccountOpening,
      sourceId: sourceId,
      currencyCode: currencyCode,
    );
  }
}
