import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';

/// P2 delete/stock symmetries: bill deletes must clear payments + cash,
/// batch-group single deletes must rebalance, purchase stock-in/out must net
/// to zero, and invoice permanent deletes must leave no orphans.
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

  Future<void> addProduct(String id, double stock,
      {bool unlimited = false}) async {
    await ProductService.insertProduct(Product(
      id: id,
      name: 'Widget $id',
      description: '',
      price: 100,
      stock: stock,
      hsncode: '',
      tax_rate: 0,
      unlimitedStock: unlimited,
    ));
  }

  Future<num> stockOf(String id) async =>
      (await ProductService.getProductById(id))!.stock;

  PurchaseBill bill(String id,
      {double total = 1000, List<PurchaseBillItem>? items}) {
    return PurchaseBill(
      id: id,
      billNumber: 'B-$id',
      supplierName: 'Acme',
      date: DateTime(2026, 1, 5),
      totalAmount: total,
      items: items ?? const [],
    );
  }

  PurchaseBillItem billItem(String id, String billId, double qty,
      {String? productId}) {
    return PurchaseBillItem(
      id: id,
      purchaseBillId: billId,
      productId: productId,
      productName: 'Widget',
      quantity: qty,
      rate: 100,
    );
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

  test('bill insert adds stock, update applies delta, delete reverses',
      () async {
    await addProduct('p1', 10);
    await addProduct('p-unl', 50, unlimited: true);

    await PurchaseBillService.insertBill(bill('bill-stock', items: [
      billItem('i1', 'bill-stock', 5, productId: 'p1'),
      // Ad-hoc (no product link) and unlimited lines must not touch stock.
      billItem('i2', 'bill-stock', 100),
      billItem('i3', 'bill-stock', 100, productId: 'p-unl'),
    ]));
    expect(await stockOf('p1'), 15);
    expect(await stockOf('p-unl'), 50);

    await PurchaseBillService.updateBill(bill('bill-stock', items: [
      billItem('i1', 'bill-stock', 7, productId: 'p1'),
    ]));
    expect(await stockOf('p1'), 17);

    await PurchaseBillService.softDeleteBill('bill-stock');
    expect(await stockOf('p1'), 10);
    expect(await PurchaseBillService.getBill('bill-stock'), isNull);
    expect(
        await db.query('purchase_bill_items',
            where: 'purchase_bill_id = ?', whereArgs: ['bill-stock']),
        isEmpty);
  });

  test('bill delete removes payments and reverses cash', () async {
    await PurchaseBillService.insertBill(bill('bill-cash', total: 1000));
    await PurchaseBillService.recordPayment('bill-cash', 400,
        datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash');
    expect(await AccountingService.getBalance('cash-default'), -400);

    await PurchaseBillService.softDeleteBill('bill-cash');

    expect(await PurchaseBillService.getBill('bill-cash'), isNull);
    expect(await PurchaseBillService.getPayments('bill-cash'), isEmpty);
    expect(
        await db.query('purchase_bill_payments',
            where: 'purchase_bill_id = ?', whereArgs: ['bill-cash']),
        isEmpty);
    // Movement + reversal net to zero: no orphan financial_transactions.
    expect(await AccountingService.getBalance('cash-default'), 0);
  });

  test('group payment single-delete rebalances the shared movement', () async {
    await PurchaseBillService.insertBill(bill('bill-g1', total: 500));
    await PurchaseBillService.insertBill(bill('bill-g2', total: 500));
    final b1 = (await PurchaseBillService.getBill('bill-g1'))!;
    final b2 = (await PurchaseBillService.getBill('bill-g2'))!;

    final saved = await PurchaseBillService.recordPaymentBatch(
      allocations: [(bill: b1, amount: 300), (bill: b2, amount: 200)],
      datePaid: DateTime(2026, 3, 1),
      paymentMethod: 'Cash',
    );
    expect(saved, hasLength(2));
    expect(await AccountingService.getBalance('cash-default'), -500);

    await PurchaseBillService.deletePayment(saved.first);

    // Cash nets to exactly the surviving sibling's total.
    expect(await AccountingService.getBalance('cash-default'), -200);
    final remaining = await db.query('purchase_bill_payments');
    expect(remaining.map((r) => r['id']), [saved[1].id]);
    expect((await PurchaseBillService.getBill('bill-g1'))!.amountPaid, 0);
    expect((await PurchaseBillService.getBill('bill-g2'))!.amountPaid, 200);
  });

  test('invoice permanent delete clears payments and nets cash to zero',
      () async {
    await addProduct('sp1', 10);
    final product = (await ProductService.getProductById('sp1'))!;
    await InvoiceService.insertInvoice(salesInvoice('00000001', product, 3));
    expect(await stockOf('sp1'), 7);

    final stored = (await InvoiceService.getInvoiceById('00000001'))!;
    await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 100,
        datePaid: DateTime(2026, 1, 11),
        paymentMethod: 'Cash');
    expect(await AccountingService.getBalance('cash-default'), 100);

    await InvoiceService.permanentDeleteInvoice('00000001');

    expect(await InvoiceService.getInvoiceById('00000001'), isNull);
    expect(
        await db.query('invoice_payments',
            where: 'invoice_id = ?', whereArgs: ['00000001']),
        isEmpty);
    expect(
        await db.query('invoice_items',
            where: 'invoice_id = ?', whereArgs: ['00000001']),
        isEmpty);
    expect(await AccountingService.getBalance('cash-default'), 0);
    expect(await stockOf('sp1'), 10);
  });

  test('updateInvoice refuses a total below amount already paid', () async {
    await addProduct('sp2', 10);
    final product = (await ProductService.getProductById('sp2'))!;
    await InvoiceService.insertInvoice(salesInvoice('00000002', product, 3));
    final stored = (await InvoiceService.getInvoiceById('00000002'))!;
    await PaymentService.addPayment(
        invoice: stored,
        amountPaid: 100,
        datePaid: DateTime(2026, 1, 11),
        paymentMethod: 'Cash');

    final shrunk = salesInvoice('00000002', product, 0.5); // total 50 < 100
    await expectLater(
        () => InvoiceService.updateInvoice(shrunk),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('below amount already paid'))));
  });
}
