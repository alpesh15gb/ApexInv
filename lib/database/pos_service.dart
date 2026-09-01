import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/invoice_payment.dart';
import 'accounting_service.dart';
import 'database_helper.dart';
import 'invoice_service.dart';

class PosTender {
  final String method;
  final double amount;
  final String? accountId;
  final String? chequeNumber;
  final DateTime? chequeDate;

  const PosTender({
    required this.method,
    required this.amount,
    this.accountId,
    this.chequeNumber,
    this.chequeDate,
  });
}

class PosService {
  static final _dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

  /// Finalizes a POS cart in one transaction: invoice, inventory, tenders,
  /// cheque register and account movements either all commit or all roll back.
  static Future<Invoice> finalize({
    required Customer customer,
    required List<InvoiceItem> items,
    required List<PosTender> tenders,
    required String currencyCode,
    required String currencySymbol,
    String notes = '',
  }) async {
    if (items.isEmpty) throw ArgumentError('The POS cart is empty');
    if (items.any((item) => item.quantity <= 0)) {
      throw ArgumentError('Item quantities must be positive');
    }
    final invoiceId = await InvoiceService.generateNextId();
    final invoiceNumber =
        await InvoiceService.generateNextInvoiceNumber('Invoice');
    final invoice = Invoice(
      id: invoiceId,
      invoiceNumber: invoiceNumber,
      customer: customer,
      items: items,
      date: DateTime.now(),
      type: 'Invoice',
      notes: notes,
      currencyCode: currencyCode,
      currencySymbol: currencySymbol,
      taxMode: TaxMode.perItem,
    );
    final paid = tenders.fold(0.0, (sum, tender) => sum + tender.amount);
    if (tenders.any((t) => t.amount <= 0) || paid > invoice.total + 0.005) {
      throw StateError('Tender total must be positive and cannot exceed total');
    }
    if (paid < invoice.total - 0.005 && customer.id == 'walk-in') {
      throw StateError('Select a customer before making a credit sale');
    }

    final db = await _dbHelper.database;
    final payments = <InvoicePayment>[];
    await db.transaction((txn) async {
      for (final item in items) {
        final rows = await txn.query('products',
            where: 'id = ?', whereArgs: [item.product.id], limit: 1);
        if (rows.isEmpty) {
          throw StateError('Product ${item.product.name} no longer exists');
        }
        final row = rows.first;
        if ((row['unlimited_stock'] as int? ?? 0) == 0) {
          final stock = (row['stock'] as num? ?? 0).toDouble();
          final reservedRows = await txn.rawQuery('''
            SELECT COALESCE(SUM(i.quantity - i.fulfilled_quantity), 0) AS qty
            FROM sale_order_items i JOIN sale_orders o ON o.id = i.sale_order_id
            WHERE i.product_id = ? AND o.status IN ('confirmed', 'partial')
          ''', [item.product.id]);
          final reserved =
              (reservedRows.first['qty'] as num? ?? 0).toDouble();
          if (item.quantity > stock - reserved + 0.000001) {
            throw StateError('Insufficient stock for ${item.product.name}');
          }
          await txn.update('products', {'stock': stock - item.quantity},
              where: 'id = ?', whereArgs: [item.product.id]);
        }
      }

      await txn.insert('invoices', {
        'id': invoice.id,
        'invoice_number': invoice.invoiceNumber,
        'customer_id': customer.id,
        'customer_name': customer.name,
        'customer_email': customer.email,
        'customer_phone': customer.phone,
        'customer_address': customer.address,
        'customer_gstin': customer.gstin,
        'customer_business_name': customer.businessName,
        'date': invoice.date.toIso8601String(),
        'notes': notes,
        'tax_rate': 0,
        'type': 'Invoice',
        'currency_code': currencyCode,
        'currency_symbol': currencySymbol,
        'tax_mode': 'item',
        'additional_costs': jsonEncode(<Object>[]),
        'previous_balance': 0,
        'invoice_discount_type': 'percent',
        'invoice_discount_value': 0,
        'is_interstate': 0,
        'payment_term_id': '',
        'custom_fields': '',
        'sales_channel': 'pos',
      });
      for (final item in items) {
        await txn.insert('invoice_items', {
          'id': item.id,
          'invoice_id': invoice.id,
          'product_id': item.product.id,
          'product_name': item.product.name,
          'product_description': item.product.description,
          'product_price': item.product.price,
          'product_tax_rate': item.product.tax_rate,
          'product_hsn_code': item.product.hsncode,
          'quantity': item.quantity,
          'discount': item.discount,
          'unit_price': item.unitPrice,
          'extra_cost': item.extraCost,
          'discount_per_unit': item.discountPerUnit ? 1 : 0,
          'is_product_saved': 1,
          'product_type': item.product.type,
          'product_purchase_price': item.product.purchasePrice,
          'product_alias_name': item.product.aliasName,
          'product_unit': item.product.unit,
          'unit': item.unit,
          'product_price_includes_tax':
              item.product.priceIncludesTax ? 1 : 0,
          'description': item.description,
        });
      }

      var previouslyPaid = 0.0;
      for (var index = 0; index < tenders.length; index++) {
        final tender = tenders[index];
        final paymentId = _uuid.v4();
        final receiptNumber =
            '${invoice.id}-R${(index + 1).toString().padLeft(3, '0')}';
        final isCheque = tender.method == 'Check';
        String? accountId;
        String? chequeId;
        if (isCheque) {
          if ((tender.chequeNumber?.trim().isEmpty ?? true) ||
              tender.chequeDate == null) {
            throw StateError('Cheque number and date are required');
          }
          if (tender.accountId != null) {
            accountId = await AccountingService.resolveAccountId(txn,
                requestedAccountId: tender.accountId,
                paymentMethod: 'Bank Transfer',
                currencyCode: currencyCode,
                currencySymbol: currencySymbol);
          }
          chequeId = await AccountingService.createCheque(txn,
              direction: 'received',
              partyName: customer.name,
              amount: tender.amount,
              chequeNumber: tender.chequeNumber!,
              chequeDate: tender.chequeDate!,
              sourceType: 'invoice_payment',
              sourceId: paymentId,
              currencyCode: currencyCode,
              currencySymbol: currencySymbol,
              notes: notes);
        } else {
          accountId = await AccountingService.resolveAccountId(txn,
              requestedAccountId: tender.accountId,
              paymentMethod: tender.method,
              currencyCode: currencyCode,
              currencySymbol: currencySymbol);
          await AccountingService.insertMovement(txn,
              accountId: accountId,
              kind: 'pos_receipt',
              amount: tender.amount,
              date: invoice.date,
              sourceType: 'invoice_payment',
              sourceId: paymentId,
              reference: receiptNumber,
              notes: notes);
        }
        final balanceAfter =
            (invoice.total - previouslyPaid - tender.amount)
                .clamp(0, double.infinity)
                .toDouble();
        final payment = InvoicePayment(
          id: paymentId,
          invoiceId: invoice.id,
          invoiceNumber: invoice.invoiceNumber!,
          receiptNumber: receiptNumber,
          amountPaid: tender.amount,
          taxAmountPaid: invoice.total <= 0
              ? 0
              : tender.amount * invoice.tax / invoice.total,
          previouslyPaid: previouslyPaid,
          balanceAfter: balanceAfter,
          datePaid: invoice.date,
          paymentMethod: tender.method,
          notes: notes,
          chequeNumber: tender.chequeNumber,
          chequeDate: tender.chequeDate,
          accountId: accountId,
          chequeId: chequeId,
          chequeStatus: isCheque ? 'pending' : 'none',
        );
        await txn.insert('invoice_payments', payment.toMap());
        payments.add(payment);
        previouslyPaid += tender.amount;
      }
    });
    invoice.payments = payments;
    return invoice;
  }
}
