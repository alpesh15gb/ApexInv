import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/additional_cost.dart';

/// Payment-collection helpers: WhatsApp/SMS reminder deep links, UPI payment
/// links, and the overdue list that backs the reminders UI.
class ReminderService {
  static final dbHelper = DatabaseHelper();

  /// Invoices with outstanding balance, most-overdue first.
  /// Totals are computed with the shared engine (lines via
  /// [InvoiceTotalsCalculator.lineFromDbRow] + [InvoiceTotalsCalculator.totals]
  /// + payable total minus live payments), matching report/invoice services.
  static Future<List<OverdueInvoice>> getOverdue({int limit = 200}) async {
    final db = await dbHelper.database;
    final nowIso = DateTime.now().toIso8601String();
    final invRows = await db.query(
      'invoices',
      columns: [
        'id',
        'invoice_number',
        'customer_name',
        'customer_phone',
        'due_date',
        'currency_symbol',
        'tax_rate',
        'tax_mode',
        'additional_costs',
        'invoice_discount_type',
        'invoice_discount_value',
        'round_off',
      ],
      where: "deleted_at IS NULL AND type = 'Invoice' "
          'AND due_date IS NOT NULL AND due_date < ?',
      whereArgs: [nowIso],
      orderBy: 'due_date ASC',
    );
    if (invRows.isEmpty) return [];
    final ids = invRows.map((r) => r['id'] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final itemRows = await db.rawQuery(
      'SELECT invoice_id, unit_price, product_price, quantity, discount, '
      'discount_per_unit, extra_cost, product_tax_rate, '
      'product_price_includes_tax FROM invoice_items '
      'WHERE invoice_id IN ($placeholders)',
      ids,
    );
    final payRows = await db.rawQuery(
      'SELECT invoice_id, COALESCE(SUM(amount_paid), 0.0) AS paid '
      'FROM invoice_payments WHERE invoice_id IN ($placeholders) '
      "AND cheque_status NOT IN ('bounced', 'cancelled') GROUP BY invoice_id",
      ids,
    );
    final itemsByInv = <String, List<Map<String, dynamic>>>{};
    for (final r in itemRows) {
      (itemsByInv[r['invoice_id'] as String] ??= [])
          .add(r as Map<String, dynamic>);
    }
    final paidByInv = <String, double>{
      for (final r in payRows)
        r['invoice_id'] as String: (r['paid'] as num).toDouble()
    };
    final result = <OverdueInvoice>[];
    for (final inv in invRows) {
      final id = inv['id'] as String;
      final taxMode = TaxModeExtension.fromKey(inv['tax_mode'] as String?);
      final taxRate = (inv['tax_rate'] as num?)?.toDouble() ?? 0.0;
      final addTotal =
          AdditionalCost.listFromJson(inv['additional_costs'] as String?)
              .fold(0.0, (s, c) => s + c.amount);
      final totals = InvoiceTotalsCalculator.totals(
        lines: (itemsByInv[id] ?? []).map((r) =>
            InvoiceTotalsCalculator.lineFromDbRow(r,
                taxMode: taxMode, globalTaxRatePercent: taxRate * 100)),
        taxMode: taxMode,
        globalTaxRate: taxRate,
        globalTaxRateFormat: TaxRateFormat.fraction,
        additionalCostsTotal: addTotal,
        invoiceDiscountType: InvoiceDiscountTypeExtension.fromKey(
            inv['invoice_discount_type'] as String?),
        invoiceDiscountValue:
            (inv['invoice_discount_value'] as num?)?.toDouble() ?? 0.0,
      );
      final payable = InvoiceTotalsCalculator.payableTotal(totals.total,
          enabled: (inv['round_off'] as int?) == 1);
      final outstanding = InvoiceCalculator.outstanding(
          total: payable, paid: paidByInv[id] ?? 0.0);
      if (outstanding <= InvoiceCalculator.moneyEpsilon) continue;
      final due = DateTime.tryParse(inv['due_date'] as String? ?? '');
      result.add(OverdueInvoice(
        id: id,
        invoiceNumber: inv['invoice_number'] as String? ?? '',
        customerName: inv['customer_name'] as String? ?? '',
        phone: inv['customer_phone'] as String? ?? '',
        total: payable,
        outstanding: outstanding,
        dueDate: due,
        currencySymbol: inv['currency_symbol'] as String? ?? '₹',
      ));
      if (result.length >= limit) break;
    }
    return result;
  }

  /// wa.me deep link with a prefilled payment reminder.
  static String whatsappUrl(OverdueInvoice inv, {String? upiId}) {
    final phoneDigits = inv.phone.replaceAll(RegExp(r'\D'), '');
    final dueStr = inv.dueDate == null
        ? ''
        : DateFormat('dd MMM yyyy').format(inv.dueDate!);
    final msg = 'Hello ${inv.customerName},\n\n'
        'Gentle reminder: invoice #${inv.invoiceNumber}'
        '${dueStr.isEmpty ? '' : ' (due $dueStr)'} has an outstanding '
        'balance of ${inv.currencySymbol} ${inv.outstanding.toStringAsFixed(2)}.'
        '${upiId == null || upiId.isEmpty ? '' : '\n\nPay instantly via UPI: '
            'upi://pay?pa=$upiId&pn=Merchant&am=${inv.outstanding.toStringAsFixed(2)}&cu=INR&tn=Invoice ${inv.invoiceNumber}'}'
        '\n\nThank you!';
    return 'https://wa.me/$phoneDigits?text=${Uri.encodeComponent(msg)}';
  }

  static Future<void> openWhatsApp(OverdueInvoice inv, {String? upiId}) =>
      launchUrl(Uri.parse(whatsappUrl(inv, upiId: upiId)),
          mode: LaunchMode.externalApplication);

  /// UPI deep link — opens any installed UPI app pre-filled.
  static Uri upiLink({
    required String payeeUpiId,
    required String payeeName,
    required double amount,
    required String note,
  }) {
    final q = Uri(queryParameters: {
      'pa': payeeUpiId,
      'pn': payeeName,
      'am': amount.toStringAsFixed(2),
      'cu': 'INR',
      'tn': note,
    }).query;
    return Uri.parse('upi://pay?$q');
  }

  static Future<void> shareReminder(OverdueInvoice inv, {String? upiId}) {
    final url = whatsappUrl(inv, upiId: upiId);
    return Share.share(
      Uri.parse(url).queryParameters['text'] ?? '',
      subject: 'Invoice ${inv.invoiceNumber} reminder',
    );
  }
}

class OverdueInvoice {
  final String id;
  final String invoiceNumber;
  final String customerName;
  final String phone;
  final double total;
  final double outstanding;
  final DateTime? dueDate;
  final String currencySymbol;

  const OverdueInvoice({
    required this.id,
    required this.invoiceNumber,
    required this.customerName,
    required this.phone,
    required this.total,
    required this.outstanding,
    required this.dueDate,
    required this.currencySymbol,
  });
}
