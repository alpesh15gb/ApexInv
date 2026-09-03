import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/services/vyapar_import_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('imports a realistic backup safely and is idempotent', () async {
    final target = await openDatabase(
      inMemoryDatabasePath,
      version: DatabaseHelper().dbVersion,
      onCreate: (db, version) => DatabaseHelper().createDbForTest(db, version),
    );
    DatabaseHelper().useDatabaseForTest(target);
    final directory =
        await Directory.systemTemp.createTemp('vyapar_import_test_');
    final sourcePath = '${directory.path}${Platform.pathSeparator}fixture.vyp';
    final source = await openDatabase(sourcePath);
    await _createFixture(source);
    await source.close();

    try {
      final first = await VyaparImportService.importFromVyp(sourcePath);

      expect(first.customersImported, 2);
      expect(first.productsImported, 2);
      expect(first.invoicesImported, 2);
      expect(first.quotationsImported, 1);
      expect(first.purchaseOrdersImported, 1);
      expect(first.purchaseBillsImported, 1);
      expect(first.warnings.join('\n'), contains('kb_firms is missing'));
      expect(first.warnings.join('\n'), contains('kb_tax_code is missing'));
      expect(first.warnings.join('\n'), contains('malformed payment'));
      expect(first.warnings.join('\n'), contains('no usable line items'));

      final customers = await target.query('customers', orderBy: 'id');
      expect(customers, hasLength(2));
      expect(customers.map((row) => row['name']), everyElement('Same Name'));

      final products = await target.query('products');
      expect(products, hasLength(2));
      expect(products.firstWhere((row) => row['hsncode'] == '1001')['stock'],
          1.75);
      expect(
          products.firstWhere((row) => row['hsncode'] == '1002')['stock'], 2.5);

      final invoices = await target.query('invoices', orderBy: 'id');
      expect(invoices, hasLength(3));
      final invoice =
          invoices.firstWhere((row) => row['invoice_number'] == 'INV-1');
      expect(invoice['customer_name'], 'Same Name');
      expect(invoice['customer_email'], 'one@example.com');
      expect(invoice['customer_phone'], '111');
      expect(invoice['customer_address'], 'First address');
      expect(invoice['customer_gstin'], 'GST-ONE');
      expect(invoice['customer_business_name'], 'First business');

      final lines = await target.query('invoice_items',
          where: 'invoice_id = ?', whereArgs: [invoice['id']]);
      expect(lines, hasLength(2));
      expect(lines.map((row) => row['id']).toSet(), hasLength(2));
      expect(lines.map((row) => row['product_name']),
          everyElement('Same Product'));
      expect(lines.first['product_description'], 'First product snapshot');
      expect(lines.first['product_hsn_code'], '1001');
      expect(lines.first['product_purchase_price'], 6.5);
      expect(lines.first['product_unit'], 'kg');

      final payments = await target.query('invoice_payments');
      expect(payments, hasLength(2));
      final directPayment =
          payments.firstWhere((row) => row['receipt_number'] == 'VYP-30');
      final linkedPayment =
          payments.firstWhere((row) => row['receipt_number'] == 'VYP-R-33');
      expect(directPayment['amount_paid'], 100.0);
      expect(directPayment['payment_method'], 'DCB BANK');
      expect(linkedPayment['amount_paid'], 20.0);
      expect(linkedPayment['previously_paid'], 100.0);
      expect(linkedPayment['balance_after'], 0.0);
      expect(linkedPayment['payment_method'], 'DCB BANK');

      final quotation = await target
          .query('invoices', where: 'invoice_number = ?', whereArgs: ['Q-1']);
      expect(quotation.single['type'], 'Quotation');
      expect(await _count(target, 'purchase_orders'), 1);
      expect(await _count(target, 'purchase_order_items'), 1);
      expect(await _count(target, 'purchase_bills'), 1);
      expect(await _count(target, 'purchase_bill_items'), 1);
      expect(await _count(target, 'purchase_bill_payments'), 1);
      final order = (await target.query('purchase_orders')).single;
      expect(order['vendor_name'], 'Supplier');
      expect(order['total_amount'], 118.0);
      final bill = (await target.query('purchase_bills')).single;
      expect(bill['supplier_gstin'], 'GST-SUPPLIER');
      expect(bill['total_amount'], 236.0);
      expect(bill['total_tax'], 36.0);
      final purchasePayment =
          (await target.query('purchase_bill_payments')).single;
      expect(purchasePayment['amount_paid'], 50.0);
      expect(purchasePayment['payment_method'], 'Imported');

      final second = await VyaparImportService.importFromVyp(sourcePath);
      expect(second.customersImported, 0);
      expect(second.productsImported, 0);
      expect(second.invoicesImported, 0);
      expect(second.quotationsImported, 0);
      expect(second.purchaseOrdersImported, 0);
      expect(second.purchaseBillsImported, 0);
      expect(await _count(target, 'customers'), 2);
      expect(await _count(target, 'products'), 2);
      expect(await _count(target, 'invoices'), 3);
      expect(await _count(target, 'invoice_items'), 4);
      expect(await _count(target, 'invoice_payments'), 2);
      expect(await _count(target, 'purchase_orders'), 1);
      expect(await _count(target, 'purchase_order_items'), 1);
      expect(await _count(target, 'purchase_bills'), 1);
      expect(await _count(target, 'purchase_bill_items'), 1);
      expect(await _count(target, 'purchase_bill_payments'), 1);
    } finally {
      DatabaseHelper().clearDatabaseForTest();
      await target.close();
      await directory.delete(recursive: true);
    }
  });
}

Future<int> _count(Database db, String table) async =>
    Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $table'))!;

Future<void> _createFixture(Database db) async {
  // kb_firms and kb_tax_code are deliberately absent: both are optional.
  await db.execute('''CREATE TABLE kb_names (
    name_id INTEGER PRIMARY KEY, name_type INTEGER, full_name TEXT, email TEXT,
    phone_number TEXT, address TEXT, name_gstin_number TEXT, party_billing_name TEXT
  )''');
  await db.execute('''CREATE TABLE kb_items (
    item_id INTEGER PRIMARY KEY, item_name TEXT, item_is_active INTEGER,
    item_sale_unit_price REAL, item_purchase_unit_price REAL,
    item_stock_quantity REAL, item_hsn_sac_code TEXT, item_description TEXT,
    item_type INTEGER, item_discount REAL, item_unit TEXT
  )''');
  await db.execute('''CREATE TABLE kb_transactions (
    txn_id INTEGER PRIMARY KEY, txn_type INTEGER, txn_status INTEGER,
     txn_name_id INTEGER, txn_date TEXT, txn_cash_amount REAL,
     txn_balance_amount REAL, txn_ref_number_char TEXT
     , txn_sub_type INTEGER, txn_due_date TEXT, txn_description TEXT,
     txn_itc_applicable INTEGER, txn_reverse_charge INTEGER
  )''');
  await db.execute('''CREATE TABLE kb_lineitems (
    lineitem_txn_id INTEGER, item_id INTEGER, quantity REAL, priceperunit REAL,
    lineitem_discount_amount REAL, lineitem_tax_amount REAL,
    lineitem_description TEXT
  )''');
  await db.execute('''CREATE TABLE kb_paymentTypes (
    paymentType_id INTEGER PRIMARY KEY, paymentType_name TEXT
  )''');
  await db.execute('''CREATE TABLE txn_payment_mapping (
    id INTEGER PRIMARY KEY, txn_id INTEGER, payment_id INTEGER, amount REAL
  )''');
  await db.execute('''CREATE TABLE kb_txn_links (
    txn_links_id INTEGER PRIMARY KEY, txn_links_txn_1_id INTEGER,
    txn_links_txn_2_id INTEGER, txn_links_amount REAL
  )''');
  await db.insert('kb_names', {
    'name_id': 10,
    'name_type': 1,
    'full_name': 'Same Name',
    'email': 'one@example.com',
    'phone_number': '111',
    'address': 'First address',
    'name_gstin_number': 'GST-ONE',
    'party_billing_name': 'First business',
  });
  await db.insert('kb_names', {
    'name_id': 12,
    'name_type': 2,
    'full_name': 'Supplier',
    'email': 'supplier@example.com',
    'phone_number': '333',
    'address': 'Supplier address',
    'name_gstin_number': 'GST-SUPPLIER',
  });
  await db.insert('kb_names', {
    'name_id': 11,
    'name_type': 1,
    'full_name': 'Same Name',
    'email': 'two@example.com',
    'phone_number': '222',
  });
  await db.insert('kb_items', {
    'item_id': 20,
    'item_name': 'Same Product',
    'item_is_active': 1,
    'item_sale_unit_price': 10.0,
    'item_purchase_unit_price': 6.5,
    'item_stock_quantity': 1.75,
    'item_hsn_sac_code': '1001',
    'item_description': 'First product snapshot',
    'item_type': 1,
    'item_unit': 'kg',
  });
  await db.insert('kb_items', {
    'item_id': 21,
    'item_name': 'Same Product',
    'item_is_active': 1,
    'item_sale_unit_price': 20.0,
    'item_purchase_unit_price': 11.0,
    'item_stock_quantity': 2.5,
    'item_hsn_sac_code': '1002',
    'item_description': 'Second product snapshot',
    'item_type': 1,
    'item_unit': 'box',
  });
  await db.insert('kb_transactions', {
    'txn_id': 30,
    'txn_type': 1,
    'txn_status': 1,
    'txn_name_id': 10,
    'txn_date': '2026-01-15T10:00:00',
    'txn_cash_amount': 100.0,
    'txn_balance_amount': 20.0,
    'txn_ref_number_char': 'INV-1',
    'txn_sub_type': 1,
  });
  await db.insert('kb_transactions', {
    'txn_id': 31,
    'txn_type': 1,
    'txn_status': 1,
    'txn_name_id': 11,
    'txn_date': '2026-01-16T10:00:00',
    'txn_cash_amount': 50.0,
    'txn_balance_amount': -10.0,
    'txn_ref_number_char': 'INV-2',
    'txn_sub_type': 1,
  });
  await db.insert('kb_transactions', {
    'txn_id': 32,
    'txn_type': 1,
    'txn_status': 1,
    'txn_name_id': 10,
    'txn_date': '2026-01-17T10:00:00',
    'txn_cash_amount': 10.0,
    'txn_balance_amount': 10.0,
    'txn_ref_number_char': 'INV-INVALID',
    'txn_sub_type': 1,
  });
  await db.insert('kb_transactions', {
    'txn_id': 33,
    'txn_type': 3,
    'txn_status': 1,
    'txn_name_id': 10,
    'txn_date': '2026-01-20T10:00:00',
    'txn_cash_amount': 20.0,
    'txn_balance_amount': 0.0,
    'txn_ref_number_char': 'RCPT-1',
  });
  await db.insert('kb_transactions', {
    'txn_id': 34,
    'txn_type': 27,
    'txn_status': 1,
    'txn_name_id': 10,
    'txn_date': '2026-01-21T10:00:00',
    'txn_ref_number_char': 'Q-1',
  });
  await db.insert('kb_transactions', {
    'txn_id': 35,
    'txn_type': 28,
    'txn_sub_type': 1,
    'txn_status': 1,
    'txn_name_id': 12,
    'txn_date': '2026-01-22T10:00:00',
    'txn_ref_number_char': 'PO-1',
    'txn_cash_amount': 10.0,
    'txn_due_date': '2026-01-30T10:00:00',
  });
  await db.insert('kb_transactions', {
    'txn_id': 36,
    'txn_type': 2,
    'txn_sub_type': 4,
    'txn_status': 1,
    'txn_name_id': 12,
    'txn_date': '2026-01-23T10:00:00',
    'txn_ref_number_char': 'PB-1',
    'txn_cash_amount': 50.0,
    'txn_due_date': '2026-02-01T10:00:00',
    'txn_description': 'Supplier bill',
    'txn_itc_applicable': 1,
  });
  await db.insert('kb_paymentTypes', {
    'paymentType_id': 3,
    'paymentType_name': 'DCB BANK',
  });
  await db.insert('txn_payment_mapping', {
    'id': 1,
    'txn_id': 30,
    'payment_id': 3,
    'amount': 100.0,
  });
  await db.insert('txn_payment_mapping', {
    'id': 2,
    'txn_id': 33,
    'payment_id': 3,
    'amount': 20.0,
  });
  await db.insert('kb_txn_links', {
    'txn_links_id': 1,
    'txn_links_txn_1_id': 30,
    'txn_links_txn_2_id': 33,
    'txn_links_amount': 20.0,
  });
  for (final quantity in [2.0, 3.0]) {
    await db.insert('kb_lineitems', {
      'lineitem_txn_id': 30,
      'item_id': 20,
      'quantity': quantity,
      'priceperunit': 10.0,
      'lineitem_tax_amount': 1.8,
    });
  }
  await db.insert('kb_lineitems', {
    'lineitem_txn_id': 31,
    'item_id': 21,
    'quantity': 1.0,
    'priceperunit': 20.0,
  });
  await db.insert('kb_lineitems', {
    'lineitem_txn_id': 34,
    'item_id': 20,
    'quantity': 1.0,
    'priceperunit': 10.0,
  });
  await db.insert('kb_lineitems', {
    'lineitem_txn_id': 35,
    'item_id': 20,
    'quantity': 1.0,
    'priceperunit': 100.0,
    'lineitem_tax_amount': 18.0,
  });
  await db.insert('kb_lineitems', {
    'lineitem_txn_id': 36,
    'item_id': 21,
    'quantity': 2.0,
    'priceperunit': 100.0,
    'lineitem_tax_amount': 36.0,
  });
  await db.insert('kb_lineitems', {
    'lineitem_txn_id': 32,
    'item_id': 20,
    'quantity': 0.0,
    'priceperunit': 10.0,
  });
}
