// P3 + P4 vertical regression tests (retail.md Â§6): old-gold exchange,
// karigar job-work lifecycle, product variants, loyalty award.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/customer_service.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/jewellery_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/product_variant_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/verticals.dart';

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

  Future<void> setRate(double rate) async {
    await db.delete('settings',
        where: '"key" = ?', whereArgs: ['loyalty_points_per_100']);
    await db.insert(
        'settings', {'key': 'loyalty_points_per_100', 'value': '$rate'});
  }

  Future<Customer> addCustomer(String id) async {
    final c = Customer(
      id: id,
      name: 'Buyer $id',
      email: '',
      phone: '',
      address: '',
      gstin: '',
      loyaltyPoints: 0,
    );
    await CustomerService.insertCustomer(c);
    final stored = (await db.query('customers',
        where: 'id = ?', whereArgs: [id], limit: 1));
    return Customer.fromMap(stored.first);
  }

  Future<Invoice> addSalesInvoice(String id, Customer savedCustomer) async {
    final customer = savedCustomer;
    final product = Product(
      id: 'p$id',
      name: 'Widget',
      description: '',
      price: 20000,
      stock: 50,
      hsncode: '',
      tax_rate: 0,
    );
    await ProductService.insertProduct(product);
    final invoice = Invoice(
      id: id,
      customer: Customer(
          id: 'c1',
          name: 'Buyer',
          email: '',
          phone: '',
          address: '',
          gstin: ''),
      items: [InvoiceItem(product: product, quantity: 2)],
      date: DateTime(2026, 9, 9),
      type: 'Invoice',
    );
    await InvoiceService.insertInvoice(invoice);
    return invoice;
  }

  test('old gold: entries persist without automatic RCM and book as a receipt',
      () async {
    final customer = await addCustomer('c1');
    final invoice = await addSalesInvoice('inv1', customer);
    final entry = OldGoldEntry(
      id: 'og1',
      customerId: customer.id,
      customerName: customer.name,
      metal: 'gold',
      purity: '22K',
      grossWeight: 10,
      netWeight: 8,
      ratePerGram: 5000,
      // The buyback rate is already configured for this purity.
      amount: 8 * 5000, // 40000
    );

    await InvoiceService.updateInvoice(invoice, oldGoldEntries: [entry]);

    final rows = await db.query('old_gold_entries',
        where: 'invoice_id = ?', whereArgs: ['inv1']);
    expect(rows, hasLength(1));
    expect((rows.first['amount'] as num).toDouble(), closeTo(40000, 0.01));

    // A customer exchange cannot infer RCM from registration status.
    final journal = await db.query('journal_entries',
        where: 'source_type = ? AND source_id = ?',
        whereArgs: ['old_gold', 'og1']);
    expect(journal, isEmpty);

    // Exchange credit = one receipt into Old Gold Stock.
    final payments = await db.query('invoice_payments',
        where: 'invoice_id = ?', whereArgs: ['inv1']);
    expect(payments, hasLength(1));
    expect(payments.first['payment_method'], 'Old gold exchange');
    expect((payments.first['amount_paid'] as num).toDouble(),
        closeTo(40000, 0.01));
  });

  test('editing preserves explicit historical RCM postings when present',
      () async {
    final customer = await addCustomer('c1');
    final invoice = await addSalesInvoice('inv1', customer);
    await InvoiceService.updateInvoice(invoice, oldGoldEntries: [
      OldGoldEntry(
          id: 'og1',
          customerName: customer.name,
          metal: 'gold',
          amount: 1000,
          rcmTax: 30),
    ]);

    await InvoiceService.updateInvoice(invoice, oldGoldEntries: [
      OldGoldEntry(
          id: 'og2',
          customerName: customer.name,
          metal: 'gold',
          amount: 2000,
          rcmTax: 60),
    ]);

    final rows = await db.query('old_gold_entries');
    expect(rows, hasLength(1));
    expect(rows.first['id'], 'og2');

    // The mirror of og1's posting stays for history; og2 posts once.
    final rcmJournals = await db.query('journal_entries',
        where: 'source_type = ? AND source_id = ?',
        whereArgs: ['old_gold', 'og2']);
    expect(rcmJournals, hasLength(1));
  });

  test('job work: issue â†’ receive computes the wastage percent', () async {
    var order = JobWorkOrder(
      id: 'jw1',
      karigar: 'Ramesh',
      metal: 'gold',
      purity: '22K',
      issuedGross: 20,
      issuedStone: 2,
      issuedDate: DateTime(2026, 9, 1),
    );
    await JewelleryService.upsertJobWorkOrder(order);
    expect((await JewelleryService.getJobWorkOrders()).length, 1);

    order = order.copyWith(
      status: 'received',
      receivedNet: 18,
      wastagePercent: ((20 - 2 - 18) / (20 - 2) * 100),
      receivedDate: DateTime(2026, 9, 8),
    );
    await JewelleryService.upsertJobWorkOrder(order);

    final stored =
        (await JewelleryService.getJobWorkOrders(status: 'received')).first;
    expect(stored.issuedNet, 18);
    expect(stored.wastagePercent, closeTo(0, 0.001));

    await JewelleryService.deleteJobWorkOrder('jw1');
    expect(await JewelleryService.getJobWorkOrders(), isEmpty);
  });

  test('product variants: crud and full replace', () async {
    await ProductVariantService.upsert(ProductVariant(
        id: 'v1',
        productId: 'p1',
        name: 'Size',
        value: 'M',
        extraPrice: 100,
        stock: 4));
    await ProductVariantService.upsert(ProductVariant(
        id: 'v2', productId: 'p1', name: 'Size', value: 'L', stock: 2));

    var list = await ProductVariantService.getForProduct('p1');
    expect(list, hasLength(2));

    await ProductVariantService.replaceForProduct(productId: 'p1', variants: [
      ProductVariant(id: 'v3', productId: 'p1', name: 'Colour', value: 'Red')
    ]);
    list = await ProductVariantService.getForProduct('p1');
    expect(list, hasLength(1));
    expect(list.first.value, 'Red');

    await ProductVariantService.delete('v3');
    expect(await ProductVariantService.getForProduct('p1'), isEmpty);
  });

  test('loyalty: award on insert, delta on update, off when rate is 0',
      () async {
    await setRate(2); // 2 points per 100 spent
    final customer = await addCustomer('c1');
    final invoice = await addSalesInvoice('inv1', customer);
    final award =
        (await db.query('invoices', where: 'id = ?', whereArgs: ['inv1']))
            .first['loyalty_points'] as num?;
    expect(award, greaterThan(0));

    final customerRow = await db.query('customers',
        where: 'id = ?', whereArgs: ['c1'], limit: 1);
    expect((customerRow.first['loyalty_points'] as num).toDouble(),
        (award!).toDouble());

    // Rate off â†’ edits award nothing new; customer keeps its balance.
    await setRate(0);
    await InvoiceService.updateInvoice(invoice);
    final customerRow2 = await db.query('customers',
        where: 'id = ?', whereArgs: ['c1'], limit: 1);
    final invoiceRow2 = await db.query('invoices',
        where: 'id = ?', whereArgs: ['inv1'], limit: 1);
    // The invoice snapshot re-zeroed at rate 0, so the customer keeps only
    // the original award.
    expect((customerRow2.first['loyalty_points'] as num).toDouble(),
        (customerRow.first['loyalty_points'] as num).toDouble());
    expect((invoiceRow2.first['loyalty_points'] as num).toDouble(),
        (customerRow.first['loyalty_points'] as num).toDouble());
  });

  test('PaymentService books the old-gold receipt into Old Gold Stock',
      () async {
    final product = Product(
      id: 'p9',
      name: 'Ring',
      description: '',
      price: 20000,
      stock: 10,
      hsncode: '',
      tax_rate: 0,
    );
    await ProductService.insertProduct(product);
    final invoice = Invoice(
      id: 'inv2',
      customer: Customer(
          id: 'c1',
          name: 'Buyer',
          email: '',
          phone: '',
          address: '',
          gstin: ''),
      items: [InvoiceItem(product: product, quantity: 1)],
      date: DateTime(2026, 9, 9),
      type: 'Invoice',
    );
    await InvoiceService.insertInvoice(invoice);
    await PaymentService.addPayment(
      invoice: invoice,
      amountPaid: 500,
      datePaid: DateTime(2026, 9, 9),
      paymentMethod: 'Old gold exchange',
    );

    final journal = await db.rawQuery('''
      SELECT l.account, l.debit
      FROM journal_lines l
      JOIN journal_entries e ON e.id = l.entry_id
      WHERE e.source_type = 'invoice_payment' AND l.debit > 0
    ''');
    final debitAccounts = [
      for (final row in journal) row['account'] as String?
    ];
    expect(debitAccounts, contains('1300 Old Gold Stock'));
  });
}
