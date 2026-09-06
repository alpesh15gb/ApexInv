import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/expense_service.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/pos_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/services/reminder_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('A1 purchase bill lines persist', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      DatabaseHelper().useDatabaseForTest(db);
    });

    tearDown(() async {
      DatabaseHelper().clearDatabaseForTest();
      await db.close();
    });

    test('insert + getBill round-trips header id == item purchaseBillId',
        () async {
      const billId = 'bill-a1';
      final bill = PurchaseBill(
        id: billId,
        supplierName: 'Acme Supplies',
        date: DateTime(2026, 1, 10),
        totalAmount: 118.0,
        totalTax: 18.0,
        items: [
          PurchaseBillItem.compute(
            id: 'item-a1-1',
            purchaseBillId: billId,
            productName: 'Widget',
            quantity: 1,
            rate: 100,
            taxRate: 18,
            discount: 0,
            interState: false,
          ),
        ],
      );
      await PurchaseBillService.insertBill(bill);
      final reloaded = await PurchaseBillService.getBill(billId);
      expect(reloaded, isNotNull);
      expect(reloaded!.items, hasLength(1));
      expect(reloaded.items.first.purchaseBillId, billId);
      expect(reloaded.id, billId);
    });
  });

  group('A2 POS round-off persisted', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      DatabaseHelper().useDatabaseForTest(db);
      await db.insert('products', {
        'id': 'p-pos',
        'name': 'POS Widget',
        'description': '',
        'price': 100.6,
        'stock': 10.0,
        'hsncode': '',
        'tax_rate': 0,
        'unlimited_stock': 0,
        'price_includes_tax': 0,
      });
    });

    tearDown(() async {
      DatabaseHelper().clearDatabaseForTest();
      await db.close();
    });

    test('reloaded POS invoice payableTotal equals charged total', () async {
      final customer = Customer(
          id: 'c-pos',
          name: 'POS',
          email: '',
          phone: '',
          address: '',
          gstin: '');
      final product = Product(
          id: 'p-pos',
          name: 'POS Widget',
          description: '',
          price: 100.6,
          stock: 10,
          hsncode: '',
          tax_rate: 0);
      // Exact total 100.6 rounds to payable 101.0 when enabled.
      final items = [
        InvoiceItem(product: product, quantity: 1),
      ];
      final invoice = await PosService.finalize(
        customer: customer,
        items: items,
        tenders: const [PosTender(method: 'Cash', amount: 101.0)],
        currencyCode: 'INR',
        currencySymbol: '₹',
        roundOffEnabled: true,
      );
      final charged = invoice.payableTotal;
      expect(charged, closeTo(101.0, 1e-9));
      final reloaded = await InvoiceService.getInvoiceById(invoice.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.roundOffEnabled, isTrue);
      expect(reloaded.payableTotal, closeTo(charged, 1e-9));
    });
  });

  group('A3 expense total keeps paise', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      DatabaseHelper().useDatabaseForTest(db);
      await db.insert('expenses', {
        'id': 'e1',
        'description': 'Stationery',
        'amount': 99.99,
        'date': DateTime(2026, 2, 1).toIso8601String(),
        'category_id': 'c1',
      });
      await db.insert('expenses', {
        'id': 'e2',
        'description': 'Fuel',
        'amount': 100.0,
        'date': DateTime(2026, 2, 2).toIso8601String(),
        'category_id': 'c1',
      });
    });

    tearDown(() async {
      DatabaseHelper().clearDatabaseForTest();
      await db.close();
    });

    test('99.99 + 100 totals 199.99', () async {
      expect(await ExpenseService.getTotalExpenses(), closeTo(199.99, 1e-9));
    });
  });

  group('A4 reminders use engine totals', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath,
          version: DatabaseHelper().dbVersion,
          singleInstance: false,
          onCreate: (database, version) =>
              DatabaseHelper().createDbForTest(database, version));
      DatabaseHelper().useDatabaseForTest(db);
      final pastDue =
          DateTime.now().subtract(const Duration(days: 10)).toIso8601String();
      await db.insert('invoices', {
        'id': 'inv-overdue',
        'invoice_number': '1001',
        'customer_id': 'c1',
        'customer_name': 'Late Customer',
        'customer_phone': '9999999999',
        'date':
            DateTime.now().subtract(const Duration(days: 20)).toIso8601String(),
        'due_date': pastDue,
        'tax_rate': 0,
        'type': 'Invoice',
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'tax_mode': 'per_item',
        'round_off': 0,
      });
      await db.insert('invoice_items', {
        'id': 'item-overdue',
        'invoice_id': 'inv-overdue',
        'product_name': 'Service',
        'product_price': 1000.0,
        'unit_price': 1000.0,
        'quantity': 1.0,
        'discount': 0.0,
        'discount_per_unit': 0,
        'extra_cost': 0.0,
        'product_tax_rate': 18,
        'product_price_includes_tax': 0,
      });
      await db.insert('invoice_payments', {
        'id': 'pay-1',
        'invoice_id': 'inv-overdue',
        'invoice_number': '1001',
        'receipt_number': 'inv-overdue-R001',
        'amount_paid': 180.0,
        'tax_amount_paid': 0,
        'previously_paid': 0,
        'balance_after': 1000.0,
        'date_paid': DateTime.now().toIso8601String(),
        'cheque_status': 'none',
      });
    });

    tearDown(() async {
      DatabaseHelper().clearDatabaseForTest();
      await db.close();
    });

    test('overdue invoice outstanding = engine total minus live payments',
        () async {
      final overdue = await ReminderService.getOverdue();
      final found = overdue.where((o) => o.id == 'inv-overdue').toList();
      expect(found, hasLength(1));
      // Line: 1000 + 18% = 1180; paid 180 → outstanding 1000.
      expect(found.first.total, closeTo(1180.0, 1e-6));
      expect(found.first.outstanding, closeTo(1000.0, 1e-6));
    });
  });
}
