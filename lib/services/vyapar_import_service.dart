import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/invoice_payment.dart';
import 'package:apexbooks/common/common.dart';

/// Result of a Vyapar import operation.
class VyaparImportResult {
  final int customersImported;
  final int customersSkipped;
  final int productsImported;
  final int productsSkipped;
  final int invoicesImported;
  final int invoicesSkipped;
  final List<String> warnings;

  const VyaparImportResult({
    required this.customersImported,
    required this.customersSkipped,
    required this.productsImported,
    required this.productsSkipped,
    required this.invoicesImported,
    required this.invoicesSkipped,
    this.warnings = const [],
  });

  @override
  String toString() =>
      'Imported: $customersImported customers, $productsImported products, $invoicesImported invoices. '
      'Skipped: $customersSkipped customers, $productsSkipped products, $invoicesSkipped invoices. '
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
        final output = File(outPath);
        await output.writeAsBytes(file.content as List<int>);
        return outPath;
      }
    }
    throw Exception('No .vyp file found inside the .vyb archive');
  }

  /// Extract metadata from the Vyapar database to preview before importing.
  static Future<VyaparPreview> preview(String vypPath) async {
    final db = await openReadOnlyDatabase(vypPath);
    try {
      final customerCount = await _count(db, 'kb_names', 'name_type = 1');
      final vendorCount = await _count(db, 'kb_names', 'name_type = 2');
      final productCount = await _count(
          db, 'kb_items', 'item_is_active = 1 OR item_is_active IS NULL');
      final txnCount = await _count(db, 'kb_transactions', 'txn_type = 1');
      final firmCount = await _count(db, 'kb_firms', null);

      String firmName = '';
      if (firmCount > 0) {
        final firm = await db.query('kb_firms', limit: 1);
        if (firm.isNotEmpty)
          firmName = firm.first['firm_name']?.toString() ?? '';
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

  /// Perform the full import from a Vyapar .vyp SQLite database.
  static Future<VyaparImportResult> importFromVyp(
    String vypPath, {
    Function(String)? onProgress,
  }) async {
    final vyaparDb = await openReadOnlyDatabase(vypPath);
    final invoisoDb = await DatabaseHelper().database;
    final warnings = <String>[];

    int customersImported = 0, customersSkipped = 0;
    int productsImported = 0, productsSkipped = 0;
    int invoicesImported = 0, invoicesSkipped = 0;

    try {
      // ── 1. Import Company Info (first firm) ──
      onProgress?.call('Importing company info...');
      final firms = await vyaparDb.query('kb_firms', limit: 1);
      if (firms.isNotEmpty) {
        final firm = firms.first;
        await invoisoDb.update(
            'company_info',
            {
              'name': firm['firm_name'] ?? '',
              'phone': firm['firm_phone'] ?? '',
              'email': firm['firm_email'] ?? '',
              'gstin': firm['firm_gstin_number'] ?? '',
              'address': firm['firm_address'] ?? '',
              'pan_number': firm['firm_tin_number'] ?? '',
              'country': 'India',
            },
            where: 'id = 1');
      }

      // ── 2. Import Customers (name_type = 1) ──
      onProgress?.call('Importing customers...');
      final customers =
          await vyaparDb.query('kb_names', where: 'name_type = 1');
      for (final row in customers) {
        try {
          final phone = row['phone_number']?.toString() ?? '';
          final email = row['email']?.toString() ?? '';
          final name = row['full_name']?.toString() ?? '';

          if (name.trim().isEmpty) {
            customersSkipped++;
            continue;
          }

          // Check for duplicates
          final existing = await invoisoDb.query('customers',
              where: 'LOWER(name) = ?',
              whereArgs: [name.trim().toLowerCase()],
              limit: 1);
          if (existing.isNotEmpty) {
            customersSkipped++;
            continue;
          }

          final id = 'vy-${_stableId(name + phone)}';
          await invoisoDb.insert('customers', {
            'id': id,
            'name': name.trim(),
            'email': email,
            'phone': phone,
            'address': row['address']?.toString() ?? '',
            'gstin': row['name_gstin_number']?.toString() ?? '',
            'business_name': row['party_billing_name']?.toString() ?? '',
          });
          customersImported++;
        } catch (e) {
          customersSkipped++;
          warnings.add('Customer "${row['full_name']}" skipped: $e');
        }
      }

      // ── 3. Import Products ──
      onProgress?.call('Importing products...');
      final products = await vyaparDb.query('kb_items',
          where: '(item_is_active = 1 OR item_is_active IS NULL)');
      for (final row in products) {
        try {
          final name = row['item_name']?.toString() ?? '';
          if (name.trim().isEmpty) {
            productsSkipped++;
            continue;
          }

          final existing = await invoisoDb.query('products',
              where: 'LOWER(name) = ?',
              whereArgs: [name.trim().toLowerCase()],
              limit: 1);
          if (existing.isNotEmpty) {
            productsSkipped++;
            continue;
          }

          final salePrice =
              (row['item_sale_unit_price'] as num?)?.toDouble() ?? 0.0;
          final purchasePrice =
              (row['item_purchase_unit_price'] as num?)?.toDouble() ?? 0.0;
          final stock = (row['item_stock_quantity'] as num?)?.toDouble() ?? 0;
          final hsncode = row['item_hsn_sac_code']?.toString() ?? '';
          final description = row['item_description']?.toString() ?? '';
          final mrp = (row['item_mrp'] as num?)?.toDouble();
          final wholesalePrice =
              (row['item_wholesale_price'] as num?)?.toDouble();

          // Determine tax rate from tax_id mapping
          double taxRate = 0;
          final taxId = row['item_tax_id'] as int?;
          if (taxId != null) {
            final taxRows = await vyaparDb.query('kb_tax_code',
                where: 'tax_code_id = ?', whereArgs: [taxId]);
            if (taxRows.isNotEmpty) {
              taxRate = (taxRows.first['tax_rate'] as num?)?.toDouble() ?? 0;
            }
          }

          // Map item type
          String type = 'product';
          final itemType = row['item_type'] as int?;
          if (itemType == 2) type = 'service';

          final id = 'vy-${_stableId(name + hsncode)}';
          await invoisoDb.insert('products', {
            'id': id,
            'name': name.trim(),
            'description': description,
            'price': salePrice,
            'stock': stock.toInt(),
            'hsncode': hsncode,
            'tax_rate': taxRate.toInt(),
            'type': type,
            'default_discount': (row['item_discount'] as num?)?.toDouble() ?? 0,
            'purchase_price': purchasePrice,
            'unit': '',
            'unlimited_stock': stock < 0 ? 1 : 0,
            'price_includes_tax': 0,
          });
          productsImported++;
        } catch (e) {
          productsSkipped++;
          warnings.add('Product "${row['item_name']}" skipped: $e');
        }
      }

      // ── 4. Import Invoices (txn_type = 1 = Sale) ──
      onProgress?.call('Importing invoices...');
      final transactions = await vyaparDb.query('kb_transactions',
          where: 'txn_type = 1', orderBy: 'txn_date ASC');

      // Build name_id → customer_id mapping
      final nameIdToCustomerId = <int, String>{};
      final customerRows = await invoisoDb.query('customers');
      // Re-read vyapar names to build mapping
      final vyaparNames = await vyaparDb.query('kb_names');
      for (final vn in vyaparNames) {
        final nid = vn['name_id'] as int;
        final vname = vn['full_name']?.toString() ?? '';
        // Find matching invoiso customer
        for (final cr in customerRows) {
          if ((cr['name']?.toString() ?? '').toLowerCase() ==
              vname.toLowerCase()) {
            nameIdToCustomerId[nid] = cr['id'] as String;
            break;
          }
        }
      }

      for (final txn in transactions) {
        try {
          final txnId = txn['txn_id'] as int;
          final nameId = txn['txn_name_id'] as int?;
          final txnDate =
              txn['txn_date']?.toString() ?? DateTime.now().toIso8601String();
          final totalAmount = (txn['txn_cash_amount'] as num?)?.toDouble() ?? 0;
          final balanceAmount =
              (txn['txn_balance_amount'] as num?)?.toDouble() ?? 0;
          final paidAmount = totalAmount - balanceAmount;
          final status = txn['txn_status'] as int?;
          final paymentStatus = txn['txn_payment_status'] as int?;

          // Skip cancelled (status = 0)
          if (status == 0) {
            invoicesSkipped++;
            continue;
          }

          // Look up customer
          String customerId = '';
          String customerName = 'Walk-in';
          if (nameId != null && nameIdToCustomerId.containsKey(nameId)) {
            customerId = nameIdToCustomerId[nameId]!;
            // Fetch customer name from invoiso DB
            final custRow = await invoisoDb.query('customers',
                where: 'id = ?', whereArgs: [customerId], limit: 1);
            if (custRow.isNotEmpty) {
              customerName = custRow.first['name']?.toString() ?? 'Walk-in';
            }
          } else if (nameId != null) {
            // Try to find by vyapar name
            final vyName = vyaparNames
                .where((n) => n['name_id'] == nameId)
                .map((n) => n['full_name']?.toString() ?? '')
                .firstOrNull;
            if (vyName != null && vyName.isNotEmpty) {
              customerName = vyName;
            }
          }

          final invoiceId = 'vy-inv-$txnId';
          final invoiceDate = DateTime.tryParse(txnDate) ?? DateTime.now();
          final prefix = txn['txn_invoice_prefix']?.toString() ?? '';
          final refNum = txn['txn_ref_number_char']?.toString();

          // Determine invoice type based on status
          String type = 'Invoice';
          if (paymentStatus == 3) {
            // Fully paid → could be Receipt
          }

          final invoice = Invoice(
            id: invoiceId,
            invoiceNumber: refNum,
            customer: Customer(
              id: customerId,
              name: customerName,
              email: '',
              phone: '',
              address: '',
              gstin: '',
            ),
            items: [],
            date: invoiceDate,
            type: type,
            taxRate: 0,
            currencyCode: 'INR',
            currencySymbol: '₹',
            taxMode: TaxMode.perItem,
          );

          // Insert invoice
          await invoisoDb.insert('invoices', {
            'id': invoiceId,
            'invoice_number': refNum,
            'customer_id': customerId,
            'customer_name': customerName,
            'customer_email': '',
            'customer_phone': '',
            'customer_address': '',
            'customer_gstin': '',
            'customer_business_name': '',
            'date': invoiceDate.toIso8601String(),
            'notes': 'Imported from Vyapar',
            'tax_rate': 0,
            'type': type,
            'currency_code': 'INR',
            'currency_symbol': '₹',
            'tax_mode': 'per_item',
            'is_interstate': 0,
          });
          invoicesImported++;

          // Insert line items
          final lineItems = await vyaparDb.query('kb_lineitems',
              where: 'lineitem_txn_id = ?', whereArgs: [txnId]);
          for (final li in lineItems) {
            final liItemId = li['item_id'] as int?;
            final qty = (li['quantity'] as num?)?.toDouble() ?? 1;
            final ppu = (li['priceperunit'] as num?)?.toDouble() ?? 0;
            final liDiscount =
                (li['lineitem_discount_amount'] as num?)?.toDouble() ?? 0;
            final liTaxAmount =
                (li['lineitem_tax_amount'] as num?)?.toDouble() ?? 0;
            final liDesc = li['lineitem_description']?.toString() ?? '';

            // Try to find matching product
            String productId = '';
            String productName = '';
            if (liItemId != null) {
              final prodRows = await vyaparDb.query('kb_items',
                  where: 'item_id = ?', whereArgs: [liItemId], limit: 1);
              if (prodRows.isNotEmpty) {
                productName = prodRows.first['item_name']?.toString() ?? '';
                // Find matching invoiso product
                final invProd = await invoisoDb.query('products',
                    where: 'LOWER(name) = ?',
                    whereArgs: [productName.toLowerCase()],
                    limit: 1);
                if (invProd.isNotEmpty) {
                  productId = invProd.first['id']?.toString() ?? '';
                }
              }
            }

            final taxRatePct = qty > 0 && ppu > 0
                ? ((liTaxAmount / (qty * ppu)) * 100).round()
                : 0;

            await invoisoDb.insert('invoice_items', {
              'id': 'vy-li-${_stableId("$txnId-$liItemId-$qty")}',
              'invoice_id': invoiceId,
              'product_id': productId,
              'product_name': productName,
              'product_description': liDesc,
              'product_price': ppu,
              'product_tax_rate': taxRatePct,
              'product_hsn_code': '',
              'quantity': qty,
              'discount': liDiscount,
              'unit_price': ppu,
              'extra_cost': 0,
              'is_product_saved': productId.isNotEmpty ? 1 : 0,
              'product_type': 'product',
              'product_purchase_price': 0,
              'product_unit': '',
              'description': liDesc,
            });
          }

          // Insert payment records if paid
          if (paidAmount > 0) {
            await invoisoDb.insert('invoice_payments', {
              'id': 'vy-pay-$txnId',
              'invoice_id': invoiceId,
              'invoice_number': refNum ?? '',
              'receipt_number': 'VYP-$txnId',
              'amount_paid': paidAmount,
              'tax_amount_paid': 0,
              'previously_paid': 0,
              'balance_after': balanceAmount,
              'date_paid': invoiceDate.toIso8601String(),
              'payment_method': 'Imported',
              'notes': 'Imported from Vyapar backup',
            });
          }
        } catch (e) {
          invoicesSkipped++;
          warnings.add('Invoice #${txn['txn_id']} skipped: $e');
        }
      }

      return VyaparImportResult(
        customersImported: customersImported,
        customersSkipped: customersSkipped,
        productsImported: productsImported,
        productsSkipped: productsSkipped,
        invoicesImported: invoicesImported,
        invoicesSkipped: invoicesSkipped,
        warnings: warnings,
      );
    } finally {
      await vyaparDb.close();
    }
  }

  /// Generate a stable numeric ID from a string using a short hash.
  static int _stableId(String input) {
    final bytes = utf8.encode(input);
    final digest = sha1.convert(bytes);
    // Use first 8 bytes as a positive integer
    int id = 0;
    for (int i = 0; i < 8 && i < digest.bytes.length; i++) {
      id = (id << 8) | digest.bytes[i];
    }
    return id & 0x7FFFFFFF; // ensure positive
  }

  static Future<int> _count(Database db, String table, String? where) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM $table${where != null ? ' WHERE $where' : ''}',
    );
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
