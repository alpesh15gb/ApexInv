import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/ledger_service.dart';
import 'package:apexbooks/database/report_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/repositories/sqlite/sqlite_company_info_repository.dart';
import 'package:apexbooks/repositories/sqlite/sqlite_installation_repository.dart';
import 'package:apexbooks/repositories/sqlite/sqlite_invoice_repository.dart';
import 'package:apexbooks/repositories/sqlite/sqlite_payment_repository.dart';
import 'package:apexbooks/repositories/sqlite/sqlite_settings_repository.dart';
import 'package:apexbooks/services/backend_services.dart';
import 'package:apexbooks/services/gstr_export_service.dart';
import 'package:apexbooks/services/pdf/pdf_widgets.dart';

/// Regression tests for VERIFIED reporting/output bugs D1–D6 (minimal edits).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    BackendServices.configure(
      settings: SqliteSettingsRepository(),
      companyInfo: SqliteCompanyInfoRepository(),
      invoices: SqliteInvoiceRepository(),
      payments: SqlitePaymentRepository(),
      installation: SqliteInstallationRepository(),
    );
  });

  late Database db;
  final from = DateTime(2026, 1, 1);
  final to = DateTime(2026, 1, 31);

  Future<void> openTestDb() async {
    db = await openDatabase(inMemoryDatabasePath,
        version: DatabaseHelper().dbVersion,
        singleInstance: false,
        onCreate: (database, version) =>
            DatabaseHelper().createDbForTest(database, version));
    DatabaseHelper().useDatabaseForTest(db);
    for (final sql in [
      'ALTER TABLE purchase_bill_payments ADD COLUMN account_id TEXT',
      'ALTER TABLE purchase_bill_payments ADD COLUMN cheque_id TEXT',
      "ALTER TABLE purchase_bill_payments ADD COLUMN cheque_status TEXT DEFAULT 'none'",
      'ALTER TABLE purchase_bill_payments ADD COLUMN payment_group_id TEXT',
    ]) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
  }

  Future<void> insertInvoiceRow(
    String id,
    String type,
    DateTime date,
    double unitPrice, {
    String currencyCode = 'INR',
    String currencySymbol = '₹',
    double taxRate = 0.18,
    String taxMode = 'global',
    int roundOff = 0,
    String customerGstin = '',
    int isInterstate = 0,
    String customerName = 'Test Customer',
  }) async {
    await db.insert('invoices', {
      'id': id,
      'invoice_number': id,
      'customer_id': 'c-test',
      'customer_name': customerName,
      'customer_gstin': customerGstin,
      'date': date.toIso8601String(),
      'tax_rate': taxRate,
      'type': type,
      'currency_code': currencyCode,
      'currency_symbol': currencySymbol,
      'tax_mode': taxMode,
      'round_off': roundOff,
      'is_interstate': isInterstate,
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

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
    await db.close();
  });

  group('D1 P&L includes loan interest/fees', () {
    setUp(openTestDb);

    test('profit matches BalanceSheet netProfit with repayment', () async {
      await insertInvoiceRow('inv-d1', 'Invoice', DateTime(2026, 1, 10), 1000);
      await db.insert('loan_accounts', {
        'id': 'loan-d1',
        'name': 'Working capital',
        'lender': 'Bank',
        'original_principal': 10000,
        'annual_interest_rate': 0,
        'start_date': DateTime(2026, 1, 1).toIso8601String(),
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'status': 'active',
      });
      await db.insert('loan_movements', {
        'id': 'lm-d1',
        'loan_id': 'loan-d1',
        'date': DateTime(2026, 1, 15).toIso8601String(),
        'type': 'repayment',
        'principal_amount': 2000,
        'interest_amount': 100,
        'fee_amount': 25,
        'account_id': 'cash-default',
      });

      final pnl = await ReportService.getPnl(from, to);
      // Revenue 1000, purchases 0, expenses 125 (interest+fees).
      expect(pnl.expenses, closeTo(125, 0.01));
      expect(pnl.profit, closeTo(875, 0.01));

      final bs = await LedgerService.getBalanceSheet(to: to);
      expect(pnl.profit, closeTo(bs.netProfit, 0.01));
    });
  });

  group('D2 bounced-cheque leakage', () {
    setUp(openTestDb);

    test('bounced purchase cheque absent from moneyOut', () async {
      await db.insert('purchase_bills', {
        'id': 'bill-d2',
        'supplier_name': 'Supplier',
        'date': DateTime(2026, 1, 5).toIso8601String(),
        'total_amount': 1000,
        'total_tax': 0,
        'amount_paid': 0,
        'itc_eligible': 1,
        'reverse_charge': 0,
        'currency_code': 'INR',
        'currency_symbol': '₹',
      });
      await db.insert('purchase_bill_payments', {
        'id': 'pbp-good',
        'purchase_bill_id': 'bill-d2',
        'amount_paid': 200,
        'date_paid': DateTime(2026, 1, 10).toIso8601String(),
        'payment_method': 'Cash',
        'cheque_status': 'none',
      });
      await db.insert('purchase_bill_payments', {
        'id': 'pbp-bounced',
        'purchase_bill_id': 'bill-d2',
        'amount_paid': 500,
        'date_paid': DateTime(2026, 1, 12).toIso8601String(),
        'payment_method': 'Check',
        'cheque_status': 'bounced',
      });

      final book = await ReportService.getDayBook(from, to);
      final moneyOut = book.fold(0.0, (s, e) => s + e.moneyOut);
      expect(moneyOut, closeTo(200, 0.01));
    });

    test('bounced receipt absent from trend collected', () async {
      await insertInvoiceRow('inv-d2', 'Invoice', DateTime(2026, 1, 10), 1000);
      await db.insert('invoice_payments', {
        'id': 'pay-good',
        'invoice_id': 'inv-d2',
        'invoice_number': 'inv-d2',
        'receipt_number': 'r-good',
        'amount_paid': 300,
        'balance_after': 0,
        'date_paid': DateTime(2026, 1, 15).toIso8601String(),
        'cheque_status': 'none',
      });
      await db.insert('invoice_payments', {
        'id': 'pay-bounced',
        'invoice_id': 'inv-d2',
        'invoice_number': 'inv-d2',
        'receipt_number': 'r-bad',
        'amount_paid': 400,
        'balance_after': 0,
        'date_paid': DateTime(2026, 1, 16).toIso8601String(),
        'cheque_status': 'bounced',
      });

      final trend = await ReportService.getMonthlyRevenueTrend(from, to);
      final collected = trend.fold(0.0, (s, p) => s + p.collected);
      expect(collected, closeTo(300, 0.01));
    });

    test('day-book includes note-linked receipts', () async {
      await insertInvoiceRow('inv-d2b', 'Invoice', DateTime(2026, 1, 10), 1000);
      await insertInvoiceRow(
          'cn-d2b', 'Credit Note', DateTime(2026, 1, 11), 100);
      await db.insert('invoice_payments', {
        'id': 'pay-note',
        'invoice_id': 'cn-d2b',
        'invoice_number': 'cn-d2b',
        'receipt_number': 'r-note',
        'amount_paid': 50,
        'balance_after': 0,
        'date_paid': DateTime(2026, 1, 18).toIso8601String(),
        'cheque_status': 'none',
      });

      final book = await ReportService.getDayBook(from, to);
      final moneyIn = book.fold(0.0, (s, e) => s + e.moneyIn);
      expect(moneyIn, closeTo(50, 0.01));
    });
  });

  group('D3 GSTR payable + notes netting', () {
    setUp(() async {
      await openTestDb();
      await db.update('company_info', {'gstin': '27ABCDE1234F1Z5'});
    });

    test('rounded invoice CSV value equals payable', () async {
      // Global 18.06% on 100 → total 118.06, payable 118.00.
      await insertInvoiceRow(
          'inv-gstr-a', 'Invoice', DateTime(2026, 1, 10), 100,
          taxRate: 0.1806, roundOff: 1, customerGstin: '29ABCDE1234F1Z5');
      final files = await GstrExportService.buildGstr1(from: from, to: to);
      final b2b = files.firstWhere((f) => f.section == 'GSTR-1 B2B');
      // B2B row: ..., Invoice Value, ..., Rate, Taxable Value, ...
      expect(b2b.csv.contains('118.00'), isTrue);
      expect(b2b.csv.contains('118.06'), isFalse);
    });

    test('sales 100k + credit 10k reports 90k in 3B', () async {
      await insertInvoiceRow(
          'inv-gstr-b', 'Invoice', DateTime(2026, 1, 10), 100000);
      await insertInvoiceRow(
          'cn-gstr-b', 'Credit Note', DateTime(2026, 1, 12), 10000);
      final summary =
          await GstrExportService.buildGstr3bSummary(from: from, to: to);
      // Table 3.1(a) taxable row should net to 90000.
      expect(summary.csv.contains('90000.00'), isTrue);

      final jsonFile =
          await GstrExportService.buildGstr3bJson(from: from, to: to);
      expect(jsonFile.csv.contains('90000'), isTrue);
    });

    test('tax-by-rate nets credit notes', () async {
      await insertInvoiceRow(
          'inv-gstr-c', 'Invoice', DateTime(2026, 1, 10), 100000);
      await insertInvoiceRow(
          'cn-gstr-c', 'Credit Note', DateTime(2026, 1, 12), 10000);
      final buckets = await ReportService.getTaxByRate(from, to);
      final total = buckets.fold(0.0, (s, b) => s + b.taxCollected);
      // 18% on 90k net = 16200.
      expect(total, closeTo(16200, 0.5));
    });
  });

  group('D4 pdf totals helpers', () {
    Invoice buildInvoice({required bool roundOff, double price = 100}) {
      return Invoice(
        id: 'inv-pdf',
        customer: Customer(
            id: 'c1', name: 'C', email: '', phone: '', address: '', gstin: ''),
        items: [
          InvoiceItem(
            product: Product(
                id: 'p1',
                name: 'Widget',
                description: '',
                price: price,
                stock: 10,
                hsncode: '',
                tax_rate: 0),
            quantity: 1,
          ),
        ],
        date: DateTime(2026, 1, 10),
        type: 'Invoice',
        taxRate: 0.1806,
        roundOffEnabled: roundOff,
      );
    }

    test('non-rounded docs never round, even when setting is on', () {
      final inv = buildInvoice(roundOff: false);
      final t = pdfInvoiceTotals(inv, previousBalanceDue: 0);
      expect(t.isRounded, isFalse);
      expect(t.roundOff, 0.0);
      expect(t.payableDue, closeTo(t.exactDue, 1e-9));
      expect(shouldShowPdfRounding(inv, true), isFalse);
      expect(shouldShowPdfRounding(inv, false), isFalse);
    });

    test('rounded docs round to payable and show rounding', () {
      final inv = buildInvoice(roundOff: true);
      // total 118.06 → payable 118.00, roundOff -0.06.
      expect(inv.total, closeTo(118.06, 0.01));
      expect(inv.payableTotal, closeTo(118.0, 0.01));
      final t = pdfInvoiceTotals(inv, previousBalanceDue: 10);
      expect(t.isRounded, isTrue);
      expect(t.exactDue, closeTo(128.06, 0.01));
      expect(t.payableDue, closeTo(128.0, 0.01));
      expect(t.roundOff, closeTo(-0.06, 0.01));
      expect(shouldShowPdfRounding(inv, true), isTrue);
      // Rounded docs always show even when the global toggle is off.
      expect(inv.roundOffEnabled, isTrue);
    });

    test('bottom-line always equals amount owed', () {
      final exact = buildInvoice(roundOff: false, price: 100);
      final rounded = buildInvoice(roundOff: true, price: 100);
      for (final prev in [0.0, 50.0]) {
        final te = pdfInvoiceTotals(exact, previousBalanceDue: prev);
        final tr = pdfInvoiceTotals(rounded, previousBalanceDue: prev);
        expect(te.payableDue, closeTo(exact.payableTotal + prev, 1e-9));
        expect(tr.payableDue, closeTo(rounded.payableTotal + prev, 1e-9));
      }
    });
  });

  group('D5 dashboard currency filter', () {
    setUp(openTestDb);

    test('INR dashboard excludes USD invoice', () async {
      await insertInvoiceRow('inv-inr', 'Invoice', DateTime(2026, 1, 10), 1000,
          currencyCode: 'INR',
          currencySymbol: '₹',
          taxRate: 0,
          taxMode: 'none');
      await db.insert('invoice_payments', {
        'id': 'pay-inr',
        'invoice_id': 'inv-inr',
        'invoice_number': 'inv-inr',
        'receipt_number': 'r-inr',
        'amount_paid': 1000,
        'balance_after': 0,
        'date_paid': DateTime(2026, 1, 15).toIso8601String(),
        'cheque_status': 'none',
      });
      await insertInvoiceRow('inv-usd', 'Invoice', DateTime(2026, 1, 11), 1000,
          currencyCode: 'USD',
          currencySymbol: '\$',
          taxRate: 0,
          taxMode: 'none');

      final inr =
          await InvoiceService.getDashboardFinancials(currencyCode: 'INR');
      expect(inr.revenue, closeTo(1000, 0.01));
      expect(inr.outstanding, closeTo(0, 0.01));

      final usd =
          await InvoiceService.getDashboardFinancials(currencyCode: 'USD');
      expect(usd.revenue, closeTo(0, 0.01));
      expect(usd.outstanding, closeTo(1000, 0.01));
    });
  });

  group('D6 expense currency + balance-sheet point-in-time', () {
    setUp(openTestDb);

    test('null-account expenses count as INR in both ledger and P&L', () async {
      await db.insert('expenses', {
        'id': 'exp-null',
        'description': 'Cash expense',
        'amount': 250,
        'date': DateTime(2026, 1, 15).toIso8601String(),
        'category_id': 'cat-other',
        'account_id': null,
      });
      final pnl = await ReportService.getPnl(from, to, currencyCode: 'INR');
      expect(pnl.expenses, closeTo(250, 0.01));

      final journal =
          await LedgerService.getJournal(to: to, currencyCode: 'INR');
      final hasExpense =
          journal.any((e) => e.description.contains('Cash expense'));
      expect(hasExpense, isTrue);
    });

    test('balance sheet is point-in-time as of to', () async {
      await insertInvoiceRow('inv-bs', 'Invoice', DateTime(2026, 1, 10), 1000);
      final bs = await LedgerService.getBalanceSheet(to: to);
      expect(bs.receivable, closeTo(1180, 0.01));
    });
  });
}
