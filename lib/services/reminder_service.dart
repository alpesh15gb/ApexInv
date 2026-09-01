import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:apexbooks/database/database_helper.dart';

/// Payment-collection helpers: WhatsApp/SMS reminder deep links, UPI payment
/// links, and the overdue list that backs the reminders UI.
class ReminderService {
  static final dbHelper = DatabaseHelper();

  /// Invoices with outstanding balance, most-overdue first.
  static Future<List<OverdueInvoice>> getOverdue({int limit = 200}) async {
    final db = await dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.id, i.invoice_number, i.customer_name, i.customer_phone,
             i.total, i.due_date, i.currency_symbol,
             (i.total - COALESCE((SELECT SUM(p.amount_paid)
                FROM invoice_payments p WHERE p.invoice_id = i.id), 0))
              AS outstanding
      FROM invoices i
      WHERE i.deleted_at IS NULL AND i.type = 'Invoice'
        AND i.due_date IS NOT NULL
      HAVING outstanding > 0.005
      ORDER BY i.due_date ASC
      LIMIT $limit
    ''');
    return rows.map((r) {
      final due = DateTime.tryParse(r['due_date'] as String? ?? '');
      return OverdueInvoice(
        id: r['id'] as String,
        invoiceNumber: r['invoice_number'] as String? ?? '',
        customerName: r['customer_name'] as String? ?? '',
        phone: r['customer_phone'] as String? ?? '',
        total: (r['total'] as num?)?.toDouble() ?? 0,
        outstanding: (r['outstanding'] as num?)?.toDouble() ?? 0,
        dueDate: due,
        currencySymbol: r['currency_symbol'] as String? ?? '₹',
      );
    }).toList();
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
