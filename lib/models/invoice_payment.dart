import 'package:apexbooks/utils/app_date.dart';

class InvoicePayment {
  final String id;
  final String invoiceId;
  final String invoiceNumber;
  final String receiptNumber;
  final double amountPaid;
  final double taxAmountPaid;
  final double previouslyPaid;
  final double balanceAfter;
  final DateTime datePaid;
  final String? paymentMethod;
  final String? notes;
  final String? chequeNumber;
  final DateTime? chequeDate;
  final bool chequeCleared;
  final String? accountId;
  final String? chequeId;
  final String chequeStatus;

  const InvoicePayment({
    required this.id,
    required this.invoiceId,
    required this.invoiceNumber,
    required this.receiptNumber,
    required this.amountPaid,
    required this.taxAmountPaid,
    required this.previouslyPaid,
    required this.balanceAfter,
    required this.datePaid,
    this.paymentMethod,
    this.notes,
    this.chequeNumber,
    this.chequeDate,
    this.chequeCleared = false,
    this.accountId,
    this.chequeId,
    this.chequeStatus = 'none',
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'invoice_id': invoiceId,
        'invoice_number': invoiceNumber,
        'receipt_number': receiptNumber,
        'amount_paid': amountPaid,
        'tax_amount_paid': taxAmountPaid,
        'previously_paid': previouslyPaid,
        'balance_after': balanceAfter,
        'date_paid': AppDate.dateKey(datePaid),
        'payment_method': paymentMethod,
        'notes': notes,
        'cheque_number': chequeNumber,
        'cheque_date': chequeDate?.toIso8601String(),
        'cheque_cleared': chequeCleared ? 1 : 0,
        'account_id': accountId,
        'cheque_id': chequeId,
        'cheque_status': chequeStatus,
      };

  factory InvoicePayment.fromMap(Map<String, dynamic> map) => InvoicePayment(
        id: map['id'] as String,
        invoiceId: map['invoice_id'] as String,
        invoiceNumber: map['invoice_number'] as String,
        receiptNumber: map['receipt_number'] as String,
        amountPaid: (map['amount_paid'] as num).toDouble(),
        taxAmountPaid: (map['tax_amount_paid'] as num).toDouble(),
        previouslyPaid: (map['previously_paid'] as num).toDouble(),
        balanceAfter: (map['balance_after'] as num).toDouble(),
        datePaid: DateTime.parse(map['date_paid'] as String),
        paymentMethod: map['payment_method'] as String?,
        notes: map['notes'] as String?,
        chequeNumber: map['cheque_number'] as String?,
        chequeDate: DateTime.tryParse(map['cheque_date'] as String? ?? ''),
        chequeCleared: (map['cheque_cleared'] as int? ?? 0) == 1,
        accountId: map['account_id'] as String?,
        chequeId: map['cheque_id'] as String?,
        chequeStatus: map['cheque_status'] as String? ?? 'none',
      );
}
