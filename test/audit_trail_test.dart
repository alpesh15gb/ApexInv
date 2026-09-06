import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/audit_log_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';

/// Audit-trail coverage: every money mutation logs inside its own DB
/// transaction with actor + entity + before→after diff.
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
    AuditActor.clear();
  });

  tearDown(() async {
    AuditActor.clear();
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

  test('payment add logs queryable row with before→after amounts', () async {
    final product = await addProduct('audit-pay-p', 100);
    await InvoiceService.insertInvoice(salesInvoice('audit-pay', product, 2),
        actor: 'alice');
    var stored = (await InvoiceService.getInvoiceById('audit-pay'))!;

    final payment = await PaymentService.addPayment(
      invoice: stored,
      amountPaid: 50,
      datePaid: DateTime(2026, 1, 11),
      paymentMethod: 'Cash',
      actor: 'alice',
    );

    final rows = await db.query(
      'audit_log',
      where: 'action = ? AND entity_id = ?',
      whereArgs: ['payment_add', payment.id],
    );
    expect(rows, hasLength(1));
    expect(rows.first['username'], 'alice');
    expect(rows.first['entity'], 'invoice_payments');
    expect(rows.first['created_at'], isNotNull);
    final details = rows.first['details'] as String? ?? '';
    // Before→after diff: 0 paid → 50 paid, amount legible.
    expect(details, contains('50.00'));
    expect(details, contains('0.00'));
    expect(details, contains('→'));
  });

  test('payment delete logs queryable row with amount → —', () async {
    final product = await addProduct('audit-del-p', 100);
    await InvoiceService.insertInvoice(salesInvoice('audit-del', product, 2),
        actor: 'bob');
    var stored = (await InvoiceService.getInvoiceById('audit-del'))!;
    final payment = await PaymentService.addPayment(
      invoice: stored,
      amountPaid: 60,
      datePaid: DateTime(2026, 1, 11),
      paymentMethod: 'Cash',
      actor: 'bob',
    );

    await PaymentService.deletePayment(payment.id, actor: 'bob');

    final rows = await db.query(
      'audit_log',
      where: 'action = ? AND entity_id = ?',
      whereArgs: ['payment_delete', payment.id],
    );
    expect(rows, hasLength(1));
    expect(rows.first['username'], 'bob');
    expect(rows.first['entity'], 'invoice_payments');
    final details = rows.first['details'] as String? ?? '';
    expect(details, contains('60.00'));
    expect(details, contains('→'));
    expect(details, contains('—'));
  });

  test('invoice edit logs queryable row with total before→after', () async {
    final product = await addProduct('audit-inv-p', 100);
    await InvoiceService.insertInvoice(salesInvoice('audit-inv', product, 2),
        actor: 'carol');
    var stored = (await InvoiceService.getInvoiceById('audit-inv'))!;
    final beforeTotal = stored.payableTotal;

    final edited = Invoice(
      id: stored.id,
      invoiceNumber: stored.invoiceNumber,
      customer: stored.customer,
      items: [InvoiceItem(product: product, quantity: 5)],
      date: stored.date,
      type: stored.type,
      taxRate: stored.taxRate,
      taxMode: stored.taxMode,
    );
    await InvoiceService.updateInvoice(edited, actor: 'carol');

    final rows = await db.query(
      'audit_log',
      where: 'action = ? AND entity_id = ?',
      whereArgs: ['invoice_update', stored.id],
      orderBy: 'created_at DESC',
    );
    expect(rows, isNotEmpty);
    final latest = rows.first;
    expect(latest['username'], 'carol');
    expect(latest['entity'], 'invoices');
    final details = latest['details'] as String? ?? '';
    expect(details, contains(beforeTotal.toStringAsFixed(2)));
    expect(details, contains(edited.payableTotal.toStringAsFixed(2)));
    expect(details, contains('→'));
  });
}
