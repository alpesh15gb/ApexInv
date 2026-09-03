import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:apexbooks/database/database_helper.dart';

/// Result of a Vyapar import operation.
class VyaparImportResult {
  final int customersImported;
  final int customersSkipped;
  final int productsImported;
  final int productsSkipped;
  final int invoicesImported;
  final int invoicesSkipped;
  final int quotationsImported;
  final int quotationsSkipped;
  final int purchaseOrdersImported;
  final int purchaseOrdersSkipped;
  final int purchaseBillsImported;
  final int purchaseBillsSkipped;
  final List<String> warnings;

  const VyaparImportResult({
    required this.customersImported,
    required this.customersSkipped,
    required this.productsImported,
    required this.productsSkipped,
    required this.invoicesImported,
    required this.invoicesSkipped,
    required this.quotationsImported,
    required this.quotationsSkipped,
    required this.purchaseOrdersImported,
    required this.purchaseOrdersSkipped,
    required this.purchaseBillsImported,
    required this.purchaseBillsSkipped,
    this.warnings = const [],
  });

  @override
  String toString() =>
      'Imported: $customersImported customers, $productsImported products, $invoicesImported invoices, '
      '$quotationsImported quotations, $purchaseOrdersImported purchase orders, $purchaseBillsImported purchase bills. '
      'Skipped: $customersSkipped customers, $productsSkipped products, $invoicesSkipped invoices, '
      '$quotationsSkipped quotations, $purchaseOrdersSkipped purchase orders, $purchaseBillsSkipped purchase bills. '
      'Warnings: ${warnings.length}';
}

class VyaparImportService {
  /// Parse a .vyb file (which is a ZIP containing a .vyp SQLite database)
  /// and return the path to the extracted .vyp file.
  static Future<String> extractVypFile(
      Uint8List vybBytes, String tempDir) async {
    final archive = ZipDecoder().decodeBytes(vybBytes);
    for (final file in archive) {
      if (file.isFile && file.name.endsWith('.vyp')) {
        final outPath = p.join(tempDir, p.basename(file.name));
        await File(outPath).writeAsBytes(file.content as List<int>);
        return outPath;
      }
    }
    throw Exception('No .vyp file found inside the .vyb archive');
  }

  /// Extract metadata from the Vyapar database to preview before importing.
  static Future<VyaparPreview> preview(String vypPath) async {
    final db = await openReadOnlyDatabase(vypPath);
    try {
      final tables = await _tables(db);
      final nameColumns = await _columns(db, tables, 'kb_names');
      final itemColumns = await _columns(db, tables, 'kb_items');
      final transactionColumns = await _columns(db, tables, 'kb_transactions');
      final customerCount = nameColumns.contains('name_type')
          ? await _count(db, 'kb_names', 'name_type = 1')
          : 0;
      final vendorCount = nameColumns.contains('name_type')
          ? await _count(db, 'kb_names', 'name_type = 2')
          : 0;
      final productCount = tables.contains('kb_items')
          ? await _count(
              db,
              'kb_items',
              itemColumns.contains('item_is_active')
                  ? 'item_is_active = 1 OR item_is_active IS NULL'
                  : null)
          : 0;
      final txnCount = transactionColumns.contains('txn_type')
          ? await _count(db, 'kb_transactions', 'txn_type = 1')
          : 0;
      final firmCount =
          tables.contains('kb_firms') ? await _count(db, 'kb_firms', null) : 0;
      String firmName = '';
      if (firmCount > 0) {
        final firm = await db.query('kb_firms', limit: 1);
        if (firm.isNotEmpty) firmName = _text(firm.first['firm_name']);
      }
      return VyaparPreview(
        customerCount: customerCount,
        vendorCount: vendorCount,
        productCount: productCount,
        invoiceCount: txnCount,
        firmName: firmName,
      );
    } finally {
      await db.close();
    }
  }

  /// Import a Vyapar SQLite backup. Source primary keys, rather than names,
  /// form stable target IDs so same-named source records remain distinct.
  static Future<VyaparImportResult> importFromVyp(
    String vypPath, {
    Function(String)? onProgress,
  }) async {
    final vyaparDb = await openReadOnlyDatabase(vypPath);
    final invoisoDb = await DatabaseHelper().database;
    final warnings = <String>[];
    var customersImported = 0, customersSkipped = 0;
    var productsImported = 0, productsSkipped = 0;
    var invoicesImported = 0, invoicesSkipped = 0;
    var quotationsImported = 0, quotationsSkipped = 0;
    var purchaseOrdersImported = 0, purchaseOrdersSkipped = 0;
    var purchaseBillsImported = 0, purchaseBillsSkipped = 0;

    try {
      final tables = await _tables(vyaparDb);
      final nameColumns = await _columns(vyaparDb, tables, 'kb_names');
      final itemColumns = await _columns(vyaparDb, tables, 'kb_items');
      final transactionColumns =
          await _columns(vyaparDb, tables, 'kb_transactions');
      final lineItemColumns = await _columns(vyaparDb, tables, 'kb_lineitems');
      if (!tables.contains('kb_transactions')) {
        warnings.add(
            'Vyapar table kb_transactions is missing; no invoices imported.');
      } else if (!transactionColumns.containsAll({'txn_id', 'txn_type'})) {
        warnings.add(
            'Vyapar table kb_transactions is missing txn_id or txn_type; no invoices imported.');
      }

      final names = nameColumns.containsAll({'name_id', 'name_type'})
          ? await _rowsOrWarning(vyaparDb, tables, 'kb_names', warnings)
          : <Map<String, Object?>>[];
      if (tables.contains('kb_names') &&
          names.isEmpty &&
          !nameColumns.containsAll({'name_id', 'name_type'})) {
        warnings.add(
            'Vyapar table kb_names is missing name_id or name_type; customers were not imported.');
      }
      final items = itemColumns.contains('item_id')
          ? await _rowsOrWarning(vyaparDb, tables, 'kb_items', warnings)
          : <Map<String, Object?>>[];
      if (tables.contains('kb_items') &&
          items.isEmpty &&
          !itemColumns.contains('item_id')) {
        warnings.add(
            'Vyapar table kb_items is missing item_id; products were not imported.');
      }
      final taxRows =
          await _rowsOrWarning(vyaparDb, tables, 'kb_tax_code', warnings);
      final taxRates = <String, double>{
        for (final row in taxRows)
          if (_sourceId(row['tax_code_id']) != null)
            _sourceId(row['tax_code_id'])!: _number(row['tax_rate']) ?? 0,
      };

      if (tables.contains('kb_firms')) {
        onProgress?.call('Importing company info...');
        final firms = await vyaparDb.query('kb_firms', limit: 1);
        if (firms.isNotEmpty) {
          final firm = firms.first;
          await invoisoDb.update(
              'company_info',
              {
                'name': _text(firm['firm_name']),
                'phone': _text(firm['firm_phone']),
                'email': _text(firm['firm_email']),
                'gstin': _text(firm['firm_gstin_number']),
                'address': _text(firm['firm_address']),
                'pan_number': _text(firm['firm_tin_number']),
                'country': 'India',
              },
              where: 'id = 1');
        }
      } else {
        warnings.add(
            'Vyapar table kb_firms is missing; company info was not imported.');
      }

      onProgress?.call('Importing customers...');
      final customerIdBySourceId = <String, String>{};
      final customerBySourceId = <String, Map<String, Object?>>{};
      final vendorBySourceId = <String, Map<String, Object?>>{
        for (final row in names.where((row) => _integer(row['name_type']) == 2))
          if (_sourceId(row['name_id']) != null)
            _sourceId(row['name_id'])!: row,
      };
      for (final row in names.where((row) => _integer(row['name_type']) == 1)) {
        final sourceId = _sourceId(row['name_id']);
        final name = _text(row['full_name']).trim();
        if (sourceId == null || name.isEmpty) {
          customersSkipped++;
          warnings.add(
              'Customer skipped: missing ${sourceId == null ? 'name_id' : 'name'}.');
          continue;
        }
        final targetId = 'vy-customer-${_stableId(sourceId)}';
        customerIdBySourceId[sourceId] = targetId;
        customerBySourceId[sourceId] = row;
        if (await _exists(invoisoDb, 'customers', targetId)) {
          customersSkipped++;
          continue;
        }
        try {
          await invoisoDb.insert('customers', {
            'id': targetId,
            'name': name,
            'email': _text(row['email']),
            'phone': _text(row['phone_number']),
            'address': _text(row['address']),
            'gstin': _text(row['name_gstin_number']),
            'business_name': _text(row['party_billing_name']),
          });
          customersImported++;
        } catch (e) {
          customersSkipped++;
          warnings.add('Customer "$name" skipped: $e');
        }
      }

      onProgress?.call('Importing products...');
      final productIdBySourceId = <String, String>{};
      final productBySourceId = <String, Map<String, Object?>>{};
      for (final row in items.where((row) {
        final active = _integer(row['item_is_active']);
        return active == null || active == 1;
      })) {
        final sourceId = _sourceId(row['item_id']);
        final name = _text(row['item_name']).trim();
        if (sourceId == null || name.isEmpty) {
          productsSkipped++;
          warnings.add(
              'Product skipped: missing ${sourceId == null ? 'item_id' : 'item_name'}.');
          continue;
        }
        final targetId = 'vy-product-${_stableId(sourceId)}';
        productIdBySourceId[sourceId] = targetId;
        productBySourceId[sourceId] = row;
        if (await _exists(invoisoDb, 'products', targetId)) {
          productsSkipped++;
          continue;
        }
        try {
          final stock = _number(row['item_stock_quantity']) ?? 0;
          final taxRate = taxRates[_sourceId(row['item_tax_id'])] ?? 0;
          await invoisoDb.insert('products', {
            'id': targetId,
            'name': name,
            'description': _text(row['item_description']),
            'price': _number(row['item_sale_unit_price']) ?? 0,
            'stock': stock,
            'hsncode': _text(row['item_hsn_sac_code']),
            'tax_rate': taxRate,
            'type': _integer(row['item_type']) == 2 ? 'service' : 'product',
            'default_discount': _number(row['item_discount']) ?? 0,
            'purchase_price': _number(row['item_purchase_unit_price']) ?? 0,
            'unit': _text(row['item_unit']),
            'unlimited_stock': stock < 0 ? 1 : 0,
            'price_includes_tax': 0,
          });
          productsImported++;
        } catch (e) {
          productsSkipped++;
          warnings.add('Product "$name" skipped: $e');
        }
      }

      if (!tables.contains('kb_transactions') ||
          !transactionColumns.containsAll({'txn_id', 'txn_type'}) ||
          !tables.contains('kb_lineitems') ||
          !lineItemColumns.contains('lineitem_txn_id')) {
        if (!tables.contains('kb_lineitems')) {
          warnings.add(
              'Vyapar table kb_lineitems is missing; no invoices imported.');
        } else if (!lineItemColumns.contains('lineitem_txn_id')) {
          warnings.add(
              'Vyapar table kb_lineitems is missing lineitem_txn_id; no invoices imported.');
        }
        return _result(
            customersImported,
            customersSkipped,
            productsImported,
            productsSkipped,
            invoicesImported,
            invoicesSkipped,
            quotationsImported,
            quotationsSkipped,
            purchaseOrdersImported,
            purchaseOrdersSkipped,
            purchaseBillsImported,
            purchaseBillsSkipped,
            warnings);
      }

      onProgress?.call('Importing invoices...');
      final transactions = await vyaparDb.query('kb_transactions');
      final transactionBySourceId = <String, Map<String, Object?>>{
        for (final transaction in transactions)
          if (_sourceId(transaction['txn_id']) != null)
            _sourceId(transaction['txn_id'])!: transaction,
      };
      final paymentTypes = <String, String>{};
      if (tables.contains('kb_paymentTypes')) {
        for (final payment in await vyaparDb.query('kb_paymentTypes')) {
          final id = _sourceId(payment['paymentType_id']);
          if (id != null) paymentTypes[id] = _text(payment['paymentType_name']);
        }
      }
      final paymentsByTransactionId = <String, List<Map<String, Object?>>>{};
      final paymentMappingColumns =
          await _columns(vyaparDb, tables, 'txn_payment_mapping');
      if (paymentMappingColumns.containsAll({'txn_id', 'amount'})) {
        for (final payment in await vyaparDb.query('txn_payment_mapping')) {
          final transactionId = _sourceId(payment['txn_id']);
          if (transactionId != null) {
            paymentsByTransactionId
                .putIfAbsent(transactionId, () => [])
                .add(payment);
          }
        }
      }
      for (final txn in transactions) {
        final subType = _integer(txn['txn_sub_type']);
        if (_integer(txn['txn_type']) != 1 ||
            (subType != null && subType != 1)) {
          continue;
        }
        final sourceId = _sourceId(txn['txn_id']);
        if (sourceId == null) {
          invoicesSkipped++;
          warnings.add('Invoice skipped: missing txn_id.');
          continue;
        }
        final invoiceId = 'vy-invoice-${_stableId(sourceId)}';
        if (await _exists(invoisoDb, 'invoices', invoiceId)) {
          invoicesSkipped++;
          continue;
        }
        if (_integer(txn['txn_status']) == 0) {
          invoicesSkipped++;
          continue;
        }

        final sourceLines = await vyaparDb.query('kb_lineitems',
            where: 'lineitem_txn_id = ?', whereArgs: [txn['txn_id']]);
        final lines = <Map<String, Object?>>[];
        for (final line in sourceLines) {
          final product = productBySourceId[_sourceId(line['item_id'])];
          final quantity = _number(line['quantity']);
          final unitPrice = _number(line['priceperunit']);
          if (product == null ||
              quantity == null ||
              quantity <= 0 ||
              unitPrice == null ||
              unitPrice < 0) {
            warnings.add(
                'Invoice #$sourceId has an unusable line and it was ignored.');
            continue;
          }
          lines.add(line);
        }
        if (lines.isEmpty) {
          invoicesSkipped++;
          warnings
              .add('Invoice #$sourceId skipped: it has no usable line items.');
          continue;
        }

        final nameSourceId = _sourceId(txn['txn_name_id']);
        final customer =
            nameSourceId == null ? null : customerBySourceId[nameSourceId];
        final invoiceDate =
            DateTime.tryParse(_text(txn['txn_date'])) ?? DateTime.now();
        // Vyapar stores the amount received at sale time and the outstanding
        // balance separately; txn_cash_amount is not the invoice total.
        final paid = _number(txn['txn_cash_amount']) ?? 0;
        final balance = _number(txn['txn_balance_amount']) ?? 0;
        final paymentIsValid = paid >= 0 && balance >= 0;
        if (!paymentIsValid) {
          warnings.add(
              'Invoice #$sourceId has a malformed payment; no payment was imported.');
        }

        try {
          await invoisoDb.transaction((target) async {
            await target.insert('invoices', {
              'id': invoiceId,
              'invoice_number': _text(txn['txn_ref_number_char']),
              'customer_id': nameSourceId == null
                  ? ''
                  : customerIdBySourceId[nameSourceId] ?? '',
              'customer_name':
                  customer == null ? 'Walk-in' : _text(customer['full_name']),
              'customer_email':
                  customer == null ? '' : _text(customer['email']),
              'customer_phone':
                  customer == null ? '' : _text(customer['phone_number']),
              'customer_address':
                  customer == null ? '' : _text(customer['address']),
              'customer_gstin':
                  customer == null ? '' : _text(customer['name_gstin_number']),
              'customer_business_name':
                  customer == null ? '' : _text(customer['party_billing_name']),
              'date': invoiceDate.toIso8601String(),
              'notes': 'Imported from Vyapar',
              'tax_rate': 0,
              'type': 'Invoice',
              'currency_code': 'INR',
              'currency_symbol': '₹',
              'tax_mode': 'per_item',
              'is_interstate': 0,
            });
            for (var index = 0; index < lines.length; index++) {
              final line = lines[index];
              final sourceProductId = _sourceId(line['item_id'])!;
              final product = productBySourceId[sourceProductId]!;
              final quantity = _number(line['quantity'])!;
              final unitPrice = _number(line['priceperunit'])!;
              final taxAmount = _number(line['lineitem_tax_amount']) ?? 0;
              final taxRate = quantity * unitPrice == 0
                  ? 0
                  : (taxAmount / (quantity * unitPrice) * 100);
              await target.insert('invoice_items', {
                'id': 'vy-line-${_stableId('$sourceId-$index')}',
                'invoice_id': invoiceId,
                'product_id': productIdBySourceId[sourceProductId] ?? '',
                'product_name': _text(product['item_name']),
                'product_description': _text(product['item_description']),
                'product_price': _number(product['item_sale_unit_price']) ?? 0,
                'product_tax_rate': taxRate,
                'product_hsn_code': _text(product['item_hsn_sac_code']),
                'quantity': quantity,
                'discount': _number(line['lineitem_discount_amount']) ?? 0,
                'unit_price': unitPrice,
                'extra_cost': 0,
                'is_product_saved':
                    productIdBySourceId.containsKey(sourceProductId) ? 1 : 0,
                'product_type':
                    _integer(product['item_type']) == 2 ? 'service' : 'product',
                'product_purchase_price':
                    _number(product['item_purchase_unit_price']) ?? 0,
                'product_unit': _text(product['item_unit']),
                'description': _text(line['lineitem_description']),
              });
            }
            if (paymentIsValid && paid > 0) {
              await target.insert('invoice_payments', {
                'id': 'vy-payment-${_stableId(sourceId)}',
                'invoice_id': invoiceId,
                'invoice_number': _text(txn['txn_ref_number_char']),
                'receipt_number': 'VYP-$sourceId',
                'amount_paid': paid,
                'tax_amount_paid': 0,
                'previously_paid': 0,
                'balance_after': balance,
                'date_paid': invoiceDate.toIso8601String(),
                'payment_method': _paymentMethod(
                    paymentsByTransactionId[sourceId], paymentTypes),
                'notes': 'Imported from Vyapar backup',
              });
            }
          });
          invoicesImported++;
        } catch (e) {
          invoicesSkipped++;
          warnings.add('Invoice #$sourceId skipped: $e');
        }
      }
      onProgress?.call('Importing quotations...');
      for (final txn
          in transactions.where((txn) => _integer(txn['txn_type']) == 27)) {
        final sourceId = _sourceId(txn['txn_id']);
        final quotationId =
            sourceId == null ? null : 'vy-quotation-${_stableId(sourceId)}';
        if (sourceId == null || _integer(txn['txn_status']) == 0) {
          quotationsSkipped++;
          continue;
        }
        if (await _exists(invoisoDb, 'invoices', quotationId!)) {
          quotationsSkipped++;
          continue;
        }
        final lines = await _usableLines(
            vyaparDb, txn, productBySourceId, warnings, 'Quotation', sourceId);
        if (lines.isEmpty) {
          quotationsSkipped++;
          continue;
        }
        final nameSourceId = _sourceId(txn['txn_name_id']);
        final customer =
            nameSourceId == null ? null : customerBySourceId[nameSourceId];
        final date = _transactionDate(txn);
        try {
          await invoisoDb.transaction((target) async {
            await target.insert('invoices', {
              'id': quotationId,
              'invoice_number': _text(txn['txn_ref_number_char']),
              'customer_id': nameSourceId == null
                  ? ''
                  : customerIdBySourceId[nameSourceId] ?? '',
              'customer_name':
                  customer == null ? 'Walk-in' : _text(customer['full_name']),
              'customer_email':
                  customer == null ? '' : _text(customer['email']),
              'customer_phone':
                  customer == null ? '' : _text(customer['phone_number']),
              'customer_address':
                  customer == null ? '' : _text(customer['address']),
              'customer_gstin':
                  customer == null ? '' : _text(customer['name_gstin_number']),
              'customer_business_name':
                  customer == null ? '' : _text(customer['party_billing_name']),
              'date': date.toIso8601String(),
              'notes': 'Imported from Vyapar',
              'tax_rate': 0,
              'type': 'Quotation',
              'currency_code': 'INR',
              'currency_symbol': '₹',
              'tax_mode': 'per_item',
              'is_interstate': 0,
            });
            await _insertInvoiceLines(target, quotationId, sourceId, lines,
                productBySourceId, productIdBySourceId);
          });
          quotationsImported++;
        } catch (e) {
          quotationsSkipped++;
          warnings.add('Quotation #$sourceId skipped: $e');
        }
      }

      onProgress?.call('Importing purchase orders...');
      for (final txn in transactions.where((txn) =>
          _integer(txn['txn_type']) == 28 &&
          _integer(txn['txn_sub_type']) == 1)) {
        final sourceId = _sourceId(txn['txn_id']);
        final orderId = sourceId == null
            ? null
            : 'vy-purchase-order-${_stableId(sourceId)}';
        if (sourceId == null || _integer(txn['txn_status']) == 0) {
          purchaseOrdersSkipped++;
          continue;
        }
        if (await _exists(invoisoDb, 'purchase_orders', orderId!)) {
          purchaseOrdersSkipped++;
          continue;
        }
        final lines = await _usableLines(vyaparDb, txn, productBySourceId,
            warnings, 'Purchase order', sourceId);
        if (lines.isEmpty) {
          purchaseOrdersSkipped++;
          continue;
        }
        final vendor = vendorBySourceId[_sourceId(txn['txn_name_id'])];
        final date = _transactionDate(txn);
        try {
          await invoisoDb.transaction((target) async {
            await target.insert('purchase_orders', {
              'id': orderId,
              'order_number': _text(txn['txn_ref_number_char']),
              'vendor_name':
                  vendor == null ? 'Walk-in' : _text(vendor['full_name']),
              'vendor_phone':
                  vendor == null ? '' : _text(vendor['phone_number']),
              'vendor_email': vendor == null ? '' : _text(vendor['email']),
              'vendor_address': vendor == null ? '' : _text(vendor['address']),
              'date': date.toIso8601String(),
              'expected_date': _dueDate(txn)?.toIso8601String(),
              'status': 'draft',
              'total_amount': _lineTotal(lines),
              'amount_paid': _number(txn['txn_cash_amount']) ?? 0,
              'notes': 'Imported from Vyapar',
              'currency_code': 'INR',
              'currency_symbol': '₹',
            });
            await _insertPurchaseOrderLines(target, orderId, sourceId, lines,
                productBySourceId, productIdBySourceId);
          });
          purchaseOrdersImported++;
        } catch (e) {
          purchaseOrdersSkipped++;
          warnings.add('Purchase order #$sourceId skipped: $e');
        }
      }

      onProgress?.call('Importing purchase bills...');
      for (final txn in transactions.where((txn) =>
          _integer(txn['txn_type']) == 2 &&
          _integer(txn['txn_sub_type']) == 4)) {
        final sourceId = _sourceId(txn['txn_id']);
        final billId =
            sourceId == null ? null : 'vy-purchase-bill-${_stableId(sourceId)}';
        if (sourceId == null || _integer(txn['txn_status']) == 0) {
          purchaseBillsSkipped++;
          continue;
        }
        if (await _exists(invoisoDb, 'purchase_bills', billId!)) {
          purchaseBillsSkipped++;
          continue;
        }
        final lines = await _usableLines(vyaparDb, txn, productBySourceId,
            warnings, 'Purchase bill', sourceId);
        if (lines.isEmpty) {
          purchaseBillsSkipped++;
          continue;
        }
        final vendor = vendorBySourceId[_sourceId(txn['txn_name_id'])];
        final date = _transactionDate(txn);
        final totalTax = lines.fold<double>(0,
            (sum, line) => sum + (_number(line['lineitem_tax_amount']) ?? 0));
        final paid = _number(txn['txn_cash_amount']) ?? 0;
        final balance = _number(txn['txn_balance_amount']) ?? 0;
        final paymentIsValid = paid >= 0 && balance >= 0;
        if (!paymentIsValid) {
          warnings.add(
              'Purchase bill #$sourceId has a malformed payment; no payment was imported.');
        }
        try {
          await invoisoDb.transaction((target) async {
            await target.insert('purchase_bills', {
              'id': billId,
              'bill_number': _text(txn['txn_ref_number_char']),
              'supplier_name':
                  vendor == null ? 'Walk-in' : _text(vendor['full_name']),
              'supplier_gstin':
                  vendor == null ? '' : _text(vendor['name_gstin_number']),
              'supplier_phone':
                  vendor == null ? '' : _text(vendor['phone_number']),
              'supplier_email': vendor == null ? '' : _text(vendor['email']),
              'supplier_address':
                  vendor == null ? '' : _text(vendor['address']),
              'date': date.toIso8601String(),
              'due_date': _dueDate(txn)?.toIso8601String(),
              'total_amount': _lineTotal(lines),
              'total_tax': totalTax,
              'amount_paid': _number(txn['txn_cash_amount']) ?? 0,
              'itc_eligible': _integer(txn['txn_itc_applicable']) == 0 ? 0 : 1,
              'reverse_charge': _integer(txn['txn_reverse_charge']) ?? 0,
              'notes': _text(txn['txn_description']),
              'currency_code': 'INR',
              'currency_symbol': '₹',
            });
            await _insertPurchaseBillLines(target, billId, sourceId, lines,
                productBySourceId, productIdBySourceId);
            if (paymentIsValid && paid > 0) {
              await target.insert('purchase_bill_payments', {
                'id': 'vy-purchase-payment-${_stableId(sourceId)}',
                'purchase_bill_id': billId,
                'amount_paid': paid,
                'previously_paid': 0,
                'balance_after': balance,
                'date_paid': date.toIso8601String(),
                'payment_method': _paymentMethod(
                    paymentsByTransactionId[sourceId], paymentTypes),
                'notes': 'Imported from Vyapar backup',
              });
            }
          });
          purchaseBillsImported++;
        } catch (e) {
          purchaseBillsSkipped++;
          warnings.add('Purchase bill #$sourceId skipped: $e');
        }
      }
      final linkColumns = await _columns(vyaparDb, tables, 'kb_txn_links');
      if (linkColumns.containsAll({
        'txn_links_id',
        'txn_links_txn_1_id',
        'txn_links_txn_2_id',
        'txn_links_amount'
      })) {
        onProgress?.call('Importing linked receipts...');
        for (final link in await vyaparDb.query('kb_txn_links')) {
          final firstId = _sourceId(link['txn_links_txn_1_id']);
          final secondId = _sourceId(link['txn_links_txn_2_id']);
          final first = firstId == null ? null : transactionBySourceId[firstId];
          final second =
              secondId == null ? null : transactionBySourceId[secondId];
          final sale = _integer(first?['txn_type']) == 1 ? first : second;
          final receipt = _integer(first?['txn_type']) == 3 ? first : second;
          final saleId = _sourceId(sale?['txn_id']);
          final receiptId = _sourceId(receipt?['txn_id']);
          final linkId = _sourceId(link['txn_links_id']);
          final amount = _number(link['txn_links_amount']);
          if (saleId == null ||
              receiptId == null ||
              linkId == null ||
              amount == null ||
              amount <= 0) {
            continue;
          }
          final invoiceId = 'vy-invoice-${_stableId(saleId)}';
          final paymentId = 'vy-linked-payment-${_stableId(linkId)}';
          if (!await _exists(invoisoDb, 'invoices', invoiceId) ||
              await _exists(invoisoDb, 'invoice_payments', paymentId)) {
            continue;
          }
          final previouslyPaidResult = await invoisoDb.rawQuery(
              'SELECT COALESCE(SUM(amount_paid), 0) AS total FROM invoice_payments WHERE invoice_id = ?',
              [invoiceId]);
          final previouslyPaid =
              _number(previouslyPaidResult.first['total']) ?? 0;
          final originalBalance = _number(sale?['txn_balance_amount']) ?? 0;
          final priorLinkedResult = await invoisoDb.rawQuery(
              '''SELECT COALESCE(SUM(p.amount_paid), 0) AS total
                     FROM invoice_payments p
                     WHERE p.invoice_id = ? AND p.id LIKE 'vy-linked-payment-%' ''',
              [invoiceId]);
          final priorLinked = _number(priorLinkedResult.first['total']) ?? 0;
          final receiptDate =
              DateTime.tryParse(_text(receipt?['txn_date'])) ?? DateTime.now();
          await invoisoDb.insert('invoice_payments', {
            'id': paymentId,
            'invoice_id': invoiceId,
            'invoice_number': _text(sale?['txn_ref_number_char']),
            'receipt_number': 'VYP-R-$receiptId',
            'amount_paid': amount,
            'tax_amount_paid': 0,
            'previously_paid': previouslyPaid,
            'balance_after': (originalBalance - priorLinked - amount)
                .clamp(0, double.infinity),
            'date_paid': receiptDate.toIso8601String(),
            'payment_method': _paymentMethod(
                paymentsByTransactionId[receiptId], paymentTypes),
            'notes': 'Imported linked receipt from Vyapar backup',
          });
        }
      }
      return _result(
          customersImported,
          customersSkipped,
          productsImported,
          productsSkipped,
          invoicesImported,
          invoicesSkipped,
          quotationsImported,
          quotationsSkipped,
          purchaseOrdersImported,
          purchaseOrdersSkipped,
          purchaseBillsImported,
          purchaseBillsSkipped,
          warnings);
    } finally {
      await vyaparDb.close();
    }
  }

  static VyaparImportResult _result(
          int customersImported,
          int customersSkipped,
          int productsImported,
          int productsSkipped,
          int invoicesImported,
          int invoicesSkipped,
          int quotationsImported,
          int quotationsSkipped,
          int purchaseOrdersImported,
          int purchaseOrdersSkipped,
          int purchaseBillsImported,
          int purchaseBillsSkipped,
          List<String> warnings) =>
      VyaparImportResult(
        customersImported: customersImported,
        customersSkipped: customersSkipped,
        productsImported: productsImported,
        productsSkipped: productsSkipped,
        invoicesImported: invoicesImported,
        invoicesSkipped: invoicesSkipped,
        quotationsImported: quotationsImported,
        quotationsSkipped: quotationsSkipped,
        purchaseOrdersImported: purchaseOrdersImported,
        purchaseOrdersSkipped: purchaseOrdersSkipped,
        purchaseBillsImported: purchaseBillsImported,
        purchaseBillsSkipped: purchaseBillsSkipped,
        warnings: warnings,
      );

  static Future<List<Map<String, Object?>>> _usableLines(
      Database db,
      Map<String, Object?> transaction,
      Map<String, Map<String, Object?>> productBySourceId,
      List<String> warnings,
      String documentType,
      String sourceId) async {
    final sourceLines = await db.query('kb_lineitems',
        where: 'lineitem_txn_id = ?', whereArgs: [transaction['txn_id']]);
    final lines = <Map<String, Object?>>[];
    for (final line in sourceLines) {
      final product = productBySourceId[_sourceId(line['item_id'])];
      final quantity = _number(line['quantity']);
      final unitPrice = _number(line['priceperunit']);
      if (product == null ||
          quantity == null ||
          quantity <= 0 ||
          unitPrice == null ||
          unitPrice < 0) {
        warnings.add(
            '$documentType #$sourceId has an unusable line and it was ignored.');
        continue;
      }
      lines.add(line);
    }
    if (lines.isEmpty) {
      warnings.add(
          '$documentType #$sourceId skipped: it has no usable line items.');
    }
    return lines;
  }

  static Future<void> _insertInvoiceLines(
      DatabaseExecutor target,
      String invoiceId,
      String sourceId,
      List<Map<String, Object?>> lines,
      Map<String, Map<String, Object?>> productBySourceId,
      Map<String, String> productIdBySourceId) async {
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final sourceProductId = _sourceId(line['item_id'])!;
      final product = productBySourceId[sourceProductId]!;
      final quantity = _number(line['quantity'])!;
      final unitPrice = _number(line['priceperunit'])!;
      final taxAmount = _number(line['lineitem_tax_amount']) ?? 0;
      final taxRate = quantity * unitPrice == 0
          ? 0
          : taxAmount / (quantity * unitPrice) * 100;
      await target.insert('invoice_items', {
        'id': 'vy-quotation-line-${_stableId('$sourceId-$index')}',
        'invoice_id': invoiceId,
        'product_id': productIdBySourceId[sourceProductId] ?? '',
        'product_name': _text(product['item_name']),
        'product_description': _text(product['item_description']),
        'product_price': _number(product['item_sale_unit_price']) ?? 0,
        'product_tax_rate': taxRate,
        'product_hsn_code': _text(product['item_hsn_sac_code']),
        'quantity': quantity,
        'discount': _number(line['lineitem_discount_amount']) ?? 0,
        'unit_price': unitPrice,
        'extra_cost': 0,
        'is_product_saved':
            productIdBySourceId.containsKey(sourceProductId) ? 1 : 0,
        'product_type':
            _integer(product['item_type']) == 2 ? 'service' : 'product',
        'product_purchase_price':
            _number(product['item_purchase_unit_price']) ?? 0,
        'product_unit': _text(product['item_unit']),
        'description': _text(line['lineitem_description']),
      });
    }
  }

  static Future<void> _insertPurchaseOrderLines(
      DatabaseExecutor target,
      String orderId,
      String sourceId,
      List<Map<String, Object?>> lines,
      Map<String, Map<String, Object?>> productBySourceId,
      Map<String, String> productIdBySourceId) async {
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final productId = _sourceId(line['item_id'])!;
      final product = productBySourceId[productId]!;
      final quantity = _number(line['quantity'])!;
      final rate = _number(line['priceperunit'])!;
      final tax = _number(line['lineitem_tax_amount']) ?? 0;
      await target.insert('purchase_order_items', {
        'id': 'vy-purchase-order-line-${_stableId('$sourceId-$index')}',
        'purchase_order_id': orderId,
        'product_id': productIdBySourceId[productId] ?? '',
        'product_name': _text(product['item_name']),
        'quantity': quantity,
        'price_per_unit': rate,
        'tax_rate': quantity * rate == 0 ? 0 : tax / (quantity * rate) * 100,
        'discount': _number(line['lineitem_discount_amount']) ?? 0,
        'description': _text(line['lineitem_description']),
      });
    }
  }

  static Future<void> _insertPurchaseBillLines(
      DatabaseExecutor target,
      String billId,
      String sourceId,
      List<Map<String, Object?>> lines,
      Map<String, Map<String, Object?>> productBySourceId,
      Map<String, String> productIdBySourceId) async {
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final sourceProductId = _sourceId(line['item_id'])!;
      final product = productBySourceId[sourceProductId]!;
      final quantity = _number(line['quantity'])!;
      final rate = _number(line['priceperunit'])!;
      final discount = _number(line['lineitem_discount_amount']) ?? 0;
      final taxable =
          (quantity * rate - discount).clamp(0, double.infinity).toDouble();
      final tax = _number(line['lineitem_tax_amount']) ?? 0;
      final taxRate = taxable == 0 ? 0 : tax / taxable * 100;
      await target.insert('purchase_bill_items', {
        'id': 'vy-purchase-bill-line-${_stableId('$sourceId-$index')}',
        'purchase_bill_id': billId,
        'product_id': productIdBySourceId[sourceProductId],
        'product_name': _text(product['item_name']),
        'hsn_code': _text(product['item_hsn_sac_code']),
        'quantity': quantity,
        'unit': _text(product['item_unit']),
        'rate': rate,
        'tax_rate': taxRate,
        'discount': discount,
        'taxable_value': taxable,
        'igst': 0,
        'cgst': tax / 2,
        'sgst': tax / 2,
        'amount': taxable + tax,
      });
    }
  }

  static double _lineTotal(List<Map<String, Object?>> lines) => lines.fold(
      0,
      (sum, line) =>
          sum +
          (_number(line['total_amount']) ??
              ((_number(line['quantity']) ?? 0) *
                      (_number(line['priceperunit']) ?? 0) -
                  (_number(line['lineitem_discount_amount']) ?? 0) +
                  (_number(line['lineitem_tax_amount']) ?? 0))));

  static DateTime _transactionDate(Map<String, Object?> transaction) =>
      DateTime.tryParse(_text(transaction['txn_date'])) ?? DateTime.now();

  static DateTime? _dueDate(Map<String, Object?> transaction) =>
      DateTime.tryParse(_text(transaction['txn_due_date']));

  static Future<Set<String>> _tables(Database db) async =>
      (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
          .map((row) => _text(row['name']))
          .toSet();

  static Future<Set<String>> _columns(
      Database db, Set<String> tables, String table) async {
    if (!tables.contains(table)) return const {};
    return (await db.rawQuery('PRAGMA table_info($table)'))
        .map((row) => _text(row['name']))
        .toSet();
  }

  static Future<List<Map<String, Object?>>> _rowsOrWarning(Database db,
      Set<String> tables, String table, List<String> warnings) async {
    if (!tables.contains(table)) {
      warnings.add(
          'Vyapar table $table is missing; related data was not imported.');
      return const [];
    }
    return db.query(table);
  }

  static Future<bool> _exists(Database db, String table, String id) async =>
      (await db.query(table,
              columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1))
          .isNotEmpty;

  static String _paymentMethod(
      List<Map<String, Object?>>? payments, Map<String, String> paymentTypes) {
    if (payments == null) return 'Imported';
    final methods = payments
        .map((payment) => paymentTypes[_sourceId(payment['payment_id'])])
        .whereType<String>()
        .where((method) => method.isNotEmpty)
        .toSet();
    return methods.isEmpty ? 'Imported' : methods.join(', ');
  }

  static String _text(Object? value) => value?.toString() ?? '';
  static String? _sourceId(Object? value) {
    final id = _text(value).trim();
    return id.isEmpty ? null : id;
  }

  static double? _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse(_text(value));
  static int? _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse(_text(value));

  /// Generate a stable numeric ID from a string using a short hash.
  static int _stableId(String input) {
    final digest = sha1.convert(utf8.encode(input));
    var id = 0;
    for (var i = 0; i < 8 && i < digest.bytes.length; i++) {
      id = (id << 8) | digest.bytes[i];
    }
    return id & 0x7FFFFFFF;
  }

  static Future<int> _count(Database db, String table, String? where) async {
    final result = await db.rawQuery(
        'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}

/// Preview data from a Vyapar backup before importing.
class VyaparPreview {
  final int customerCount;
  final int vendorCount;
  final int productCount;
  final int invoiceCount;
  final String firmName;

  const VyaparPreview({
    required this.customerCount,
    required this.vendorCount,
    required this.productCount,
    required this.invoiceCount,
    required this.firmName,
  });
}
