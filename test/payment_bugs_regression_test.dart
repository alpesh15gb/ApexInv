import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';

/// Regression tests for VERIFIED payment bugs B1–B4 (minimal fixes, no UI).
void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

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

  Future<Product> addProduct(String id, double stock) async {
    final p = Product(
      id: id,
      name: 'Widget $id',
      description: '',
      price: 100,
      stock: stock,
      hsncode: '',
      tax_rate: 0,
    );
    await ProductService.insertProduct(p);
    return (await ProductService.getProductById(id))!;
  }

  Invoice salesInvoice(String id, Product product, double qty) {
    return Invoice(
      id: id,
      customer: Customer(
          id: 'c1',
          name: 'Buyer',
          email: '',
          phone: '',
          address: '',
          gstin: ''),
      items: [InvoiceItem(product: product, quantity: qty)],
      date: DateTime(2026, 1, 10),
      type: 'Invoice',
    );
  }

  PurchaseBill bill(String id, {double total = 1000}) {
    return PurchaseBill(
      id: id,
      billNumber: 'B-$id',
      supplierName: 'Acme',
      date: DateTime(2026, 1, 5),
      totalAmount: total,
      items: const [],
    );
  }

  group('B1 sales deletePayment is atomic + bounced safe', () {
    test('deleting a bounced-cheque receipt does not throw', () async {
      final product = await addProduct('b1p', 100);
      await InvoiceService.insertInvoice(salesInvoice('b1inv', product, 10));
      var stored = (await InvoiceService.getInvoiceById('b1inv'))!;

      await AccountingService.saveAccount(FinancialAccount(
        id: 'bank-b1',
        name: 'Bank B1',
        type: 'bank',
        openingDate: DateTime(2026, 1, 1),
      ));

      final payment = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 100,
        datePaid: DateTime(2026, 1, 11),
        paymentMethod: 'Check',
        chequeNumber: 'CHF-B1',
        chequeDate: DateTime(2026, 1, 10),
      );
      expect(payment.chequeId, isNotNull);

      await AccountingService.transitionCheque(
        chequeId: payment.chequeId!,
        status: 'cleared',
        bankAccountId: 'bank-b1',
      );
      await AccountingService.transitionCheque(
        chequeId: payment.chequeId!,
        status: 'bounced',
        notes: 'bounced for test',
      );
      final prow = (await db.query('invoice_payments',
              where: 'id = ?', whereArgs: [payment.id], limit: 1))
          .first;
      expect(prow['cheque_status'], 'bounced');

      // Used to throw StateError (bounced is terminal in the state machine).
      await PaymentService.deletePayment(payment.id);

      expect(
          await db.query('invoice_payments',
              where: 'id = ?', whereArgs: [payment.id]),
          isEmpty);
      // Cleared (+100) + bounce (−100) net to zero; delete adds no extra leg.
      expect(await AccountingService.getBalance('bank-b1'), 0);
    });

    test('deleting a cancelled/pending cheque parks it without crash',
        () async {
      final product = await addProduct('b1p2', 100);
      await InvoiceService.insertInvoice(salesInvoice('b1inv2', product, 10));

      var stored = (await InvoiceService.getInvoiceById('b1inv2'))!;
      final payment = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 50,
        datePaid: DateTime(2026, 1, 12),
        paymentMethod: 'Check',
        chequeNumber: 'CHF-B1C',
        chequeDate: DateTime(2026, 1, 11),
      );
      await PaymentService.deletePayment(payment.id);
      expect(
          await db.query('invoice_payments',
              where: 'id = ?', whereArgs: [payment.id]),
          isEmpty);
      final crow = (await db.query('cheques',
              where: 'id = ?', whereArgs: [payment.chequeId!], limit: 1))
          .first;
      expect(crow['status'], 'cancelled');
    });

    test('cash delete reverses the register in the same txn', () async {
      final product = await addProduct('b1p3', 100);
      await InvoiceService.insertInvoice(salesInvoice('b1inv3', product, 10));
      var stored = (await InvoiceService.getInvoiceById('b1inv3'))!;
      final payment = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 120,
        datePaid: DateTime(2026, 1, 13),
        paymentMethod: 'Cash',
      );
      expect(await AccountingService.getBalance('cash-default'), 120);
      await PaymentService.deletePayment(payment.id);
      expect(
          await db.query('invoice_payments',
              where: 'id = ?', whereArgs: [payment.id]),
          isEmpty);
      expect(await AccountingService.getBalance('cash-default'), 0);
    });
  });

  group('B2 purchase recordPayment fresh read + overpay throws', () {
    test('overpay throws instead of clamping silently', () async {
      await PurchaseBillService.insertBill(bill('b2', total: 1000));
      await PurchaseBillService.recordPayment('b2', 400,
          datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash');
      expect((await PurchaseBillService.getBill('b2'))!.amountPaid, 400);

      // Outstanding is 600; 700 must throw like sales/batch paths.
      await expectLater(
          () => PurchaseBillService.recordPayment('b2', 700,
              datePaid: DateTime(2026, 2, 2), paymentMethod: 'Cash'),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('within the outstanding balance'))));
      // No partial write leaked.
      expect((await PurchaseBillService.getBill('b2'))!.amountPaid, 400);
    });

    test('epsilon overpay also throws; exact outstanding succeeds', () async {
      await PurchaseBillService.insertBill(bill('b2e', total: 1000));
      await PurchaseBillService.recordPayment('b2e', 400,
          datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash');
      await expectLater(
          () => PurchaseBillService.recordPayment('b2e', 600.01,
              datePaid: DateTime(2026, 2, 2), paymentMethod: 'Cash'),
          throwsStateError);
      final ok = await PurchaseBillService.recordPayment('b2e', 600,
          datePaid: DateTime(2026, 2, 2), paymentMethod: 'Cash');
      expect(ok.previouslyPaid, 400);
      expect(ok.balanceAfter, 0);
      expect((await PurchaseBillService.getBill('b2e'))!.amountPaid, 1000);
    });
  });

  group('B3 receipt-number UNIQUE + retry', () {
    test('unique index exists on fresh DB', () async {
      final idx = await db.rawQuery(
          "SELECT name, sql FROM sqlite_master WHERE type='index' AND name='idx_payments_receipt_unique'");
      expect(idx, hasLength(1));
      expect((idx.first['sql'] as String).toUpperCase(), contains('UNIQUE'));
    });

    test('two rapid payments get distinct receipt numbers', () async {
      final product = await addProduct('b3p', 100);
      await InvoiceService.insertInvoice(salesInvoice('b3inv', product, 20));
      var stored = (await InvoiceService.getInvoiceById('b3inv'))!;

      // Simulate two rapid taps: run concurrently, both must commit uniquely.
      final results = await Future.wait([
        PaymentService.addPayment(
            invoice: stored,
            amountPaid: 100,
            datePaid: DateTime(2026, 3, 1),
            paymentMethod: 'Cash'),
        PaymentService.addPayment(
            invoice: stored,
            amountPaid: 150,
            datePaid: DateTime(2026, 3, 1),
            paymentMethod: 'Cash'),
      ]);
      expect(results[0].receiptNumber, isNot(results[1].receiptNumber));
      final rows = await db.query('invoice_payments',
          columns: ['receipt_number'],
          where: 'invoice_id = ?',
          whereArgs: ['b3inv']);
      expect(rows.map((r) => r['receipt_number']).toSet(), hasLength(2));
    });

    test('duplicate receipt insert is rejected by UNIQUE', () async {
      final product = await addProduct('b3p2', 100);
      await InvoiceService.insertInvoice(salesInvoice('b3inv2', product, 20));
      var stored = (await InvoiceService.getInvoiceById('b3inv2'))!;
      final first = await PaymentService.addPayment(
          invoice: stored,
          amountPaid: 100,
          datePaid: DateTime(2026, 3, 2),
          paymentMethod: 'Cash');
      await expectLater(
          () => db.insert('invoice_payments', {
                'id': 'dup-id',
                'invoice_id': stored.id,
                'invoice_number': stored.invoiceNumber ?? stored.id,
                'receipt_number': first.receiptNumber,
                'amount_paid': 10,
                'tax_amount_paid': 0,
                'previously_paid': 100,
                'balance_after': 0,
                'date_paid': '2026-03-02',
                'payment_method': 'Cash',
                'cheque_status': 'none',
              }),
          throwsA(isA<DatabaseException>().having((e) => e.toString(),
              'message', contains('UNIQUE constraint failed'))));
    });
  });

  group('B4 inclusive day bounds for mixed date formats', () {
    test('same-day ISO + date-only rows are both returned', () async {
      final product = await addProduct('b4p', 100);
      await InvoiceService.insertInvoice(salesInvoice('b4inv', product, 20));
      var stored = (await InvoiceService.getInvoiceById('b4inv'))!;

      final viaService = await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 100,
        datePaid: DateTime(2026, 5, 3, 9, 30),
        paymentMethod: 'Cash',
      );
      // Simulate a Vyapar-imported ISO row on the same day with time.
      await db.insert('invoice_payments', {
        'id': 'b4-iso',
        'invoice_id': stored.id,
        'invoice_number': stored.invoiceNumber ?? stored.id,
        'receipt_number': '${stored.id}-R99',
        'amount_paid': 200,
        'tax_amount_paid': 10,
        'previously_paid': 100,
        'balance_after': 0,
        'date_paid': DateTime(2026, 5, 3, 14, 20).toIso8601String(),
        'payment_method': 'Cash',
        'cheque_status': 'none',
      });

      final day = DateTime(2026, 5, 3);
      final found = await PaymentService.getAllPaymentsBetween(day, day);
      final ids = found.map((p) => p.id).toSet();
      expect(ids, contains(viaService.id));
      expect(ids, contains('b4-iso'));

      final tax = await PaymentService.getTaxPaidBetween(day, day);
      // viaService tax is proportional (tax 0 here) + 10 from the ISO row.
      expect(tax, greaterThanOrEqualTo(10));
    });

    test('adjacent days are still excluded', () async {
      final product = await addProduct('b4p2', 100);
      await InvoiceService.insertInvoice(salesInvoice('b4inv2', product, 20));
      var stored = (await InvoiceService.getInvoiceById('b4inv2'))!;
      await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 100,
        datePaid: DateTime(2026, 5, 4, 10),
        paymentMethod: 'Cash',
      );
      final found = await PaymentService.getAllPaymentsBetween(
          DateTime(2026, 5, 3), DateTime(2026, 5, 3));
      expect(found.where((p) => p.invoiceId == 'b4inv2'), isEmpty);
    });
  });
}
