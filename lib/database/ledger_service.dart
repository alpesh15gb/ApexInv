import '../database/database_helper.dart';

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

    // 1. Sales invoices → AR / Sales + GST Output
    String currencyFilter(String column) =>
        currencyCode == null ? '' : ' AND $column = ?';
    final invoices = await db.rawQuery('''
      SELECT i.id, i.date, i.customer_name, i.total, i.tax, i.currency_symbol
      FROM invoices i
      WHERE i.deleted_at IS NULL AND i.type = 'Invoice'
      ${currencyFilter('i.currency_code')}
      ${dateFilter('i.date')}
      ORDER BY i.date
    ''', [if (currencyCode != null) currencyCode]);
    for (final inv in invoices) {
      final total = (inv['total'] as num?)?.toDouble() ?? 0;
      final tax = (inv['tax'] as num?)?.toDouble() ?? 0;
      final net = total - tax;
      final date = DateTime.tryParse(inv['date'] as String? ?? '') ??
          DateTime.now();
      entries.add(JournalEntry(
        date: date,
        description:
            'Sale — ${inv['customer_name'] ?? ''} (${inv['currency_symbol'] ?? ''}${total.toStringAsFixed(2)})',
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
      SELECT p.date_paid AS d, p.amount_paid, p.payment_method, p.customer_name
      FROM invoice_payments p
      JOIN invoices i ON i.id = p.invoice_id
      WHERE i.deleted_at IS NULL AND i.type = 'Invoice'
      ${currencyFilter('i.currency_code')}
      ${dateFilter('p.date_paid')}
      ORDER BY d
    ''', [if (currencyCode != null) currencyCode]);
    for (final p in payments) {
      final method = p['payment_method'] as String? ?? 'Cash';
      final account =
          method == 'Cash' ? accCash : accBank; // cheques settle at bank
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
      SELECT e.date, e.description, e.amount, c.name AS category
      FROM expenses e
      LEFT JOIN expense_categories c ON c.id = e.category_id
      ${currencyCode == null || currencyCode == 'INR' ? dateFilter('e.date') : ' AND 1 = 0'}
      ORDER BY e.date
    ''');
    for (final e in expenses) {
      final category = e['category'] as String? ?? 'General';
      final amount = (e['amount'] as num?)?.toDouble() ?? 0;
      entries.add(JournalEntry(
        date: DateTime.tryParse(e['date'] as String? ?? '') ?? DateTime.now(),
        description: 'Expense — ${e['description'] ?? category}',
        lines: [
          LedgerLine(
              account: '$accExpenses: $category', debit: amount, credit: 0),
          LedgerLine(account: accCash, debit: 0, credit: amount),
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
             b.supplier_name, b.currency_code
      FROM purchase_bill_payments p
      JOIN purchase_bills b ON b.id = p.purchase_bill_id
      WHERE 1 = 1
      ${currencyFilter('b.currency_code')}
      ${dateFilter('p.date_paid')}
      ORDER BY d
    ''', [if (currencyCode != null) currencyCode]);
    for (final p in purchasePayments) {
      final amount = (p['amount_paid'] as num?)?.toDouble() ?? 0;
      entries.add(JournalEntry(
        date: DateTime.tryParse(p['d'] as String? ?? '') ?? DateTime.now(),
        description: 'Purchase payment — ${p['supplier_name'] ?? ''}',
        lines: [
          LedgerLine(account: accPayable, debit: amount, credit: 0),
          LedgerLine(account: accCash, debit: 0, credit: amount),
        ],
      ));
    }

    // 5. Opening capital is a real opening entry, never omitted because other
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

    final opening = currencyCode == null || currencyCode == 'INR'
        ? await getOpeningCapital()
        : 0.0;
    double salesCredit = 0;
    double purchasesDebit = 0;
    double expensesDebit = 0;
    double gstOutputCredit = 0;
    for (final r in tb.rows) {
      if (r.account == accSales) salesCredit += r.credit - r.debit;
      if (r.account == accPurchases) purchasesDebit += r.debit - r.credit;
      if (r.account.startsWith(accExpenses)) expensesDebit += r.debit - r.credit;
      if (r.account == accGstOutput) gstOutputCredit += r.credit - r.debit;
    }
    // Net income = Sales (credit) − Purchases (debit) − Expenses (debit).
    final netProfit = salesCredit - purchasesDebit - expensesDebit;

    final receivable = getNet(accReceivable);
    final cash = getNet(accCash) + getNet(accBank);
    final payable = -(getNet(accPayable));
    final gstInput = getNet(accGstInput);

    return BalanceSheet(
      cash: cash,
      receivable: receivable,
      gstInput: gstInput,
      gstOutput: gstOutputCredit,
      payables: payable,
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
  final double receivable;
  final double gstInput;
  final double gstOutput;
  final double payables;
  final double openingCapital;
  final double netProfit;
  final double totalDebit;
  final double totalCredit;
  const BalanceSheet({
    required this.cash,
    required this.receivable,
    required this.gstInput,
    required this.gstOutput,
    required this.payables,
    required this.openingCapital,
    required this.netProfit,
    required this.totalDebit,
    required this.totalCredit,
  });

  double get assets => cash + receivable + gstInput;
  double get liabilitiesAndEquity =>
      payables + gstOutput + openingCapital + netProfit;
}
