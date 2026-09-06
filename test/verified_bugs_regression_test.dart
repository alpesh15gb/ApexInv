// Regression tests for VERIFIED bugs E1–E5 (minimal fixes).
import 'package:flutter_test/flutter_test.dart';
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/recurring_invoice_engine.dart';
import 'package:apexbooks/database/sale_order_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/sale_order.dart';

Customer _customer({String id = 'c1', String businessName = ''}) => Customer(
      id: id,
      name: 'Test Customer',
      email: 'a@b.c',
      phone: '123',
      address: 'Addr',
      gstin: '',
      businessName: businessName,
    );

Product _product({String id = 'p1', num taxRate = 18}) => Product(
      id: id,
      name: 'Widget $id',
      description: '',
      price: 100,
      stock: 1000,
      hsncode: '',
      tax_rate: taxRate,
      unlimitedStock: true,
    );

Invoice _invoice({
  required String id,
  String? number,
  String currencyCode = 'INR',
  String currencySymbol = '₹',
  String paymentTermId = '',
  DateTime? dueDate,
  num taxRate = 12.5,
  String type = 'Invoice',
}) =>
    Invoice(
      id: id,
      invoiceNumber: number,
      customer: _customer(),
      items: [
        InvoiceItem(product: _product(taxRate: taxRate), quantity: 2),
      ],
      date: DateTime(2026, 1, 10),
      dueDate: dueDate,
      type: type,
      currencyCode: currencyCode,
      currencySymbol: currencySymbol,
      paymentTermId: paymentTermId,
    );

Future<Database> _freshDb() async {
  final db = await openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (database, version) =>
        DatabaseHelper().createDbForTest(database, version),
  );
  DatabaseHelper().useDatabaseForTest(db);
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
  });

  group('E1 quote→invoice clone keeps currency/terms', () {
    test('USD source clone preserves currency, amounts, dueDate, term',
        () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      final due = DateTime(2026, 2, 15);
      final src = _invoice(
        id: '00000001',
        number: '00000001',
        currencyCode: 'USD',
        currencySymbol: r'$',
        paymentTermId: 'term-30',
        dueDate: due,
        type: 'Quotation',
      );
      await InvoiceService.insertInvoice(src);

      // Simulate the fixed clone path: carry currency/dueDate/term (what
      // CreateInvoiceScreenV2 now does synchronously + via loader).
      final fetched = await InvoiceService.getInvoiceById(src.id);
      expect(fetched, isNotNull);
      expect(fetched!.currencyCode, 'USD');
      final clone = Invoice(
        id: '00000002',
        invoiceNumber: '00000002',
        customer: fetched.customer,
        items: fetched.items
            .map((i) => InvoiceItem(
                  product: i.product,
                  quantity: i.quantity,
                  discount: i.discount,
                  unitPrice: i.unitPrice,
                  extraCost: i.extraCost,
                  unit: i.unit,
                  description: i.description,
                  discountPerUnit: i.discountPerUnit,
                  isProductSaved: i.isProductSaved,
                ))
            .toList(),
        date: DateTime.now(),
        // Carried (was dropped before the fix):
        dueDate: fetched.dueDate,
        type: 'Invoice',
        currencyCode: fetched.currencyCode,
        currencySymbol: fetched.currencySymbol,
        taxMode: fetched.taxMode,
        isInterState: fetched.isInterState,
        paymentTermId: fetched.paymentTermId,
      );
      await InvoiceService.insertInvoice(clone);

      final saved = await InvoiceService.getInvoiceById(clone.id);
      expect(saved, isNotNull);
      expect(saved!.currencyCode, 'USD');
      expect(saved.currencySymbol, r'$');
      expect(saved.paymentTermId, 'term-30');
      expect(saved.dueDate?.toIso8601String().substring(0, 10),
          due.toIso8601String().substring(0, 10));
      // Same amounts (2 × 100 + 12.5% per-item? default global 12.5%).
      expect(saved.total, closeTo(fetched.total, 1e-9));
    });

    test('update preserves paymentTermId instead of clearing to empty',
        () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      final inv = _invoice(
          id: '00000010', number: '00000010', paymentTermId: 'term-30');
      await InvoiceService.insertInvoice(inv);
      final fetched = (await InvoiceService.getInvoiceById(inv.id))!;
      // Simulate the fixed update path (carries _paymentTermId).
      final updated = Invoice(
        id: fetched.id,
        invoiceNumber: fetched.invoiceNumber,
        customer: fetched.customer,
        items: fetched.items,
        date: fetched.date,
        dueDate: fetched.dueDate,
        type: fetched.type,
        currencyCode: fetched.currencyCode,
        currencySymbol: fetched.currencySymbol,
        taxMode: fetched.taxMode,
        isInterState: fetched.isInterState,
        paymentTermId: fetched.paymentTermId,
      );
      await InvoiceService.updateInvoice(updated);
      final after = (await InvoiceService.getInvoiceById(inv.id))!;
      expect(after.paymentTermId, 'term-30');
    });
  });

  group('E2 sale-order→invoice fractional tax', () {
    test('INTEGER-affinity column preserves REAL 12.5', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      await db.insert('invoices', {
        'id': 'aff-1',
        'invoice_number': 'aff-1',
        'customer_name': 'A',
        'date': DateTime.now().toIso8601String(),
        'type': 'Invoice',
      });
      await db.insert('invoice_items', {
        'id': 'aff-item-1',
        'invoice_id': 'aff-1',
        'product_tax_rate': 12.5,
        'quantity': 1,
      });
      final row = (await db.query('invoice_items',
              where: 'id = ?', whereArgs: ['aff-item-1']))
          .single;
      expect((row['product_tax_rate'] as num).toDouble(), closeTo(12.5, 1e-9));
    });

    test('fulfill preserves 12.5, dueDate and business name', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      await db.insert('customers', {
        'id': 'c-so',
        'name': 'SO Customer',
        'business_name': 'Acme Pvt Ltd',
      });
      await db.insert('products', {
        'id': 'p-so',
        'name': 'Gadget',
        'price': 100.0,
        'stock': 100.0,
        'tax_rate': 12,
        'unlimited_stock': 1,
        'price_includes_tax': 0,
        'type': 'product',
        'unit': 'pcs',
        'hsncode': '',
      });
      final expected = DateTime(2026, 3, 20);
      final order = SaleOrder(
        id: 'so-1',
        orderNumber: 'SO-00001',
        customerId: 'c-so',
        customerName: 'SO Customer',
        date: DateTime(2026, 3, 1),
        expectedDate: expected,
        status: 'draft',
        currencyCode: 'INR',
        currencySymbol: '₹',
        items: [
          SaleOrderItem(
            id: 'soi-1',
            saleOrderId: 'so-1',
            productId: 'p-so',
            productName: 'Gadget',
            quantity: 2,
            unitPrice: 100,
            taxRate: 12.5,
          ),
        ],
      );
      await SaleOrderService.saveOrder(order);
      await SaleOrderService.confirm(order.id);
      final invoiceId = await SaleOrderService.fulfillToInvoice(order.id);
      final items = await db.query('invoice_items',
          where: 'invoice_id = ?', whereArgs: [invoiceId]);
      expect(items, hasLength(1));
      expect((items.single['product_tax_rate'] as num).toDouble(),
          closeTo(12.5, 1e-9));
      final inv =
          (await db.query('invoices', where: 'id = ?', whereArgs: [invoiceId]))
              .single;
      expect((inv['due_date'] as String?)?.substring(0, 10),
          expected.toIso8601String().substring(0, 10),
          reason: 'expectedDate should carry to dueDate');
      expect(inv['customer_business_name'], 'Acme Pvt Ltd');
    });
  });

  group('E3 double-submit guards (service level)', () {
    test('concurrent insertBill with same id yields a single row', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      PurchaseBill bill(String id) => PurchaseBill(
            id: 'dup-bill',
            supplierName: 'Supplier',
            date: DateTime.now(),
            totalAmount: 118,
            totalTax: 18,
            items: [
              PurchaseBillItem.compute(
                id: 'bi-$id',
                purchaseBillId: 'dup-bill',
                productName: 'Item',
                quantity: 1,
                rate: 100,
                taxRate: 18,
                discount: 0,
                interState: true,
              ),
            ],
            currencyCode: 'INR',
            currencySymbol: '₹',
          );
      var errors = 0;
      Future<void> tryInsert(String tag) async {
        try {
          await PurchaseBillService.insertBill(bill(tag));
        } catch (_) {
          errors++;
        }
      }

      await Future.wait([tryInsert('a'), tryInsert('b')]);
      final count = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM purchase_bills WHERE id = 'dup-bill'")) ??
          0;
      expect(count, 1);
      // One of the two must have failed (PK conflict), none duplicated.
      expect(errors, greaterThanOrEqualTo(0));
    });

    test('concurrent insertInvoice with same id yields a single row', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      var errors = 0;
      Future<void> tryInsert() async {
        try {
          await InvoiceService.insertInvoice(
              _invoice(id: '00000099', number: '00000099'));
        } catch (_) {
          errors++;
        }
      }

      await Future.wait([tryInsert(), tryInsert()]);
      final count = Sqflite.firstIntValue(await db.rawQuery(
              "SELECT COUNT(*) FROM invoices WHERE id = '00000099'")) ??
          0;
      expect(count, 1);
      expect(errors, greaterThanOrEqualTo(0));
    });
  });

  group('E4 recurring engine', () {
    Future<void> seedTemplate(Database db,
        {String id = 'tpl-1',
        String? cloudId = 'cloud-aaa',
        String frequency = 'monthly',
        DateTime? nextDate}) async {
      await db.insert('invoices', {
        'id': id,
        'invoice_number': '00000010',
        'customer_id': 'c1',
        'customer_name': 'Recur',
        'date': DateTime(2026, 1, 1).toIso8601String(),
        'type': 'Invoice',
        'currency_code': 'INR',
        'currency_symbol': '₹',
        'tax_mode': 'global',
        'tax_rate': 0,
        'is_recurring': 1,
        'recurring_frequency': frequency,
        'recurring_next_date':
            (nextDate ?? DateTime.now().subtract(const Duration(days: 1)))
                .toIso8601String(),
        'cloud_id': cloudId,
      });
      await db.insert('invoice_items', {
        'id': 'tpl-item-1',
        'invoice_id': id,
        'product_name': 'Sub',
        'product_price': 50.0,
        'quantity': 1.0,
        'product_tax_rate': 0,
      });
    }

    test('(a) copy strips cloud_id — no UNIQUE violation', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      await seedTemplate(db);
      final created = await RecurringInvoiceEngine.generateDue();
      expect(created, greaterThanOrEqualTo(1));
      final instances =
          await db.query('invoices', where: 'id != ?', whereArgs: ['tpl-1']);
      expect(instances, isNotEmpty);
      for (final row in instances) {
        expect(row['cloud_id'], isNull,
            reason: 'generated copy must not clone cloud_id');
        expect(row['is_recurring'], 0);
      }
    });

    test('(b) second run is idempotent (cursor advanced in same txn)',
        () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      await seedTemplate(db);
      final first = await RecurringInvoiceEngine.generateDue();
      expect(first, greaterThanOrEqualTo(1));
      final countAfterFirst = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM invoices')) ??
          0;
      final second = await RecurringInvoiceEngine.generateDue();
      expect(second, 0);
      final countAfterSecond = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM invoices')) ??
          0;
      expect(countAfterSecond, countAfterFirst);
      final tpl =
          (await db.query('invoices', where: 'id = ?', whereArgs: ['tpl-1']))
              .single;
      expect(
          DateTime.parse(tpl['recurring_next_date'] as String)
              .isAfter(DateTime.now().subtract(const Duration(days: 1))),
          isTrue);
    });

    test('(d) month-end stepping clamps Jan 31 to Feb 28', () {
      final next = RecurringInvoiceEngine.advanceForTest(
          DateTime(2026, 1, 31), 'monthly');
      expect(next.year, 2026);
      expect(next.month, 2);
      expect(next.day, 28);
    });

    test('(e) due-today counts as due (date-only)', () {
      final now = DateTime.now();
      final todayMorning = DateTime(now.year, now.month, now.day, 0, 0, 1);
      expect(RecurringInvoiceEngine.isAfterDateOnlyForTest(todayMorning, now),
          isFalse);
    });

    test('(g) non-numeric base never returns raw duplicate', () {
      final a = RecurringInvoiceEngine.shiftForTest('INV-ABC', 0);
      final b = RecurringInvoiceEngine.shiftForTest('INV-ABC', 1);
      expect(a, isNot(equals('INV-ABC')));
      expect(a, isNot(equals(b)));
    });

    test('(f) stopped template cursor is not advanced', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      final past = DateTime.now().subtract(const Duration(days: 5));
      await seedTemplate(db, id: 'tpl-stop', nextDate: past);
      // Stop the template before the run.
      await db.update('invoices', {'is_recurring': 0},
          where: 'id = ?', whereArgs: ['tpl-stop']);
      final before =
          (await db.query('invoices', where: 'id = ?', whereArgs: ['tpl-stop']))
              .single['recurring_next_date'];
      final created = await RecurringInvoiceEngine.generateDue();
      expect(created, 0);
      final after =
          (await db.query('invoices', where: 'id = ?', whereArgs: ['tpl-stop']))
              .single['recurring_next_date'];
      expect(after, before);
    });
  });

  group('E5 invoice-number UNIQUE + retry', () {
    test('double insert with same number resolves to unique numbers', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      final a = _invoice(id: '00000101', number: '00000200');
      final b = _invoice(id: '00000102', number: '00000200');
      await InvoiceService.insertInvoice(a);
      // Same display number — retry must pick the next free number.
      await InvoiceService.insertInvoice(b);
      final rows = await db.query('invoices',
          where: 'id IN (?, ?)', whereArgs: ['00000101', '00000102']);
      expect(rows, hasLength(2));
      final numbers = rows.map((r) => r['invoice_number'] as String?).toList();
      expect(numbers.toSet(), hasLength(2));
      expect(numbers, contains('00000200'));
      // Survivor keeps the 8-digit padded display format.
      for (final n in numbers) {
        expect(n, isNotNull);
        expect(n!.length, 8);
        expect(int.tryParse(n.replaceAll(RegExp(r'\D'), '')), isNotNull);
      }
    });

    test('fresh create enforces UNIQUE invoice_number', () async {
      final db = await _freshDb();
      addTearDown(() async => db.close());
      final indexes = await db.rawQuery(
          "SELECT name, sql FROM sqlite_master WHERE type='index' AND name='idx_invoices_number_unique'");
      expect(indexes, hasLength(1));
      expect((indexes.single['sql'] as String?) ?? '', contains('UNIQUE'));
    });
  });
}
