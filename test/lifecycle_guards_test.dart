import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/purchase_order_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/purchase_order.dart';

/// Regression tests for the verified lifecycle bugs:
/// C1 paid-invoice soft-delete block, C2 PO stock guards, C3 reverse-charge
/// net outstanding, C4 purchase-bill edit overpay guard, C5 flat-discount
/// service guard.
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

  Future<void> addProduct(String id, double stock) async {
    await ProductService.insertProduct(Product(
      id: id,
      name: 'Widget $id',
      description: '',
      price: 100,
      stock: stock,
      hsncode: '',
      tax_rate: 0,
    ));
  }

  Future<num> stockOf(String id) async =>
      (await ProductService.getProductById(id))!.stock;

  Invoice salesInvoice(String id, Product product, double qty,
      {InvoiceDiscountType discountType = InvoiceDiscountType.percent,
      double discountValue = 0}) {
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
      invoiceDiscountType: discountType,
      invoiceDiscountValue: discountValue,
    );
  }

  PurchaseBill bill(String id,
      {double total = 1000,
      double tax = 0,
      bool reverseCharge = false,
      List<PurchaseBillItem>? items}) {
    return PurchaseBill(
      id: id,
      billNumber: 'B-$id',
      supplierName: 'Acme',
      date: DateTime(2026, 1, 5),
      totalAmount: total,
      totalTax: tax,
      reverseCharge: reverseCharge,
      items: items ?? const [],
    );
  }

  PurchaseOrder po(String id, String productId, double qty,
      {String status = 'draft', double amountPaid = 0}) {
    final item = PurchaseOrderItem(
      id: 'poi-$id-$qty',
      productId: productId,
      productName: 'Widget',
      quantity: qty,
      pricePerUnit: 100,
    );
    return PurchaseOrder(
      id: id,
      orderNumber: 'PO-$id',
      vendorName: 'Vendor',
      items: [item],
      date: DateTime(2026, 1, 5),
      status: status,
      totalAmount: qty * 100,
      amountPaid: amountPaid,
    );
  }

  group('C1 soft-delete of paid invoice is blocked', () {
    test('throws, keeps invoice active, stock reserved, payments intact',
        () async {
      await addProduct('sp1', 10);
      final product = (await ProductService.getProductById('sp1'))!;
      await InvoiceService.insertInvoice(salesInvoice('inv-paid', product, 3));
      final stored = (await InvoiceService.getInvoiceById('inv-paid'))!;
      await PaymentService.addPayment(
          invoice: stored,
          amountPaid: 100,
          datePaid: DateTime(2026, 1, 11),
          paymentMethod: 'Cash');

      await expectLater(
          () => InvoiceService.softDeleteInvoice('inv-paid'),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('live payments'))));

      // Nothing moved: invoice still active, stock still reserved, cash kept.
      expect(await InvoiceService.getInvoiceById('inv-paid'), isNotNull);
      expect(await InvoiceService.getDeletedInvoices(), isEmpty);
      expect(await stockOf('sp1'), 7);
      expect(await PaymentService.getTotalPaidForInvoice('inv-paid'), 100);
    });

    test('unpaid invoice still soft-deletes and restores symmetrically',
        () async {
      await addProduct('sp2', 10);
      final product = (await ProductService.getProductById('sp2'))!;
      await InvoiceService.insertInvoice(salesInvoice('inv-free', product, 3));
      await InvoiceService.softDeleteInvoice('inv-free');
      expect(await InvoiceService.getInvoiceById('inv-free'), isNull);
      expect(await stockOf('sp2'), 10);
      await InvoiceService.restoreInvoice('inv-free');
      expect(await InvoiceService.getInvoiceById('inv-free'), isNotNull);
      expect(await stockOf('sp2'), 7);
    });
  });

  group('C2 purchase order stock guards', () {
    test('receive then delete restores stock', () async {
      await addProduct('p1', 10);
      await PurchaseOrderService.insertPurchaseOrder(
          po('po1', 'p1', 5), po('po1', 'p1', 5).items);
      expect(await stockOf('p1'), 10);
      expect(await PurchaseOrderService.markAsReceived('po1'), isTrue);
      expect(await stockOf('p1'), 15);

      await PurchaseOrderService.deletePurchaseOrder('po1');
      expect(await stockOf('p1'), 10);
      expect(await PurchaseOrderService.getPurchaseOrderById('po1'), isNull);
    });

    test('draft to received via updateStatus adds stock exactly once',
        () async {
      await addProduct('p2', 10);
      await PurchaseOrderService.insertPurchaseOrder(
          po('po2', 'p2', 5), po('po2', 'p2', 5).items);
      await PurchaseOrderService.updateStatus('po2', 'received');
      expect(await stockOf('p2'), 15);
      // Idempotent: a second flip must not double-add.
      await PurchaseOrderService.updateStatus('po2', 'received');
      expect(await stockOf('p2'), 15);
    });

    test('received to cancelled via updateStatus reverses stock', () async {
      await addProduct('p3', 10);
      await PurchaseOrderService.insertPurchaseOrder(
          po('po3', 'p3', 5), po('po3', 'p3', 5).items);
      await PurchaseOrderService.updateStatus('po3', 'received');
      expect(await stockOf('p3'), 15);
      await PurchaseOrderService.updateStatus('po3', 'cancelled');
      expect(await stockOf('p3'), 10);
      expect((await PurchaseOrderService.getPurchaseOrderById('po3'))!.status,
          'cancelled');
    });

    test('edit after receive applies net delta and keeps amountPaid', () async {
      await addProduct('p4', 10);
      await PurchaseOrderService.insertPurchaseOrder(
          po('po4', 'p4', 5, amountPaid: 200),
          po('po4', 'p4', 5, amountPaid: 200).items);
      await PurchaseOrderService.markAsReceived('po4');
      expect(await stockOf('p4'), 15);

      // Grow lines 5 -> 7 while (incorrectly) passing amountPaid 0: stock
      // must move by the +2 delta and the stored 200 must survive.
      final edited = po('po4', 'p4', 7, status: 'received', amountPaid: 0);
      await PurchaseOrderService.updatePurchaseOrder(edited,
          items: edited.items);
      expect(await stockOf('p4'), 17);
      expect(
          (await PurchaseOrderService.getPurchaseOrderById('po4'))!.amountPaid,
          200);
    });
  });

  group('C3 reverse-charge bills owe the net', () {
    test('RC bill 118 shows outstanding 100 and cannot pay 118', () async {
      await PurchaseBillService.insertBill(
          bill('rc1', total: 118, tax: 18, reverseCharge: true));
      final stored = (await PurchaseBillService.getBill('rc1'))!;
      expect(stored.payableTotal, 100);
      expect(stored.outstanding, 100);

      // The gross 118 exceeds the net outstanding, so it is refused and
      // books nothing; paying the exact net 100 settles the bill.
      await expectLater(
          () => PurchaseBillService.recordPayment('rc1', 118,
              datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash'),
          throwsA(isA<StateError>()));
      expect((await PurchaseBillService.getBill('rc1'))!.outstanding, 100);
      final payment = await PurchaseBillService.recordPayment('rc1', 100,
          datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash');
      expect(payment.amountPaid, 100);
      expect((await PurchaseBillService.getBill('rc1'))!.outstanding, 0);
    });

    test('RC batch allocation above the net is refused', () async {
      await PurchaseBillService.insertBill(
          bill('rc2', total: 118, tax: 18, reverseCharge: true));
      final stored = (await PurchaseBillService.getBill('rc2'))!;
      await expectLater(
          () => PurchaseBillService.recordPaymentBatch(
                allocations: [(bill: stored, amount: 101)],
                datePaid: DateTime(2026, 2, 1),
                paymentMethod: 'Cash',
              ),
          throwsA(isA<StateError>()));
    });
  });

  group('C4 purchase-bill edit overpay guard', () {
    test('shrinking the total below amount paid throws', () async {
      await PurchaseBillService.insertBill(bill('bill-edit', total: 1000));
      await PurchaseBillService.recordPayment('bill-edit', 800,
          datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash');

      await expectLater(
          () => PurchaseBillService.updateBill(bill('bill-edit', total: 500)),
          throwsA(isA<StateError>().having((e) => e.message, 'message',
              contains('below amount already paid'))));

      // Failed edit changed nothing.
      final stored = (await PurchaseBillService.getBill('bill-edit'))!;
      expect(stored.totalAmount, 1000);
      expect(stored.amountPaid, 800);
    });
  });

  group('C5 flat invoice discount guard', () {
    test('flat discount above the pre-discount total is refused', () async {
      await addProduct('sp3', 10);
      final product = (await ProductService.getProductById('sp3'))!;
      final bad = salesInvoice('inv-disc', product, 1,
          discountType: InvoiceDiscountType.amount, discountValue: 150);
      // Pre-discount total is 100 (1 x 100, no tax): 150 must not persist.
      await expectLater(
          () => InvoiceService.insertInvoice(bad),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('pre-discount'))));

      // A sane flat discount still saves.
      final ok = salesInvoice('inv-disc-ok', product, 1,
          discountType: InvoiceDiscountType.amount, discountValue: 10);
      await InvoiceService.insertInvoice(ok);
      expect(await InvoiceService.getInvoiceById('inv-disc-ok'), isNotNull);

      // And edits cannot sneak an excessive discount in either.
      final badEdit = salesInvoice('inv-disc-ok', product, 1,
          discountType: InvoiceDiscountType.amount, discountValue: 500);
      await expectLater(
          () => InvoiceService.updateInvoice(badEdit),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('pre-discount'))));
    });
  });
}
