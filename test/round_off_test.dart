import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/ledger_service.dart';
import 'package:apexbooks/database/report_service.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';

/// Round-off mechanism: calculator math, invoice payable/outstanding,
/// explicit Round Off ledger postings (Sales/Tax stay exact), P&L parity,
/// and the v51 → v52 migration.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('calculator', () {
    test('backs out the paise delta in both directions', () {
      expect(InvoiceTotalsCalculator.roundOffAmount(1234.56, enabled: true),
          closeTo(0.44, 1e-9));
      expect(InvoiceTotalsCalculator.roundOffAmount(1234.44, enabled: true),
          closeTo(-0.44, 1e-9));
      expect(InvoiceTotalsCalculator.payableTotal(1234.56, enabled: true),
          closeTo(1235.0, 1e-9));
      expect(InvoiceTotalsCalculator.roundOffAmount(100.0, enabled: true), 0.0);
      expect(
          InvoiceTotalsCalculator.roundOffAmount(1234.56, enabled: false), 0.0);
      expect(InvoiceTotalsCalculator.payableTotal(1234.56, enabled: false),
          closeTo(1234.56, 1e-9));
    });
  });

  group('invoice model', () {
    Invoice build({required bool roundOff}) {
      return Invoice(
        id: 'inv-ro',
        customer: Customer(
            id: 'c1', name: 'C', email: '', phone: '', address: '', gstin: ''),
        items: [
          InvoiceItem(
            product: Product(
                id: 'p1',
                name: 'Widget',
                description: '',
                price: 100,
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

    test('payable and outstanding round only when enabled', () {
      final exact = build(roundOff: false);
      expect(exact.total, closeTo(118.06, 1e-9));
      expect(exact.roundOffAmount, 0.0);
      expect(exact.payableTotal, closeTo(118.06, 1e-9));
      expect(exact.outstandingBalance, closeTo(118.06, 1e-9));

      final rounded = build(roundOff: true);
      expect(rounded.total, closeTo(118.06, 1e-9));
      expect(rounded.roundOffAmount, closeTo(-0.06, 1e-9));
      expect(rounded.payableTotal, closeTo(118.0, 1e-9));
      expect(rounded.outstandingBalance, closeTo(118.0, 1e-9));
      // Tax itself is never rounded away.
      expect(rounded.tax, closeTo(18.06, 1e-9));
    });
  });

  group('ledger and P&L', () {
    late Database db;
    final from = DateTime(2026, 1, 1);
    final to = DateTime(2026, 1, 31);

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      DatabaseHelper().useDatabaseForTest(db);
      // Global 18.06% on 100 → total 118.06, payable 118.00.
      await db.insert('invoices', {
        'id': 'inv-ro',
        'invoice_number': 'inv-ro',
        'customer_id': 'c1',
        'customer_name': 'Rounding Customer',
        'date': DateTime(2026, 1, 10).toIso8601String(),
        'tax_rate': 0.1806,
        'type': 'Invoice',
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'tax_mode': 'global',
        'round_off': 1,
      });
      await db.insert('invoice_items', {
        'id': 'item-ro',
        'invoice_id': 'inv-ro',
        'product_name': 'Widget',
        'product_price': 100.0,
        'unit_price': 100.0,
        'quantity': 1.0,
        'discount': 0.0,
        'discount_per_unit': 0,
        'extra_cost': 0.0,
        'product_tax_rate': 0,
        'product_price_includes_tax': 0,
      });
    });

    tearDown(() async {
      DatabaseHelper().clearDatabaseForTest();
      await db.close();
    });

    test('sale posts AR at payable with an explicit Round Off line', () async {
      final journal = await LedgerService.getJournal(from: from, to: to);
      final sale =
          journal.firstWhere((e) => e.description.startsWith('Sale —'));
      double Dr(String account) => sale.lines
          .where((l) => l.account == account)
          .fold(0.0, (s, l) => s + l.debit);
      double Cr(String account) => sale.lines
          .where((l) => l.account == account)
          .fold(0.0, (s, l) => s + l.credit);
      // AR settles at the rounded payable; Sales and GST stay exact.
      expect(Dr(LedgerService.accReceivable), closeTo(118.0, 1e-9));
      expect(Cr(LedgerService.accSales), closeTo(100.0, 1e-9));
      expect(Cr(LedgerService.accGstOutput), closeTo(18.06, 1e-9));
      expect(Dr(LedgerService.accRoundOff), closeTo(0.06, 1e-9));

      final tb = await LedgerService.getTrialBalance(from: from, to: to);
      expect(tb.balanced, isTrue);

      final bs = await LedgerService.getBalanceSheet(to: to);
      expect(bs.receivable, closeTo(118.0, 1e-9));
      expect(bs.netProfit, closeTo(99.94, 1e-9));

      final pnl = await ReportService.getPnl(from, to);
      expect(pnl.revenue, closeTo(100.0, 1e-9));
      expect(pnl.roundOff, closeTo(-0.06, 1e-9));
      expect(pnl.profit, closeTo(bs.netProfit, 1e-9));
    });
  });

  group('migration v51 to v52', () {
    test('adds round_off defaulting to 0 without data loss', () async {
      final db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      // Simulate a v51 database, then run the real upgrade chain.
      await db.execute('ALTER TABLE invoices DROP COLUMN round_off');
      await db.insert('invoices', {
        'id': 'legacy-1',
        'customer_name': 'Legacy',
        'date': DateTime(2026, 1, 5).toIso8601String(),
        'type': 'Invoice',
      });
      await DatabaseHelper()
          .upgradeDbForTest(db, 51, DatabaseHelper().dbVersion);

      final cols = await db.rawQuery('PRAGMA table_info(invoices)');
      expect(cols.map((c) => c['name']), contains('round_off'));
      final row =
          (await db.query('invoices', where: 'id = ?', whereArgs: ['legacy-1']))
              .single;
      expect(row['round_off'], 0);
      expect(row['customer_name'], 'Legacy');
      await db.close();
    });
  });
}
