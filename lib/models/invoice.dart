import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'additional_cost.dart';
import 'customer.dart';
import 'invoice_item.dart';
import 'invoice_payment.dart';

class Invoice {
  String id;
  String?
      invoiceNumber; // per-type sequential display number; null on legacy rows (falls back to id)
  Customer customer;
  List<InvoiceItem> items;
  DateTime date;
  String? notes;
  double taxRate;
  String type;
  String?
      invoiceTitle; // GST document title override (e.g. "Tax Invoice", "Bill of Supply"); null = use type
  String currencyCode;
  String currencySymbol;
  TaxMode taxMode;
  bool
      isInterState; // India: interstate supply → show IGST instead of CGST/SGST
  bool roundOffEnabled; // round the payable total to the nearest rupee; the
  // paise difference posts as an explicit Round Off ledger line so Sales
  // and Tax stay exact. Default off (exact totals).
  List<InvoicePayment> payments;
  String? upiId; // selected UPI account for this invoice
  String? bankAccountId; // selected bank account label key for this invoice
  DateTime? dueDate;
  String?
      quantityLabel; // custom label for the Qty column (e.g. "Words", "Hours")
  List<AdditionalCost>
      additionalCosts; // e.g. Shipping, Packaging (zero tax, added after tax)
  double previousBalance;
  InvoiceDiscountType
      invoiceDiscountType; // invoice-level discount, applied after tax
  double invoiceDiscountValue;
  bool hideInvoiceNumber; // hide real invoice number in PDF output only
  String? referenceInvoiceId; // for credit/debit notes
  bool isRecurring;
  String? recurringFrequency; // weekly/monthly/quarterly/yearly
  DateTime? recurringNextDate;
  String salesChannel; // invoice | pos | sale_order
  String? sourceOrderId;
  String?
      customInvoiceNumber; // shown instead of invoiceNumber in PDF when hideInvoiceNumber is true
  String paymentTermId; // linked payment term ID
  String? customFields; // JSON string of custom field values
  String
      industry; // immutable snapshot of the industry profile at creation time

  Invoice({
    required this.id,
    this.invoiceNumber,
    required this.customer,
    required this.items,
    required this.date,
    required this.type,
    this.invoiceTitle,
    this.notes,
    this.taxRate = 0.0,
    this.currencyCode = 'INR',
    this.currencySymbol = '₹',
    this.taxMode = TaxMode.global,
    this.isInterState = false,
    this.roundOffEnabled = false,
    this.payments = const [],
    this.upiId,
    this.bankAccountId,
    this.dueDate,
    this.quantityLabel,
    this.additionalCosts = const [],
    this.previousBalance = 0.0,
    this.invoiceDiscountType = InvoiceDiscountType.percent,
    this.invoiceDiscountValue = 0.0,
    this.hideInvoiceNumber = false,
    this.customInvoiceNumber,
    this.paymentTermId = '',
    this.customFields,
    this.referenceInvoiceId,
    this.isRecurring = false,
    this.recurringFrequency,
    this.recurringNextDate,
    this.salesChannel = 'invoice',
    this.sourceOrderId,
    this.industry = '',
  });

  /// Text to render for the invoice number in PDF/receipt output, or null to omit the line entirely.
  String? pdfNumberText(String invoicePrefix, {bool showLeadingZeros = true}) {
    if (hideInvoiceNumber) {
      final c = customInvoiceNumber?.trim();
      return (c != null && c.isNotEmpty) ? c : null;
    }
    final number = invoiceNumber ?? id;
    if (showLeadingZeros) return '$invoicePrefix$number';
    final stripped = number.replaceFirst(RegExp(r'^0+'), '');
    return '$invoicePrefix${stripped.isEmpty ? '0' : stripped}';
  }

  InvoiceTotals get _totals => InvoiceTotalsCalculator.totals(
        lines: items.map((item) => item.isJewelleryLine
            // Weight lines always carry their own 3% retail-jewellery tax
            // (sell rates are GST-exclusive); generic global tax does not
            // replace it.
            ? item.lineAmounts
            : item._amountsForInvoice(
                taxMode: taxMode, globalTaxRatePercent: taxRate * 100)),
        taxMode: taxMode,
        globalTaxRate: taxRate,
        globalTaxRateFormat: TaxRateFormat.fraction,
        additionalCostsTotal: additionalCostsTotal,
        invoiceDiscountType: invoiceDiscountType,
        invoiceDiscountValue: invoiceDiscountValue,
      );

  double get subtotal => _totals.subtotal;

  double get grossSubtotal => _totals.grossSubtotal;

  double get totalDiscount => _totals.totalDiscount;

  double get tax => _totals.tax;

  double get additionalCostsTotal =>
      additionalCosts.fold(0.0, (sum, c) => sum + c.amount);

  double get invoiceDiscountAmount => _totals.invoiceDiscountAmount;

  double get total => _totals.total;

  /// Round-off delta (payable − exact), 0 unless [roundOffEnabled].
  double get roundOffAmount =>
      InvoiceTotalsCalculator.roundOffAmount(total, enabled: roundOffEnabled);

  /// What the customer actually owes. Equals [total] unless rounding is on.
  /// Payments, outstanding, reports, ledger AR, and GSTR invoice value all
  /// derive from this so the books agree with the printed bill.
  double get payableTotal =>
      InvoiceTotalsCalculator.payableTotal(total, enabled: roundOffEnabled);

  double get amountPaid => payments
      .where(
          (p) => p.chequeStatus != 'bounced' && p.chequeStatus != 'cancelled')
      .fold(0.0, (sum, p) => sum + p.amountPaid);

  double get outstandingBalance =>
      InvoiceCalculator.outstanding(total: payableTotal, paid: amountPaid);

  /// True when every line's rate already contains tax. Outputs use this to
  /// label rates/tax as inclusive; editors restamp it via the GST toggle.
  bool get allPricesIncludeTax =>
      items.isNotEmpty && items.every((i) => i.product.priceIncludesTax);

  PaymentStatus get paymentStatus =>
      InvoiceCalculator.paymentStatus(total: payableTotal, paid: amountPaid);
}

extension _InvoiceItemTotals on InvoiceItem {
  InvoiceLineAmount _amountsForInvoice({
    required TaxMode taxMode,
    required double globalTaxRatePercent,
  }) =>
      InvoiceTotalsCalculator.line(
        price: effectivePrice,
        quantity: quantity,
        discount: discount,
        discountPerUnit: discountPerUnit,
        extraCost: extraCost ?? 0.0,
        taxRatePercent: product.tax_rate.toDouble(),
        priceIncludesTax: product.priceIncludesTax,
        taxMode: taxMode,
        globalTaxRatePercent: globalTaxRatePercent,
      );
}
