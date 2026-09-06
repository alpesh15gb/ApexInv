import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/expense_service.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/journal_store.dart';
import 'package:apexbooks/database/ledger_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/report_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/expense.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';

/// Parity evidence for the projected → persisted ledger conversion (v56).
///
/// The persisted journal ([JournalStore]) and the deterministic projection
/// ([LedgerService.getProjectedJournal]) share the [LedgerPostings]
/// builders, so every reported figure must be numerically identical whether
/// it is read from posted rows or derived live. These tests pin that:
///
///  A. backfill: raw-seeded sources → figures before/after [JournalStore.backfill]
///  B. write paths: every service mutation keeps union == projection
///  C. reversals: mirrors net to zero, journal rows are never updated/deleted
void main() {
  late Database db;
  final from = DateTime(2026, 1, 1);
  final to = DateTime(2026, 1, 31);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> openDb() async {
    db = await openDatabase(inMemoryDatabasePath,
        version: DatabaseHelper().dbVersion,
        singleInstance: false,
        onCreate: (database, version) =>
            DatabaseHelper().createDbForTest(database, version));
    DatabaseHelper().useDatabaseForTest(db);
  }

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
    await db.close();
  });

  Map<String, (double, double)> sums(List<JournalEntry> entries) {
    final m = <String, (double, double)>{};
    for (final e in entries) {
      for (final l in e.lines) {
        final cur = m[l.account] ?? (0.0, 0.0);
        m[l.account] = (cur.$1 + l.debit, cur.$2 + l.credit);
      }
    }
    // Fully-netted mirror pairs leave (0, 0) accounts persisted-side only;
    // they change no figure, so drop them on both sides before comparing.
    m.removeWhere((_, v) => v.$1.abs() < 0.005 && v.$2.abs() < 0.005);
    return m;
  }

  void expectSumsEqual(
      List<JournalEntry> a, List<JournalEntry> b, String reason) {
    // Compare NET balance per account: mirror pairs add equal debit+credit
    // legs (an immutable journal keeps both), so gross per-side sums differ
    // by design while every reported figure — revenue, profit, balances,
    // tax buckets — is a net. Fully-netted accounts drop on both sides.
    double net(Map<String, (double, double)> m, String k) =>
        (m[k]?.$1 ?? 0) - (m[k]?.$2 ?? 0);
    final sa = sums(a);
    final sb = sums(b);
    final keys = {...sa.keys, ...sb.keys}
        .where((k) => net(sa, k).abs() >= 0.005 || net(sb, k).abs() >= 0.005);
    for (final k in keys) {
      expect(net(sa, k), closeTo(net(sb, k), 0.01), reason: '$reason: net $k');
    }
  }

  void expectBalanced(List<JournalEntry> entries) {
    for (final e in entries) {
      final d = e.lines.fold(0.0, (s, l) => s + l.debit);
      final c = e.lines.fold(0.0, (s, l) => s + l.credit);
      expect((d - c).abs(), lessThanOrEqualTo(0.01),
          reason: 'unbalanced: ${e.description}');
    }
  }

  /// Union (persisted-first) must agree paise-for-paise with the projection.
  Future<void> expectParity(String step) async {
    final projected = await LedgerService.getProjectedJournal();
    final union = await LedgerService.getJournal();
    expectSumsEqual(union, projected, step);
    expectBalanced(union);
    final tb = await LedgerService.getTrialBalance();
    expect(tb.balanced, isTrue, reason: step);
  }

  Future<void> expectParityRanged(String step) async {
    final projected = await LedgerService.getProjectedJournal(
        from: from, to: to);
    final union = await LedgerService.getJournal(from: from, to: to);
    expectSumsEqual(union, projected, step);
    expectBalanced(union);
  }

  group('A backfill parity on raw seeds', () {
    Future<void> seedRaw() async {
      await db.insert('purchase_bills', {
        'id': 'bill-elig',
        'supplier_name': 'Supplier A',
        'date': DateTime(2026, 1, 5).toIso8601String(),
        'total_amount': 1180,
        'total_tax': 180,
        'amount_paid': 0,
        'itc_eligible': 1,
        'reverse_charge': 0,
        'currency_code': 'INR',
        'currency_symbol': '₹',
      });
      await db.insert('purchase_bills', {
        'id': 'bill-inelig',
        'supplier_name': 'Supplier B',
        'date': DateTime(2026, 1, 6).toIso8601String(),
        'total_amount': 1120,
        'total_tax': 120,
        'amount_paid': 0,
        'itc_eligible': 0,
        'reverse_charge': 0,
        'currency_code': 'INR',
        'currency_symbol': '₹',
      });
      await db.insert('purchase_bills', {
        'id': 'bill-rc',
        'supplier_name': 'Supplier C',
        'date': DateTime(2026, 1, 7).toIso8601String(),
        'total_amount': 1180,
        'total_tax': 180,
        'amount_paid': 0,
        'itc_eligible': 1,
        'reverse_charge': 1,
        'currency_code': 'INR',
        'currency_symbol': '₹',
      });
      // Pre-v47 style aggregate-paid bill with no payment rows.
      await db.insert('purchase_bills', {
        'id': 'bill-legacy',
        'supplier_name': 'Supplier D',
        'date': DateTime(2026, 1, 8).toIso8601String(),
        'total_amount': 500,
        'total_tax': 0,
        'amount_paid': 200,
        'itc_eligible': 1,
        'reverse_charge': 0,
        'currency_code': 'INR',
        'currency_symbol': '₹',
      });
      Future<void> invoice(String id, String type, DateTime date,
          double unitPrice, double rate) async {
        await db.insert('invoices', {
          'id': id,
          'invoice_number': id,
          'customer_id': 'c-test',
          'customer_name': 'Test Customer',
          'date': date.toIso8601String(),
          'tax_rate': rate,
          'type': type,
          'currency_code': 'INR',
          'currency_symbol': '₹',
          'tax_mode': 'global',
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

      await invoice(
          'inv-1', 'Invoice', DateTime(2026, 1, 10), 1000, 0.18);
      await invoice(
          'cn-1', 'Credit Note', DateTime(2026, 1, 12), 500, 0.18);
      await invoice(
          'dn-1', 'Debit Note', DateTime(2026, 1, 13), 200, 0.18);
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
        'payment_method': 'Cash',
        'cheque_status': 'none',
      });
      await db.insert('purchase_bill_payments', {
        'id': 'pbp-1',
        'purchase_bill_id': 'bill-elig',
        'amount_paid': 180,
        'previously_paid': 0,
        'balance_after': 1000,
        'date_paid': DateTime(2026, 1, 21).toIso8601String(),
        'payment_method': 'Cash',
        'cheque_status': 'none',
      });
      await db.insert('financial_accounts', {
        'id': 'bank-a',
        'name': 'Bank A',
        'type': 'bank',
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'opening_balance': 1000,
        'opening_date': DateTime(2026, 1, 1).toIso8601String(),
        'active': 1,
      });
      await db.insert('financial_transactions', {
        'id': 'tx-t1',
        'account_id': 'bank-a',
        'transfer_account_id': 'cash-default',
        'kind': 'transfer_out',
        'amount': -250,
        'date': DateTime(2026, 1, 22).toIso8601String(),
        'source_type': 'transfer',
        'source_id': 'grp-1',
      });
      await db.insert('financial_transactions', {
        'id': 'tx-t2',
        'account_id': 'cash-default',
        'transfer_account_id': 'bank-a',
        'kind': 'transfer_in',
        'amount': 250,
        'date': DateTime(2026, 1, 22).toIso8601String(),
        'source_type': 'transfer',
        'source_id': 'grp-1',
      });
      await db.insert('financial_transactions', {
        'id': 'tx-adj',
        'account_id': 'cash-default',
        'kind': 'adjustment',
        'amount': 50,
        'date': DateTime(2026, 1, 23).toIso8601String(),
        'source_type': 'adjustment',
        'source_id': 'adj-1',
        'notes': 'correction',
      });
      await db.insert('loan_accounts', {
        'id': 'loan-1',
        'name': 'Working capital',
        'lender': 'Bank',
        'original_principal': 10000,
        'annual_interest_rate': 0,
        'start_date': DateTime(2026, 1, 2).toIso8601String(),
        'disbursement_account_id': 'cash-default',
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'status': 'active',
      });
      await db.insert('loan_movements', {
        'id': 'lm-1',
        'loan_id': 'loan-1',
        'date': DateTime(2026, 1, 2).toIso8601String(),
        'type': 'drawdown',
        'principal_amount': 10000,
        'interest_amount': 0,
        'fee_amount': 0,
        'account_id': 'cash-default',
      });
      await db.insert('loan_movements', {
        'id': 'lm-2',
        'loan_id': 'loan-1',
        'date': DateTime(2026, 1, 25).toIso8601String(),
        'type': 'repayment',
        'principal_amount': 2000,
        'interest_amount': 100,
        'fee_amount': 25,
        'account_id': 'cash-default',
      });
      await db.insert('cheques', {
        'id': 'ch-1',
        'direction': 'received',
        'party_name': 'Test Customer',
        'amount': 400,
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'cheque_number': '111',
        'cheque_date': DateTime(2026, 1, 18).toIso8601String(),
        'status': 'cleared',
        'source_type': 'manual_cheque',
        'source_id': 'm-1',
        'bank_account_id': 'bank-a',
        'cleared_at': DateTime(2026, 1, 24).toIso8601String(),
      });
    }

    test('backfill keeps every figure identical', () async {
      await openDb();
      await seedRaw();

      final proj0 = await LedgerService.getProjectedJournal(from: from, to: to);
      final tb0 = await LedgerService.getTrialBalance(from: from, to: to);
      final bs0 = await LedgerService.getBalanceSheet(to: to);
      final pnl0 = await ReportService.getPnl(from, to);
      expect(tb0.balanced, isTrue);

      final count = await JournalStore.backfill(db);
      expect(count, proj0.length);

      final union = await LedgerService.getJournal(from: from, to: to);
      expect(union.length, proj0.length);
      expectSumsEqual(union, proj0, 'backfill');
      expectBalanced(union);

      final tb1 = await LedgerService.getTrialBalance(from: from, to: to);
      expect(tb1.totalDebit, closeTo(tb0.totalDebit, 0.01));
      expect(tb1.totalCredit, closeTo(tb0.totalCredit, 0.01));
      expect(tb1.balanced, isTrue);

      final bs1 = await LedgerService.getBalanceSheet(to: to);
      expect(bs1.receivable, closeTo(bs0.receivable, 0.01));
      expect(bs1.gstInput, closeTo(bs0.gstInput, 0.01));
      expect(bs1.gstOutput, closeTo(bs0.gstOutput, 0.01));
      expect(bs1.netProfit, closeTo(bs0.netProfit, 0.01));
      expect(bs1.cash, closeTo(bs0.cash, 0.01));
      expect(bs1.payables, closeTo(bs0.payables, 0.01));

      final pnl1 = await ReportService.getPnl(from, to);
      expect(pnl1.revenue, closeTo(pnl0.revenue, 0.01));
      expect(pnl1.purchases, closeTo(pnl0.purchases, 0.01));
      expect(pnl1.expenses, closeTo(pnl0.expenses, 0.01));
      expect(pnl1.profit, closeTo(pnl0.profit, 0.01));
      expect(pnl1.profit, closeTo(bs1.netProfit, 0.01));

      // Backfill is re-run safe: second pass posts nothing.
      expect(await JournalStore.backfill(db), 0);
    });
  });

  group('B service write paths keep union == projection', () {
    Product makeProduct() => Product(
          id: 'p-par',
          name: 'Parity Widget',
          description: '',
          price: 100,
          stock: 1000000,
          hsncode: '',
          tax_rate: 0,
        );

    Invoice doc(String id, String type, double unitPrice,
        {bool roundOff = false, double rate = 0.18}) {
      return Invoice(
        id: id,
        invoiceNumber: id,
        customer: Customer(
            id: 'c-par',
            name: 'Parity Buyer',
            email: '',
            phone: '',
            address: '',
            gstin: ''),
        items: [
          InvoiceItem(product: makeProduct(), quantity: 1, unitPrice: unitPrice)
        ],
        date: DateTime(2026, 1, 10),
        type: type,
        taxRate: rate,
        roundOffEnabled: roundOff,
      );
    }

    PurchaseBill bill(String id,
        {double total = 1180,
        double tax = 180,
        bool elig = true,
        bool rc = false}) {
      return PurchaseBill(
        id: id,
        billNumber: 'B-$id',
        supplierName: 'Parity Supplier $id',
        date: DateTime(2026, 1, 5),
        totalAmount: total,
        totalTax: tax,
        itcEligible: elig,
        reverseCharge: rc,
        items: const [],
      );
    }

    test('full lifecycle parity', () async {
      await openDb();

      // Sales incl. round-off + notes.
      await InvoiceService.insertInvoice(
          doc('par-inv', 'Invoice', 100, roundOff: true, rate: 0.1806));
      await expectParity('sale');
      await InvoiceService.insertInvoice(doc('par-cn', 'Credit Note', 50));
      await expectParity('credit note');
      await InvoiceService.insertInvoice(doc('par-dn', 'Debit Note', 200));
      await expectParity('debit note');
      await expectParityRanged('ranged');

      // Receipts: cash + cheque clear + bounce.
      var stored =
          (await InvoiceService.getInvoiceById('par-inv'))!;
      final cashPay = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 50,
        datePaid: DateTime(2026, 1, 11),
        paymentMethod: 'Cash',
      );
      await expectParity('cash receipt');
      final chqPay = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 20,
        datePaid: DateTime(2026, 1, 12),
        paymentMethod: 'Check',
        chequeNumber: 'PAR-1',
        chequeDate: DateTime(2026, 1, 12),
      );
      await expectParity('cheque receipt');
      await AccountingService.saveAccount(FinancialAccount(
        id: 'bank-par',
        name: 'Parity Bank',
        type: 'bank',
        openingDate: DateTime(2026, 1, 1),
      ));
      await AccountingService.transitionCheque(
        chequeId: chqPay.chequeId!,
        status: 'cleared',
        bankAccountId: 'bank-par',
      );
      await expectParity('cheque cleared');
      await AccountingService.transitionCheque(
        chequeId: chqPay.chequeId!,
        status: 'bounced',
        notes: 'parity bounce',
      );
      await expectParity('cheque bounced');
      await PaymentService.deletePayment(cashPay.id);
      await expectParity('receipt deleted');
      await PaymentService.deletePayment(chqPay.id);
      await expectParity('bounced receipt deleted');

      // Expenses: insert / update / delete.
      await ExpenseService.insertExpense(Expense(
        id: 'par-exp',
        description: 'Parity Rent',
        amount: 300,
        date: DateTime(2026, 1, 15),
        categoryId: 'cat-other',
      ));
      await expectParity('expense');
      await ExpenseService.updateExpense(Expense(
        id: 'par-exp',
        description: 'Parity Rent revised',
        amount: 350,
        date: DateTime(2026, 1, 15),
        categoryId: 'cat-other',
      ));
      await expectParity('expense updated');
      await ExpenseService.deleteExpense('par-exp');
      await expectParity('expense deleted');

      // Purchase bills: eligible / ineligible / RC + edit + delete.
      await PurchaseBillService.insertBill(bill('par-b1'));
      await PurchaseBillService.insertBill(
          bill('par-b2', total: 1120, tax: 120, elig: false));
      await PurchaseBillService.insertBill(bill('par-b3', rc: true));
      await expectParity('bills');
      await PurchaseBillService.updateBill(
          bill('par-b1', total: 2360, tax: 360));
      await expectParity('bill updated');
      final pbp = await PurchaseBillService.recordPayment(
        'par-b1',
        360,
        datePaid: DateTime(2026, 1, 16),
        paymentMethod: 'Cash',
      );
      await expectParity('bill payment');
      await PurchaseBillService.deletePayment(pbp);
      await expectParity('bill payment deleted');
      await PurchaseBillService.softDeleteBill('par-b2');
      await expectParity('bill deleted');

      // Registers: opening, transfer, adjustment, loans.
      await AccountingService.saveAccount(FinancialAccount(
        id: 'bank-open',
        name: 'Opening Bank',
        type: 'bank',
        openingBalance: 1000,
        openingDate: DateTime(2026, 1, 1),
      ));
      await expectParity('account opening');
      await AccountingService.transfer(
        fromAccountId: 'bank-open',
        toAccountId: 'cash-default',
        amount: 250,
        date: DateTime(2026, 1, 17),
      );
      await expectParity('transfer');
      await AccountingService.adjustBalance(
        accountId: 'cash-default',
        amount: 25,
        date: DateTime(2026, 1, 18),
        reason: 'parity correction',
      );
      await expectParity('adjustment');
      await AccountingService.createLoan(LoanAccount(
        id: 'loan-par',
        name: 'Parity Loan',
        lender: 'Bank',
        originalPrincipal: 10000,
        startDate: DateTime(2026, 1, 3),
        disbursementAccountId: 'cash-default',
      ));
      await expectParity('loan drawdown');
      await AccountingService.recordLoanRepayment(
        loanId: 'loan-par',
        accountId: 'cash-default',
        principal: 2000,
        interest: 100,
        fees: 25,
        date: DateTime(2026, 1, 20),
      );
      await expectParity('loan repayment');

      // Invoice lifecycle: soft delete / restore / permanent delete.
      await InvoiceService.softDeleteInvoice('par-dn');
      await expectParity('invoice trashed');
      await InvoiceService.restoreInvoice('par-dn');
      await expectParity('invoice restored');
      await InvoiceService.permanentDeleteInvoice('par-cn');
      await expectParity('invoice permanently deleted');

      // P&L agrees with the balance sheet on the persisted journal.
      // Revenue: par-inv net 100 + par-dn net 200 (par-cn deleted).
      final bs = await LedgerService.getBalanceSheet(to: to);
      final pnl = await ReportService.getPnl(from, to);
      expect(pnl.revenue, closeTo(300, 0.01));
      expect(pnl.profit, closeTo(bs.netProfit, 0.01));
    });

    test('reversals are mirrors, never edits', () async {
      await openDb();
      await InvoiceService.insertInvoice(doc('rev-inv', 'Invoice', 100));
      stored() async => (await InvoiceService.getInvoiceById('rev-inv'))!;
      final pay = await PaymentService.addPayment(
        invoice: await stored(),
        amountPaid: 50,
        datePaid: DateTime(2026, 1, 11),
        paymentMethod: 'Cash',
      );
      Future<int> entryCount() async => Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM journal_entries'))!;
      Future<int> lineCount() async => Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM journal_lines'))!;
      final entriesBefore = await entryCount();
      final linesBefore = await lineCount();
      final idsBefore = (await db.query('journal_entries', columns: ['id']))
          .map((r) => r['id'] as String)
          .toSet();

      await PaymentService.deletePayment(pay.id);

      // Nothing removed or rewritten: strictly more rows, same ids alive.
      expect(await entryCount(), greaterThan(entriesBefore));
      expect(await lineCount(), greaterThan(linesBefore));
      final idsAfter = (await db.query('journal_entries', columns: ['id']))
          .map((r) => r['id'] as String)
          .toSet();
      expect(idsAfter.containsAll(idsBefore), isTrue);
      // The mirror links back and nets the source to zero.
      final mirrors = await db.query('journal_entries',
          where: 'reversal_of IS NOT NULL AND source_id = ?',
          whereArgs: [pay.id]);
      expect(mirrors, isNotEmpty);
      await expectParity('after mirror');

      // Unbalanced postings abort loudly instead of writing drift.
      expect(
          () => JournalStore.postEntry(db,
              date: DateTime(2026, 1, 1),
              description: 'bogus',
              sourceType: 'test',
              sourceId: 'x',
              lines: const [
                LedgerLine(account: 'a', debit: 10, credit: 0),
                LedgerLine(account: 'b', debit: 0, credit: 9),
              ]),
          throwsA(isA<StateError>()));
    });
  });
}
