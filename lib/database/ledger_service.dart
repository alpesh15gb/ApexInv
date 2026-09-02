import '../database/database_helper.dart';
import 'invoice_service.dart';

/// Double-entry ledger engine (v47 reports): derives a general journal from
/// the operational tables and serves trial balance + balance sheet.
///
/// Design: the ledger is a *projection*, not a store — every run rebuilds
/// from invoices/payments/expenses/purchase_bills, so it can never drift
/// from the business data and needs no sync of its own. Posting rules
/// (single-company cash+accrual hybrid, standard Indian chart of accounts):
///
///   Sale (invoice)      Dr Accounts Receivable / Cr Sales + Cr GST Output
///   Receipt (payment)   Dr Cash/Bank / Cr Accounts Receivable
///   Expense             Dr <category expense> / Cr Cash
///   Purchase bill       Dr Purchases + Dr GST Input (ITC) / Cr Payables
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
  static const accPayable = '2000 Accounts Payable';
  static const accGstOutput = '2200 GST Output Payable';
  static const accGstInput = '1400 GST Input Credit (ITC)';
  static const accCapital = '3000 Owner Capital (Opening)';
  static const accRetained = '3100 Retained Earnings';
  static const accSales = '4000 Sales';
  static const accOtherIncome = '4100 Other Income';
  static const accPurchases = '5000 Purchases';
  static const accExpenses = '6000 Operating Expenses';

  /// Opening balance source: settings key 'opening_capital' (default 0).
  static Future<double> getOpeningCapital() async {
    final db = await _db.database;
    final rows = await db.query('settings',
        where: 'key = ?', whereArgs: ['opening_capital'], limit: 1);
    final v = rows.isEmpty ? null : rows.first['value'] as String?;
    return double.tryParse(v ?? '') ?? 0;
  }

  /// Full journal for the given range (or everything when null).
  static Future<List<JournalEntry>> getJournal({
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
            : ' AND ${[if (fromS != null) "$col >= '$fromS'", if (toS != null) "$col <= '$toS'"].join(' AND ')}';

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

    // 1. Sales invoices → AR / Sales + GST Output. Invoice totals are
    // computed by the same domain calculator as the UI/PDF; they are not
    // stale denormalized columns in SQLite.
    final invoices = (await InvoiceService.getAllInvoices())
        .where((invoice) =>
            invoice.type == 'Invoice' &&
            (currencyCode == null || invoice.currencyCode == currencyCode) &&
            inRange(invoice.date))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    for (final inv in invoices) {
      final total = inv.total;
      final tax = inv.tax;
      final net = total - tax;
      entries.add(JournalEntry(
        date: inv.date,
        description:
            'Sale — ${inv.customer.name} (${inv.currencySymbol}${total.toStringAsFixed(2)})',
        lines: [
          LedgerLine(
              account: accReceivable, debit: total, credit: 0),
          LedgerLine(account: accSales, debit: 0, credit: net),
          LedgerLine(account: accGstOutput, debit: 0, credit: tax),
        ],
      ));
    }

    // 2. Receipts → Cash/Bank / AR
    final payments = await db.rawQuery('''
      SELECT p.date_paid AS d, p.amount_paid, p.payment_method,
             p.account_id, p.cheque_status, i.customer_name
      FROM invoice_payments p
      JOIN invoices i ON i.id = p.invoice_id
      WHERE i.deleted_at IS NULL AND i.type = 'Invoice'
        AND COALESCE(p.cheque_status, 'none') NOT IN ('bounced', 'cancelled')
      ${currencyFilter('i.currency_code')}
      ${dateFilter('p.date_paid')}
      ORDER BY d
    ''', [if (currencyCode != null) currencyCode]);
    for (final p in payments) {
      final method = p['payment_method'] as String? ?? 'Cash';
      final account = method == 'Check'
          ? accChequesInHand
          : accountName(p['account_id'] as String?,
              fallback: method == 'Cash' ? accCash : accBank);
      entries.add(JournalEntry(
        date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
        description:
            'Receipt — ${p['customer_name'] ?? ''} ($method)',
        lines: [
          LedgerLine(
              account: account,
              debit: (p['amount_paid'] as num?)?.toDouble() ?? 0,
              credit: 0),
          LedgerLine(
              account: accReceivable,
              debit: 0,
              credit: (p['amount_paid'] as num?)?.toDouble() ?? 0),
        ],
      ));
    }

    // 3. Expenses → expense / Cash
    final expenses = await db.rawQuery('''
      SELECT e.date, e.description, e.amount, e.account_id,
             c.name AS category
             , a.currency_code
      FROM expenses e
      LEFT JOIN expense_categories c ON c.id = e.category_id
      LEFT JOIN financial_accounts a ON a.id = e.account_id
      WHERE 1 = 1 ${dateFilter('e.date')} ${currencyFilter('a.currency_code')}
      ORDER BY e.date
    ''', [if (currencyCode != null) currencyCode]);
    for (final e in expenses) {
      final category = e['category'] as String? ?? 'General';
      final amount = (e['amount'] as num?)?.toDouble() ?? 0;
      entries.add(JournalEntry(
        date: DateTime.tryParse(e['date'] as String? ?? '') ?? DateTime.now(),
        description: 'Expense — ${e['description'] ?? category}',
        lines: [
          LedgerLine(
              account: '$accExpenses: $category', debit: amount, credit: 0),
          LedgerLine(
              account: accountName(e['account_id'] as String?),
              debit: 0,
              credit: amount),
        ],
      ));
    }

    // 4. Purchase bills → Purchases + ITC / Payables.
    final bills = await db.rawQuery('''
      SELECT b.id, b.date, b.supplier_name, b.total_amount, b.total_tax,
             b.amount_paid, b.currency_symbol, b.currency_code,
             COALESCE(SUM(p.amount_paid), 0) AS recorded_paid
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
      final net = total - tax;
      // Pre-v47 bills stored only an aggregate paid amount. Preserve that
      // historical payment as a bill-date cash movement when no payment
      // records exist, while newer bills use the dated payment rows below.
      final recordedPaid = (b['recorded_paid'] as num?)?.toDouble() ?? 0;
      final legacyPaid = recordedPaid <= 0
          ? ((b['amount_paid'] as num?)?.toDouble() ?? 0)
              .clamp(0, total)
              .toDouble()
          : 0.0;
      final date =
          DateTime.tryParse(b['date'] as String? ?? '') ?? DateTime.now();
      entries.add(JournalEntry(
        date: date,
        description:
            'Purchase — ${b['supplier_name'] ?? ''} (${b['currency_symbol'] ?? ''}${total.toStringAsFixed(2)})',
        lines: [
          LedgerLine(account: accPurchases, debit: net, credit: 0),
          LedgerLine(account: accGstInput, debit: tax, credit: 0),
          if (legacyPaid > 0)
            LedgerLine(account: accCash, debit: 0, credit: legacyPaid),
          LedgerLine(
              account: accPayable,
              debit: 0,
              credit: total - legacyPaid),
        ],
      ));
    }

    // Purchase payments settle payables on their actual payment date.
    final purchasePayments = await db.rawQuery('''
      SELECT p.date_paid AS d, p.amount_paid, p.payment_method,
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
      entries.add(JournalEntry(
        date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
        description: 'Purchase payment — ${p['supplier_name'] ?? ''}',
        lines: [
          LedgerLine(account: accPayable, debit: amount, credit: 0),
          LedgerLine(account: paymentAccount, debit: 0, credit: amount),
        ],
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
      final bank = accountName(cheque['bank_account_id'] as String?,
          fallback: accBank);
      final received = cheque['direction'] == 'received';
      entries.add(JournalEntry(
          date: DateTime.tryParse(cheque['cleared_at'] as String? ?? '') ??
              DateTime.now(),
          description: 'Cheque cleared — ${cheque['cheque_number']}',
          lines: received
              ? [
                  LedgerLine(account: bank, debit: amount, credit: 0),
                  LedgerLine(
                      account: accChequesInHand, debit: 0, credit: amount),
                ]
              : [
                  LedgerLine(
                      account: accChequesIssued, debit: amount, credit: 0),
                  LedgerLine(account: bank, debit: 0, credit: amount),
                ]));
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
        entries.add(JournalEntry(
            date: DateTime.parse(row['date'] as String),
            description: 'Balance adjustment — ${row['notes'] ?? ''}',
            lines: amount >= 0
                ? [
                    LedgerLine(
                        account: accountName(row['account_id'] as String),
                        debit: amount,
                        credit: 0),
                    LedgerLine(
                        account: accCapital, debit: 0, credit: amount),
                  ]
                : [
                    LedgerLine(
                        account: accCapital, debit: -amount, credit: 0),
                    LedgerLine(
                        account: accountName(row['account_id'] as String),
                        debit: 0,
                        credit: -amount),
                  ]));
      } else {
        transferGroups
            .putIfAbsent(row['source_id'] as String, () => [])
            .add(row);
      }
    }
    for (final group in transferGroups.values) {
      entries.add(JournalEntry(
          date: DateTime.parse(group.first['date'] as String),
          description: 'Account transfer',
          lines: group.map((row) {
            final amount = (row['amount'] as num).toDouble();
            return LedgerLine(
                account: accountName(row['account_id'] as String),
                debit: amount > 0 ? amount : 0,
                credit: amount < 0 ? -amount : 0);
          }).toList()));
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
      final principal =
          (movement['principal_amount'] as num?)?.toDouble() ?? 0;
      final interest =
          (movement['interest_amount'] as num?)?.toDouble() ?? 0;
      final fees = (movement['fee_amount'] as num?)?.toDouble() ?? 0;
      final account = accountName(movement['account_id'] as String?);
      final drawdown = movement['type'] == 'drawdown';
      entries.add(JournalEntry(
          date: DateTime.parse(movement['date'] as String),
          description: '${drawdown ? 'Loan drawdown' : 'Loan repayment'} — '
              '${movement['loan_name']}',
          lines: drawdown
              ? [
                  LedgerLine(account: account, debit: principal, credit: 0),
                  LedgerLine(
                      account: '$accLoanLiability: ${movement['loan_name']}',
                      debit: 0,
                      credit: principal),
                ]
              : [
                  LedgerLine(
                      account: '$accLoanLiability: ${movement['loan_name']}',
                      debit: principal,
                      credit: 0),
                  if (interest > 0)
                    LedgerLine(
                        account: accInterestExpense,
                        debit: interest,
                        credit: 0),
                  if (fees > 0)
                    LedgerLine(account: accBankFees, debit: fees, credit: 0),
                  LedgerLine(
                      account: account,
                      debit: 0,
                      credit: principal + interest + fees),
                ]));
    }

    // Account-level opening balances are equity-funded balance forwards, not
    // income. They are distinct from the legacy single opening_capital key.
    for (final accountRow in accountRows) {
      final opening =
          (accountRow['opening_balance'] as num?)?.toDouble() ?? 0;
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
      entries.add(JournalEntry(
          date: openingDate,
          description: 'Opening balance — ${accountRow['name']}',
          lines: opening >= 0
              ? [
                  LedgerLine(account: account, debit: opening, credit: 0),
                  LedgerLine(
                      account: accCapital, debit: 0, credit: opening),
                ]
              : [
                  LedgerLine(
                      account: accCapital, debit: -opening, credit: 0),
                  LedgerLine(account: account, debit: 0, credit: -opening),
                ]));
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
    final journal = await getJournal(
        from: from, to: to, currencyCode: currencyCode);
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
  static Future<BalanceSheet> getBalanceSheet({
    DateTime? from,
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
    for (final r in tb.rows) {
      if (r.account == accSales) salesCredit += r.credit - r.debit;
      if (r.account == accPurchases) purchasesDebit += r.debit - r.credit;
      if (r.account.startsWith(accExpenses)) expensesDebit += r.debit - r.credit;
      if (r.account == accInterestExpense || r.account == accBankFees) {
        expensesDebit += r.debit - r.credit;
      }
      if (r.account == accGstOutput) gstOutputCredit += r.credit - r.debit;
    }
    // Net income = Sales (credit) − Purchases (debit) − Expenses (debit).
    final netProfit = salesCredit - purchasesDebit - expensesDebit;

    final receivable = getNet(accReceivable);
    final chequesInHand = getNet(accChequesInHand);
    final chequesIssued = -getNet(accChequesIssued);
    final loans = -getNet(accLoanLiability);
    final cash = getNet(accCash) + getNet(accBank);
    final payable = -(getNet(accPayable));
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
  const JournalEntry({
    required this.date,
    required this.description,
    required this.lines,
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
