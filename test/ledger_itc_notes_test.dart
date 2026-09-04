import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/ledger_service.dart';
import 'package:apexbooks/database/report_service.dart';

/// P1 ledger correctness: ITC eligibility, reverse charge, credit/debit
/// notes, and single (accrual) P&L matching the ledger.
void main() {
  late Database db;
  final from = DateTime(2026, 1, 1);
  final to = DateTime(2026, 1, 31);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> insertInvoice(
    String id,
    String type,
    DateTime date,
    double unitPrice, {
    String? refId,
  }) async {
    await db.insert('invoices', {
      'id': id,
      'invoice_number': id,
      'customer_id': 'c-test',
      'customer_name': 'Test Customer',
      'date': date.toIso8601String(),
      'tax_rate': 0.18,
      'type': type,
      'currency_code': 'INR',
      'currency_symbol': '₹',
      'tax_mode': 'global',
      'reference_invoice_id': refId,
    });
    await db.insert('invoice_items', {
      'id': 'item-$id',
      'invoice_id': id,
      'product_name': 'Widget',
      'product_price': unitPrice,
      'unit_price': unitPrice,
      'quantity': 1.0,
      'discount': 0.0,
      'discount_per_unit': 0,
      'extra_cost': 0.0,
      'product_tax_rate': 0,
      'product_price_includes_tax': 0,
    });
  }

  Future<void> insertBill(
    String id,
    String supplier,
    DateTime date,
    double total,
    double tax, {
    bool eligible = true,
    bool rc = false,
  }) async {
    await db.insert('purchase_bills', {
      'id': id,
      'supplier_name': supplier,
      'date': date.toIso8601String(),
      'total_amount': total,
      'total_tax': tax,
      'amount_paid': 0,
      'itc_eligible': eligible ? 1 : 0,
      'reverse_charge': rc ? 1 : 0,
      'currency_code': 'INR',
      'currency_symbol': '₹',
    });
  }

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath,
        version: DatabaseHelper().dbVersion,
        singleInstance: false,
        onCreate: (database, version) =>
            DatabaseHelper().createDbForTest(database, version));
    DatabaseHelper().useDatabaseForTest(db);
    // createDbForTest only runs _createDB, which predates the migration
    // that adds payment-account columns to purchase_bill_payments
    // (database_helper _upgradeDB). Bring the in-memory schema up to the
    // level the ledger queries expect; no-ops on already-migrated DBs.
    for (final sql in [
      'ALTER TABLE purchase_bill_payments ADD COLUMN account_id TEXT',
      'ALTER TABLE purchase_bill_payments ADD COLUMN cheque_id TEXT',
      "ALTER TABLE purchase_bill_payments ADD COLUMN cheque_status TEXT DEFAULT 'none'",
      'ALTER TABLE purchase_bill_payments ADD COLUMN payment_group_id TEXT',
    ]) {
      try {
        await db.execute(sql);
      } catch (_) {
        // Column already exists.
      }
    }

    // Purchase bills: eligible (net 1000/tax 180), ineligible
    // (total 1120/tax 120, no ITC), RC eligible (net 1000/tax 180).
    await insertBill(
        'bill-elig', 'Supplier A', DateTime(2026, 1, 5), 1180, 180);
    await insertBill(
        'bill-inelig', 'Supplier B', DateTime(2026, 1, 6), 1120, 120,
        eligible: false);
    await insertBill('bill-rc', 'Supplier C', DateTime(2026, 1, 7), 1180, 180,
        rc: true);

    // Sales: invoice net 1000, partial credit note net 500 (reversal),
    // debit note net 200 (additional sale). Accrual revenue = 700.
    await insertInvoice('inv-1', 'Invoice', DateTime(2026, 1, 10), 1000);
    await insertInvoice('cn-1', 'Credit Note', DateTime(2026, 1, 12), 500,
        refId: 'inv-1');
    await insertInvoice('dn-1', 'Debit Note', DateTime(2026, 1, 13), 200,
        refId: 'inv-1');

    // One expense + one receipt (cash memo).
    await db.insert('expenses', {
      'id': 'exp-1',
      'description': 'Rent',
      'amount': 300,
      'date': DateTime(2026, 1, 15).toIso8601String(),
      'category_id': 'cat-other',
    });
    await db.insert('invoice_payments', {
      'id': 'pay-1',
      'invoice_id': 'inv-1',
      'invoice_number': 'inv-1',
      'receipt_number': 'r-1',
      'amount_paid': 500,
      'balance_after': 0,
      'date_paid': DateTime(2026, 1, 20).toIso8601String(),
      'cheque_status': 'none',
    });
  });

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
    await db.close();
  });

  double debitOf(JournalEntry e, String account) => e.lines
      .where((l) => l.account == account)
      .fold(0.0, (s, l) => s + l.debit);
  double creditOf(JournalEntry e, String account) => e.lines
      .where((l) => l.account == account)
      .fold(0.0, (s, l) => s + l.credit);

  test('ITC eligibility: ineligible posts full total, no ITC split', () async {
    final journal = await LedgerService.getJournal(from: from, to: to);
    final inelig =
        journal.firstWhere((e) => e.description.contains('Supplier B'));
    // Full total expensed, no GST Input leg.
    expect(debitOf(inelig, LedgerService.accPurchases), closeTo(1120, 0.01));
    expect(debitOf(inelig, LedgerService.accGstInput), 0);
    expect(creditOf(inelig, LedgerService.accPayable), closeTo(1120, 0.01));

    final elig =
        journal.firstWhere((e) => e.description.contains('Supplier A'));
    expect(debitOf(elig, LedgerService.accPurchases), closeTo(1000, 0.01));
    expect(debitOf(elig, LedgerService.accGstInput), closeTo(180, 0.01));
    expect(creditOf(elig, LedgerService.accPayable), closeTo(1180, 0.01));
  });

  test('reverse charge posts Input/Output pair, payables net only', () async {
    final journal = await LedgerService.getJournal(from: from, to: to);
    final rc = journal.firstWhere((e) => e.description.contains('Supplier C'));
    expect(debitOf(rc, LedgerService.accPurchases), closeTo(1000, 0.01));
    expect(debitOf(rc, LedgerService.accGstInput), closeTo(180, 0.01));
    expect(creditOf(rc, LedgerService.accGstOutput), closeTo(180, 0.01));
    // Supplier owed net only (tax self-assessed to government).
    expect(creditOf(rc, LedgerService.accPayable), closeTo(1000, 0.01));

    // Balance sheet ITC holds eligible ITC (180 non-RC + 180 RC gross,
    // the RC leg offset by the paired Output above).
    final bs = await LedgerService.getBalanceSheet(to: to);
    expect(bs.gstInput, closeTo(360, 0.01));
    expect(bs.gstOutput, closeTo(306, 0.01));
  });

  test('credit note reverses sale, debit note adds sale', () async {
    final journal = await LedgerService.getJournal(from: from, to: to);
    // inv-1: net 1000/tax 180/total 1180.
    final inv = journal.firstWhere((e) => e.description.startsWith('Sale —'));
    expect(debitOf(inv, LedgerService.accReceivable), closeTo(1180, 0.01));
    expect(creditOf(inv, LedgerService.accSales), closeTo(1000, 0.01));
    expect(creditOf(inv, LedgerService.accGstOutput), closeTo(180, 0.01));

    // cn-1: net 500/tax 90/total 590 reversal.
    final cn =
        journal.firstWhere((e) => e.description.startsWith('Credit Note —'));
    expect(debitOf(cn, LedgerService.accSales), closeTo(500, 0.01));
    expect(debitOf(cn, LedgerService.accGstOutput), closeTo(90, 0.01));
    expect(creditOf(cn, LedgerService.accReceivable), closeTo(590, 0.01));

    // dn-1: net 200/tax 36/total 236 additional sale.
    final dn =
        journal.firstWhere((e) => e.description.startsWith('Debit Note —'));
    expect(debitOf(dn, LedgerService.accReceivable), closeTo(236, 0.01));
    expect(creditOf(dn, LedgerService.accSales), closeTo(200, 0.01));
    expect(creditOf(dn, LedgerService.accGstOutput), closeTo(36, 0.01));

    final tb = await LedgerService.getTrialBalance(from: from, to: to);
    expect(tb.balanced, isTrue);
  });

  test('getPnl accrual matches ledger netProfit (single P&L)', () async {
    final pnl = await ReportService.getPnl(from, to);
    // Revenue 1000 − 500 + 200 = 700; purchases 1000 + 1120 + 1000 = 3120.
    expect(pnl.revenue, closeTo(700, 0.01));
    expect(pnl.purchases, closeTo(3120, 0.01));
    expect(pnl.expenses, closeTo(300, 0.01));
    expect(pnl.profit, closeTo(-2720, 0.01));
    // Cash memos, not part of profit.
    expect(pnl.collected, closeTo(500, 0.01));
    expect(pnl.paid, 0);

    final bs = await LedgerService.getBalanceSheet(to: to);
    expect(pnl.profit, closeTo(bs.netProfit, 0.01));
  });
}
