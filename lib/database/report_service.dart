import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/services/backend_services.dart';
import 'package:apexbooks/services/pdf/pdf_report_header.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/domain/customer_identity.dart';
import 'package:apexbooks/domain/invoice_calculator.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/additional_cost.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'package:apexbooks/utils/formatters.dart';
import 'package:apexbooks/models/report_models.dart';
import 'package:apexbooks/services/pdf/pdf_font_service.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:apexbooks/common/constants.dart';
export 'package:apexbooks/models/report_models.dart';

// ─── Internal row ─────────────────────────────────────────────────────────────

class _InvRow {
  final String id;
  final String customerKey;
  final String customerName;
  final String date;
  final String? dueDate;
  final double total;
  final double paid;
  final double outstanding;
  final String currencyCode;
  final String currencySymbol;

  const _InvRow({
    required this.id,
    required this.customerKey,
    required this.customerName,
    required this.date,
    this.dueDate,
    required this.total,
    required this.paid,
    required this.outstanding,
    required this.currencyCode,
    required this.currencySymbol,
  });
}

class _StatementLineDraft {
  final String date;
  final int order;
  final String type;
  final String reference;
  final String description;
  final double debit;
  final double credit;

  const _StatementLineDraft({
    required this.date,
    required this.order,
    required this.type,
    required this.reference,
    required this.description,
    required this.debit,
    required this.credit,
  });
}

// ─── Service ───────────────────────────────────────────────────────────────────

class ReportService {
  static final _db = DatabaseHelper();
  static const _invoiceItemNetSql = 'CASE WHEN ii.discount_per_unit = 1 '
      'THEN (COALESCE(ii.unit_price, ii.product_price) - ii.discount) * ii.quantity '
      '+ COALESCE(ii.extra_cost, 0) '
      'ELSE COALESCE(ii.unit_price, ii.product_price) * ii.quantity '
      '- ii.discount + COALESCE(ii.extra_cost, 0) END';
  static const _invoiceItemDiscountSql = 'CASE WHEN ii.discount_per_unit = 1 '
      'THEN ii.discount * ii.quantity ELSE ii.discount END';
  // Revenue basis for P&L/dashboard: backs out embedded tax for
  // tax-inclusive-priced items so "revenue" stays a tax-exclusive figure,
  // matching the sales tax report and invoice subtotal. Applies in per-item
  // mode via the line's product rate, and in global mode via the invoice's
  // global rate (global-mode tax never derives from per-product rates).
  static const _invoiceItemTaxableNetSql =
      "CASE WHEN i.tax_mode = 'per_item' AND ii.product_price_includes_tax = 1 "
      'AND ii.product_tax_rate > 0 '
      'THEN ($_invoiceItemNetSql) / (1 + ii.product_tax_rate / 100.0) '
      "WHEN i.tax_mode = 'global' AND ii.product_price_includes_tax = 1 "
      'AND i.tax_rate > 0 '
      'THEN ($_invoiceItemNetSql) / (1 + i.tax_rate) '
      'ELSE $_invoiceItemNetSql END';

  // ── Batch loader: invoice totals computed in Dart (accurate, no N+1) ────────

  static Future<List<_InvRow>> _loadRows({
    String type = 'Invoice',
    DateTime? from,
    DateTime? to,
    String? currencyCode,
    String? customerKey,
  }) async {
    final db = await _db.database;

    final sb = StringBuffer('type = ? AND deleted_at IS NULL');
    final args = <dynamic>[type];
    if (from != null) {
      sb.write(' AND date >= ?');
      args.add(AppDate.dateKeyStart(from));
    }
    if (to != null) {
      sb.write(' AND date <= ?');
      args.add(AppDate.dateKeyEnd(to));
    }
    if (currencyCode != null) {
      sb.write(' AND currency_code = ?');
      args.add(currencyCode);
    }
    if (customerKey != null) {
      sb.write(" AND COALESCE(NULLIF(customer_id, ''), customer_name) = ?");
      args.add(customerKey);
    }

    final invRows = await db.query(
      'invoices',
      columns: [
        'id',
        'customer_id',
        'customer_name',
        'date',
        'due_date',
        'tax_rate',
        'tax_mode',
        'additional_costs',
        'invoice_discount_type',
        'invoice_discount_value',
        'currency_code',
        'currency_symbol',
      ],
      where: sb.toString(),
      whereArgs: args,
    );
    if (invRows.isEmpty) return [];

    final ids = invRows.map((r) => r['id'] as String).toList();
    final ph = List.filled(ids.length, '?').join(',');

    final itemRows = await db.rawQuery(
      'SELECT invoice_id, quantity, unit_price, product_price, discount, '
      'discount_per_unit, extra_cost, product_tax_rate, product_price_includes_tax '
      'FROM invoice_items WHERE invoice_id IN ($ph)',
      ids,
    );

    final payRows = await db.rawQuery(
      'SELECT invoice_id, COALESCE(SUM(amount_paid), 0.0) AS paid '
      "FROM invoice_payments WHERE invoice_id IN ($ph) AND cheque_status NOT IN ('bounced', 'cancelled') "
      'GROUP BY invoice_id',
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

    return invRows.map((inv) {
      final id = inv['id'] as String;
      final taxMode = TaxModeExtension.fromKey(inv['tax_mode'] as String?);
      final taxRate = (inv['tax_rate'] as num?)?.toDouble() ?? 0.0;
      final items = itemsByInv[id] ?? [];
      final paid = paidByInv[id] ?? 0.0;

      final addCosts =
          AdditionalCost.listFromJson(inv['additional_costs'] as String?)
              .fold(0.0, (s, c) => s + c.amount);
      final totals = InvoiceTotalsCalculator.totals(
        lines: items.map((r) => InvoiceTotalsCalculator.lineFromDbRow(r,
            taxMode: taxMode, globalTaxRatePercent: taxRate * 100)),
        taxMode: taxMode,
        globalTaxRate: taxRate,
        globalTaxRateFormat: TaxRateFormat.fraction,
        additionalCostsTotal: addCosts,
        invoiceDiscountType: InvoiceDiscountTypeExtension.fromKey(
            inv['invoice_discount_type'] as String?),
        invoiceDiscountValue:
            (inv['invoice_discount_value'] as num?)?.toDouble() ?? 0.0,
      );
      final total = totals.total;
      final outstanding =
          InvoiceCalculator.outstanding(total: total, paid: paid);

      return _InvRow(
        id: id,
        customerKey: CustomerIdentity.key(
          id: inv['customer_id'] as String?,
          name: inv['customer_name'] as String?,
        ),
        customerName:
            CustomerIdentity.displayName(inv['customer_name'] as String?),
        date: inv['date'] as String? ?? '',
        dueDate: inv['due_date'] as String?,
        total: total,
        paid: paid,
        outstanding: outstanding,
        currencyCode: inv['currency_code'] as String? ?? 'INR',
        currencySymbol: inv['currency_symbol'] as String? ?? 'Rs.',
      );
    }).toList();
  }

  // ── 1. Revenue KPIs ────────────────────────────────────────────────────────

  static Future<RevenueKpi> getRevenueSummary(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final rows =
        await _loadRows(from: from, to: to, currencyCode: currencyCode);
    if (rows.isEmpty) return RevenueKpi.empty;

    double billed = 0, collected = 0, outstanding = 0;
    for (final r in rows) {
      billed += r.total;
      collected += r.paid;
      outstanding += r.outstanding;
    }
    final profit = await _getTotalProfit(from, to, currencyCode: currencyCode);
    return RevenueKpi(
      invoiceCount: rows.length,
      billed: billed,
      collected: collected,
      outstanding: outstanding,
      avgInvoiceValue: billed / rows.length,
      profit: profit,
    );
  }

  /// Net product revenue minus cost of goods sold, for [from]..[to]. Uses the
  /// same net-revenue basis as [getTopProducts] (tax-exclusive line total),
  /// not the tax-inclusive invoice `billed` total used elsewhere in this KPI.
  static Future<double> _getTotalProfit(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final ccFilter = currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];
    final rows = await db.rawQuery(
      // Accrual revenue: invoices only. Payment/cheque status must not
      // filter revenue (a bounced cheque affects cash, not sales).
      "SELECT SUM($_invoiceItemTaxableNetSql) AS revenue, "
      "SUM(ii.quantity * ii.product_purchase_price) AS cogs "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "$ccFilter"
      "AND i.date >= ? AND i.date <= ?",
      args,
    );
    if (rows.isEmpty) return 0.0;
    final revenue = (rows.first['revenue'] as num?)?.toDouble() ?? 0.0;
    final cogs = (rows.first['cogs'] as num?)?.toDouble() ?? 0.0;
    return revenue - cogs;
  }

  /// Count of sold line items in [from]..[to] with no purchase-price
  /// snapshot (0 or null) — i.e. sales made before purchase price was set on
  /// the product, or before this feature existed. Profit/margin figures are
  /// understated by this many items' worth of unknown cost.
  static Future<int> getMissingCostItemCount(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final ccFilter = currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS cnt "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "AND (ii.product_purchase_price IS NULL OR ii.product_purchase_price = 0) "
      "$ccFilter"
      "AND i.date >= ? AND i.date <= ?",
      args,
    );
    return (rows.first['cnt'] as num?)?.toInt() ?? 0;
  }

  // ── 2. Monthly revenue trend ───────────────────────────────────────────────

  static Future<List<MonthlyPoint>> getMonthlyRevenueTrend(
      DateTime from, DateTime to,
      {String? currencyCode}) async {
    final rows =
        await _loadRows(from: from, to: to, currencyCode: currencyCode);
    final db = await _db.database;

    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final currencyFilter =
        currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];

    // Collected grouped by payment date (more accurate for cash-flow view)
    final collectedRows = await db.rawQuery(
      "SELECT strftime('%Y-%m', ip.date_paid) AS month, "
      "COALESCE(SUM(ip.amount_paid), 0.0) AS collected "
      "FROM invoice_payments ip "
      "JOIN invoices i ON ip.invoice_id = i.id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "$currencyFilter"
      "AND ip.date_paid >= ? AND ip.date_paid <= ? "
      "GROUP BY month ORDER BY month",
      args,
    );

    final collectedByMonth = <String, double>{
      for (final r in collectedRows)
        r['month'] as String: (r['collected'] as num).toDouble()
    };

    // Billed grouped by invoice date
    final billedByMonth = <String, double>{};
    for (final r in rows) {
      if (r.date.length >= 7) {
        final m = r.date.substring(0, 7);
        billedByMonth[m] = (billedByMonth[m] ?? 0) + r.total;
      }
    }

    // Profit grouped by invoice date (net revenue minus COGS)
    final profitRows = await db.rawQuery(
      "SELECT strftime('%Y-%m', i.date) AS month, "
      "SUM($_invoiceItemTaxableNetSql) AS revenue, "
      "SUM(ii.quantity * ii.product_purchase_price) AS cogs "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "$currencyFilter"
      "AND i.date >= ? AND i.date <= ? "
      "GROUP BY month",
      args,
    );
    final profitByMonth = <String, double>{
      for (final r in profitRows)
        r['month'] as String: ((r['revenue'] as num?)?.toDouble() ?? 0.0) -
            ((r['cogs'] as num?)?.toDouble() ?? 0.0)
    };

    final allMonths = {...billedByMonth.keys, ...collectedByMonth.keys}.toList()
      ..sort();

    return allMonths
        .map((m) => MonthlyPoint(
              month: m,
              billed: billedByMonth[m] ?? 0,
              collected: collectedByMonth[m] ?? 0,
              profit: profitByMonth[m] ?? 0,
            ))
        .toList();
  }

  // ── 2b. Daily sales/profit trend ────────────────────────────────────────────

  static Future<List<DailyPoint>> getDailyRevenueTrend(
      DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final currencyFilter =
        currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];

    final rows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', i.date) AS day, "
      "COUNT(DISTINCT i.id) AS invoice_count, "
      "SUM($_invoiceItemTaxableNetSql) AS revenue, "
      "SUM(ii.quantity * ii.product_purchase_price) AS cogs "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "$currencyFilter"
      "AND i.date >= ? AND i.date <= ? "
      "GROUP BY day ORDER BY day",
      args,
    );

    return rows
        .map((r) => DailyPoint(
              date: r['day'] as String,
              invoiceCount: (r['invoice_count'] as num?)?.toInt() ?? 0,
              billed: (r['revenue'] as num?)?.toDouble() ?? 0.0,
              cogs: (r['cogs'] as num?)?.toDouble() ?? 0.0,
            ))
        .toList();
  }

  // ── 3. Payment status breakdown ────────────────────────────────────────────

  static Future<StatusBreakdown> getPaymentStatusBreakdown(
      DateTime from, DateTime to,
      {String? currencyCode}) async {
    final rows =
        await _loadRows(from: from, to: to, currencyCode: currencyCode);
    int paid = 0, partial = 0, unpaid = 0;
    for (final r in rows) {
      switch (InvoiceCalculator.paymentStatus(total: r.total, paid: r.paid)) {
        case PaymentStatus.unpaid:
          unpaid++;
        case PaymentStatus.paid:
          paid++;
        case PaymentStatus.partial:
          partial++;
      }
    }
    return StatusBreakdown(paid: paid, partial: partial, unpaid: unpaid);
  }

  // ── 4. Aged receivables (all time, all overdue) ────────────────────────────

  static Future<List<AgedReceivable>> getAgedReceivables(
      {String? currencyCode}) async {
    final rows = await _loadRows(currencyCode: currencyCode);
    final now = DateTime.now();
    final result = <AgedReceivable>[];

    for (final r in rows) {
      if (r.outstanding <= InvoiceCalculator.moneyEpsilon) continue;
      final dueDate = r.dueDate != null ? DateTime.tryParse(r.dueDate!) : null;
      final bool noDueDate = dueDate == null;
      final daysOverdue =
          InvoiceCalculator.daysOverdue(dueDate: dueDate, asOf: now);
      result.add(AgedReceivable(
        invoiceId: r.id,
        customerName: r.customerName,
        outstanding: r.outstanding,
        daysOverdue: daysOverdue,
        hasNoDueDate: noDueDate,
      ));
    }
    // Sort: no-due-date last, then by days overdue descending
    result.sort((a, b) {
      if (a.hasNoDueDate != b.hasNoDueDate) return a.hasNoDueDate ? 1 : -1;
      return b.daysOverdue.compareTo(a.daysOverdue);
    });
    return result;
  }

  /// Total outstanding (all-time, not date-bound) per customer, keyed by
  /// customer_id — for a customer-list "Outstanding" column/filter/sort.
  static Future<Map<String, double>> getOutstandingByCustomer(
      {String? currencyCode}) async {
    final rows = await _loadRows(currencyCode: currencyCode);
    final result = <String, double>{};
    for (final r in rows) {
      if (r.outstanding <= InvoiceCalculator.moneyEpsilon) continue;
      result[r.customerKey] = (result[r.customerKey] ?? 0) + r.outstanding;
    }
    return result;
  }

  /// Distinct currency codes actually used across (non-deleted) invoices —
  /// for a currency picker, e.g. next to the Outstanding column.
  static Future<List<String>> getInvoiceCurrencies() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      "SELECT DISTINCT currency_code FROM invoices "
      "WHERE deleted_at IS NULL AND type = 'Invoice' AND currency_code IS NOT NULL",
    );
    final codes = rows.map((r) => r['currency_code'] as String).toList();
    codes.sort();
    return codes;
  }

  // ── 5. Tax collected by rate ───────────────────────────────────────────────

  static Future<List<TaxBucket>> getTaxByRate(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final ccFilter = currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final dateArgs = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];

    final buckets = <double, double>{};

    // Per-item mode: tax computed per line item's product_tax_rate
    final perItemRows = await db.rawQuery(
      "SELECT ii.product_tax_rate AS rate, "
      "SUM(CASE WHEN ii.product_price_includes_tax = 1 "
      "THEN $_invoiceItemNetSql * ii.product_tax_rate / (100 + ii.product_tax_rate) "
      "ELSE $_invoiceItemNetSql * ii.product_tax_rate / 100 "
      "END) AS tax_amount "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "AND i.tax_mode = 'per_item' "
      "$ccFilter"
      "AND i.date >= ? AND i.date <= ? "
      "AND ii.product_tax_rate > 0 "
      "GROUP BY ii.product_tax_rate",
      dateArgs,
    );
    for (final r in perItemRows) {
      final rate = (r['rate'] as num).toDouble();
      buckets[rate] =
          (buckets[rate] ?? 0) + (r['tax_amount'] as num).toDouble();
    }

    // Global mode: single tax rate applied to the invoice subtotal
    final globalInvRows = await db.rawQuery(
      "SELECT i.id, i.tax_rate, i.additional_costs "
      "FROM invoices i "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "AND i.tax_mode = 'global' AND i.tax_rate > 0 "
      "$ccFilter"
      "AND i.date >= ? AND i.date <= ?",
      dateArgs,
    );

    if (globalInvRows.isNotEmpty) {
      final ids = globalInvRows.map((r) => r['id'] as String).toList();
      final ph = List.filled(ids.length, '?').join(',');
      final itemRows = await db.rawQuery(
        "SELECT invoice_id, quantity, unit_price, product_price, discount, "
        "discount_per_unit, extra_cost, product_tax_rate, product_price_includes_tax "
        "FROM invoice_items WHERE invoice_id IN ($ph)",
        ids,
      );
      final itemsByInv = <String, List<Map<String, dynamic>>>{};
      for (final r in itemRows) {
        (itemsByInv[r['invoice_id'] as String] ??= [])
            .add(r as Map<String, dynamic>);
      }
      for (final inv in globalInvRows) {
        final id = inv['id'] as String;
        final taxRate = (inv['tax_rate'] as num?)?.toDouble() ?? 0.0;
        final totals = InvoiceTotalsCalculator.totals(
          lines: (itemsByInv[id] ?? []).map((r) =>
              InvoiceTotalsCalculator.lineFromDbRow(r,
                  taxMode: TaxMode.global,
                  globalTaxRatePercent: taxRate * 100)),
          taxMode: TaxMode.global,
          globalTaxRate: taxRate,
          globalTaxRateFormat: TaxRateFormat.fraction,
        );
        final tax = totals.tax;
        final ratePercent = taxRate * 100;
        if (tax > 0) {
          buckets[ratePercent] = (buckets[ratePercent] ?? 0) + tax;
        }
      }
    }

    return (buckets.entries
        .map((e) => TaxBucket(rate: e.key, taxCollected: e.value))
        .toList()
      ..sort((a, b) => a.rate.compareTo(b.rate)));
  }

  // ── 6. Top customers ──────────────────────────────────────────────────────

  static Future<List<TopCustomer>> getTopCustomers(
    DateTime from,
    DateTime to, {
    int limit = 500,
    String? currencyCode,
  }) async {
    final rows =
        await _loadRows(from: from, to: to, currencyCode: currencyCode);

    final byCustomer = <String, List<_InvRow>>{};
    for (final r in rows) {
      (byCustomer[r.customerKey] ??= []).add(r);
    }

    final result = byCustomer.entries.map((e) {
      double billed = 0, collected = 0, outstanding = 0;
      for (final r in e.value) {
        billed += r.total;
        collected += r.paid;
        outstanding += r.outstanding;
      }
      return TopCustomer(
        name: e.value.first.customerName,
        invoiceCount: e.value.length,
        billed: billed,
        collected: collected,
        outstanding: outstanding,
      );
    }).toList()
      ..sort((a, b) => b.billed.compareTo(a.billed));

    return result.take(limit).toList();
  }

  static Future<List<CustomerStatementCustomer>> getStatementCustomers({
    String? currencyCode,
  }) async {
    final db = await _db.database;
    final sb = StringBuffer(
      "type = 'Invoice' AND deleted_at IS NULL "
      "AND COALESCE(NULLIF(customer_id, ''), customer_name) IS NOT NULL",
    );
    final args = <Object?>[];
    if (currencyCode != null) {
      sb.write(' AND currency_code = ?');
      args.add(currencyCode);
    }

    final rows = await db.rawQuery(
      "SELECT COALESCE(NULLIF(customer_id, ''), customer_name) AS customer_key, "
      "COALESCE(NULLIF(customer_name, ''), 'Unknown') AS customer_name, "
      'COUNT(*) AS invoice_count '
      'FROM invoices '
      'WHERE ${sb.toString()} '
      'GROUP BY customer_key '
      'ORDER BY customer_name COLLATE NOCASE',
      args,
    );

    return rows
        .map((r) => CustomerStatementCustomer(
              key: CustomerIdentity.key(
                id: r['customer_key'] as String?,
                name: r['customer_name'] as String?,
              ),
              name: CustomerIdentity.displayName(r['customer_name'] as String?),
              invoiceCount: (r['invoice_count'] as num).toInt(),
            ))
        .toList();
  }

  static Future<List<CustomerStatement>> getCustomerStatements(
    String customerKey,
    DateTime from,
    DateTime to, {
    String? currencyCode,
  }) async {
    final rows = await _loadRows(
      customerKey: customerKey,
      currencyCode: currencyCode,
    );
    if (rows.isEmpty) return [];

    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final byCurrency = <String, List<_InvRow>>{};
    for (final row in rows) {
      (byCurrency[row.currencyCode] ??= []).add(row);
    }

    final statements = <CustomerStatement>[];
    for (final entry in byCurrency.entries) {
      final currencyRows = entry.value;
      final ids = currencyRows.map((r) => r.id).toList();
      final ph = List.filled(ids.length, '?').join(',');
      final paymentRows = await db.rawQuery(
        'SELECT invoice_id, receipt_number, amount_paid, date_paid, '
        'payment_method, notes '
        "FROM invoice_payments WHERE invoice_id IN ($ph) AND cheque_status NOT IN ('bounced', 'cancelled') "
        'ORDER BY date_paid ASC, rowid ASC',
        ids,
      );
      final invoicesById = {for (final r in currencyRows) r.id: r};
      final drafts = <_StatementLineDraft>[];
      double opening = 0;
      double invoiced = 0;
      double paid = 0;
      double overdue = 0;

      for (final invoice in currencyRows) {
        if (invoice.date.compareTo(f) < 0) {
          opening += invoice.total;
        } else if (invoice.date.compareTo(t) <= 0) {
          invoiced += invoice.total;
          drafts.add(_StatementLineDraft(
            date: invoice.date,
            order: 0,
            type: 'Invoice',
            reference: invoice.id,
            description: 'Invoice raised',
            debit: invoice.total,
            credit: 0,
          ));
        }

        final dueDate = invoice.dueDate;
        if (InvoiceCalculator.isOverdue(
          dueDate: dueDate == null ? null : DateTime.tryParse(dueDate),
          outstanding: invoice.outstanding,
        )) {
          overdue += invoice.outstanding;
        }
      }

      for (final payment in paymentRows) {
        final invoice = invoicesById[payment['invoice_id'] as String];
        if (invoice == null) continue;
        final date = payment['date_paid'] as String? ?? '';
        final amount = (payment['amount_paid'] as num?)?.toDouble() ?? 0;
        if (date.compareTo(f) < 0) {
          opening -= amount;
        } else if (date.compareTo(t) <= 0) {
          paid += amount;
          final method = payment['payment_method'] as String?;
          drafts.add(_StatementLineDraft(
            date: date,
            order: 1,
            type: 'Payment',
            reference: payment['receipt_number'] as String? ?? invoice.id,
            description: method == null || method.isEmpty
                ? 'Payment for ${invoice.id}'
                : 'Payment for ${invoice.id} ($method)',
            debit: 0,
            credit: amount,
          ));
        }
      }

      drafts.sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        if (byDate != 0) return byDate;
        return a.order.compareTo(b.order);
      });

      var running = opening;
      final lines = drafts.map((draft) {
        running += draft.debit - draft.credit;
        return CustomerStatementLine(
          date: draft.date,
          type: draft.type,
          reference: draft.reference,
          description: draft.description,
          debit: draft.debit,
          credit: draft.credit,
          balance: running,
        );
      }).toList();

      statements.add(CustomerStatement(
        customerKey: customerKey,
        customerName: currencyRows.first.customerName,
        currencyCode: entry.key,
        currencySymbol: currencyRows.first.currencySymbol,
        openingBalance: opening,
        invoiced: invoiced,
        paid: paid,
        closingBalance: running,
        overdueBalance: overdue,
        lines: lines,
      ));
    }

    statements.sort((a, b) => a.currencyCode.compareTo(b.currencyCode));
    return statements;
  }

  // ── 7. Top products ───────────────────────────────────────────────────────

  static Future<List<TopProduct>> getTopProducts(
    DateTime from,
    DateTime to, {
    int limit = 500,
    String? currencyCode,
    bool rankByProfit = false,
  }) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final ccFilter = currencyCode != null ? 'AND i.currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
      limit,
    ];
    final orderBy = rankByProfit
        ? '(SUM($_invoiceItemTaxableNetSql) - SUM(ii.quantity * ii.product_purchase_price))'
        : 'revenue';
    final rows = await db.rawQuery(
      "SELECT ii.product_name, "
      "SUM(ii.quantity) AS units_sold, "
      "SUM($_invoiceItemTaxableNetSql) AS revenue, "
      "SUM($_invoiceItemDiscountSql) AS discount_given, "
      "SUM(ii.quantity * ii.product_purchase_price) AS cogs "
      "FROM invoice_items ii "
      "JOIN invoices i ON i.id = ii.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type = 'Invoice' "
      "$ccFilter"
      "AND i.date >= ? AND i.date <= ? "
      "GROUP BY ii.product_name ORDER BY $orderBy DESC LIMIT ?",
      args,
    );
    return rows
        .map((r) => TopProduct(
              name: r['product_name'] as String? ?? 'Unknown',
              unitsSold: (r['units_sold'] as num).toDouble(),
              revenue: (r['revenue'] as num).toDouble(),
              discountGiven: (r['discount_given'] as num).toDouble(),
              cogs: (r['cogs'] as num?)?.toDouble() ?? 0.0,
            ))
        .toList();
  }

  // ── 8. Quotation conversion ───────────────────────────────────────────────

  static Future<QuotationStats> getQuotationStats(
    DateTime from,
    DateTime to, {
    String? currencyCode,
  }) async {
    final db = await _db.database;
    final f = AppDate.dateKeyStart(from);
    final t = AppDate.dateKeyEnd(to);
    final currencyFilter = currencyCode != null ? 'AND currency_code = ? ' : '';
    final args = <Object?>[
      if (currencyCode != null) currencyCode,
      f,
      t,
    ];

    final qr = await db.rawQuery(
      "SELECT COUNT(*) AS cnt FROM invoices "
      "WHERE type = 'Quotation' AND deleted_at IS NULL "
      "$currencyFilter"
      "AND date >= ? AND date <= ?",
      args,
    );
    final quotationsIssued = (qr.first['cnt'] as int?) ?? 0;

    final ir = await db.rawQuery(
      "SELECT COUNT(*) AS cnt FROM invoices "
      "WHERE type = 'Invoice' AND deleted_at IS NULL "
      "$currencyFilter"
      "AND date >= ? AND date <= ?",
      args,
    );
    final invoicesInPeriod = (ir.first['cnt'] as int?) ?? 0;

    final rate = quotationsIssued == 0
        ? 0.0
        : (invoicesInPeriod / quotationsIssued * 100).clamp(0.0, 100.0);

    return QuotationStats(
      quotationsIssued: quotationsIssued,
      invoicesInPeriod: invoicesInPeriod,
      conversionRate: rate,
    );
  }

  // ── CSV export helpers ─────────────────────────────────────────────────────

  static String exportDailyReportCsv(List<DailyPoint> rows) {
    return buildQuotedCsv([
      ['Date', 'Invoices', 'Sales', 'COGS', 'Profit', 'Margin %'],
      for (final d in rows)
        [
          d.date,
          d.invoiceCount,
          d.billed.toStringAsFixed(2),
          d.cogs.toStringAsFixed(2),
          d.profit.toStringAsFixed(2),
          d.marginPercent.toStringAsFixed(1),
        ],
    ]);
  }

  static String exportTrendCsv(List<MonthlyPoint> trend) {
    return buildQuotedCsv([
      ['Month', 'Billed', 'Collected', 'Profit'],
      for (final p in trend)
        [
          p.month,
          p.billed.toStringAsFixed(2),
          p.collected.toStringAsFixed(2),
          p.profit.toStringAsFixed(2),
        ],
    ]);
  }

  static String exportTopCustomersCsv(List<TopCustomer> list) {
    return buildQuotedCsv([
      ['Customer', 'Invoices', 'Billed', 'Collected', 'Outstanding'],
      for (final c in list)
        [
          c.name,
          c.invoiceCount,
          c.billed.toStringAsFixed(2),
          c.collected.toStringAsFixed(2),
          c.outstanding.toStringAsFixed(2),
        ],
    ]);
  }

  static String exportCustomerStatementsCsv(
      List<CustomerStatement> statements) {
    final blocks = <String>[];
    for (final statement in statements) {
      blocks.add(buildQuotedCsv([
        [
          'Customer',
          statement.customerName,
          'Currency',
          statement.currencyCode
        ],
        ['Opening Balance', statement.openingBalance.toStringAsFixed(2)],
        ['Invoiced', statement.invoiced.toStringAsFixed(2)],
        ['Paid', statement.paid.toStringAsFixed(2)],
        ['Closing Balance', statement.closingBalance.toStringAsFixed(2)],
        ['Overdue Balance', statement.overdueBalance.toStringAsFixed(2)],
        [
          'Date',
          'Type',
          'Reference',
          'Description',
          'Debit',
          'Credit',
          'Balance'
        ],
        for (final line in statement.lines)
          [
            line.date,
            line.type,
            line.reference,
            line.description,
            line.debit.toStringAsFixed(2),
            line.credit.toStringAsFixed(2),
            line.balance.toStringAsFixed(2),
          ],
      ]));
    }
    return blocks.join('\n\n');
  }

  static String exportTopProductsCsv(List<TopProduct> list) {
    return buildQuotedCsv([
      [
        'SL',
        'Product',
        'Units Sold',
        'Revenue',
        'Discount Given',
        'Profit',
        'Margin %'
      ],
      for (var i = 0; i < list.length; i++)
        [
          i + 1,
          list[i].name,
          list[i].unitsSold.toStringAsFixed(2),
          list[i].revenue.toStringAsFixed(2),
          list[i].discountGiven.toStringAsFixed(2),
          list[i].profit.toStringAsFixed(2),
          list[i].marginPercent.toStringAsFixed(1),
        ],
    ]);
  }

  static String exportAgedReceivablesCsv(List<AgedReceivable> list) {
    return buildQuotedCsv([
      ['Invoice ID', 'Customer', 'Outstanding', 'Days Overdue'],
      for (final r in list)
        [
          r.invoiceId,
          r.customerName,
          r.outstanding.toStringAsFixed(2),
          r.daysOverdue,
        ],
    ]);
  }

  static String exportTaxCsv(List<TaxBucket> list) {
    return buildQuotedCsv([
      ['Tax Rate (%)', 'Tax Collected'],
      for (final b in list)
        [b.rate.toStringAsFixed(0), b.taxCollected.toStringAsFixed(2)],
    ]);
  }

  // ── 9. Invoice status list ─────────────────────────────────────────────────

  static Future<List<InvoiceStatusRow>> getInvoiceStatusList(
    DateTime from,
    DateTime to, {
    String? currencyCode,
  }) async {
    final rows = await _loadRows(
      from: from,
      to: to,
      currencyCode: currencyCode,
    );
    final now = DateTime.now();
    final result = rows.map((r) {
      final dueDate = r.dueDate != null ? DateTime.tryParse(r.dueDate!) : null;
      final noDueDate = r.dueDate == null;
      final daysOverdue =
          InvoiceCalculator.daysOverdue(dueDate: dueDate, asOf: now);

      final status = switch (
          InvoiceCalculator.paymentStatus(total: r.total, paid: r.paid)) {
        PaymentStatus.paid => 'Paid',
        PaymentStatus.partial => 'Partial',
        PaymentStatus.unpaid => 'Unpaid',
      };

      final isOverdue = InvoiceCalculator.isOverdue(
        dueDate: dueDate,
        outstanding: r.outstanding,
        asOf: now,
      );

      return InvoiceStatusRow(
        id: r.id,
        date: r.date,
        dueDate: r.dueDate,
        customerName: r.customerName,
        total: r.total,
        paid: r.paid,
        outstanding: r.outstanding,
        daysOverdue: daysOverdue,
        hasNoDueDate: noDueDate,
        status: status,
        isOverdue: isOverdue,
      );
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  static String exportInvoiceStatusCsv(List<InvoiceStatusRow> list) {
    return buildQuotedCsv([
      [
        'Date',
        'Invoice ID',
        'Customer',
        'Total',
        'Paid',
        'Outstanding',
        'Status',
        'Days Overdue',
      ],
      for (final r in list)
        [
          r.date,
          r.id,
          r.customerName,
          r.total.toStringAsFixed(2),
          r.paid.toStringAsFixed(2),
          r.outstanding.toStringAsFixed(2),
          r.status,
          r.hasNoDueDate ? '' : r.daysOverdue,
        ],
    ]);
  }

  // ── PDF export ──────────────────────────────────────────────────────────────

  static Future<Uint8List> exportDailyReportPdf(
    List<DailyPoint> rows, {
    required String currencySymbol,
    required String dateRangeLabel,
    bool showFooterBranding = true,
  }) async {
    final theme = await PdfFontService.loadTheme();
    final doc = pw.Document(theme: theme);
    final company = await BackendServices.companyInfo.getCompanyInfo();
    final dateFmt = (await BackendServices.settings.getDateFormat()).key;
    final generatedOn = DateFormat(dateFmt).format(DateTime.now());

    String money(double v) => '$currencySymbol ${v.toStringAsFixed(2)}';
    final totalInvoices = rows.fold<int>(0, (a, d) => a + d.invoiceCount);
    final totalSales = rows.fold<double>(0, (a, d) => a + d.billed);
    final totalCogs = rows.fold<double>(0, (a, d) => a + d.cogs);
    final totalProfit = totalSales - totalCogs;
    final totalMargin =
        totalSales == 0 ? 0.0 : (totalProfit / totalSales) * 100;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            PdfReportHeader.build(
                company: company,
                title: 'DAILY SALES & PROFIT REPORT',
                generatedOn: generatedOn),
            pw.Text(dateRangeLabel,
                style:
                    const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            pw.SizedBox(height: 12),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 16),
          child: pw.Text(
            showFooterBranding
                ? "Page ${context.pageNumber} of ${context.pagesCount}  -  Generated by Apex Books"
                : "Page ${context.pageNumber} of ${context.pagesCount}",
            style: pw.TextStyle(
                fontSize: PdfLayout.footerBrandingFontSize,
                color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: [
              'SL',
              'Date',
              'Invoices',
              'Sales',
              'COGS',
              'Profit',
              'Margin %'
            ],
            data: List<List<String>>.generate(rows.length, (i) {
              final d = rows[i];
              return [
                '${i + 1}',
                d.date,
                '${d.invoiceCount}',
                money(d.billed),
                money(d.cogs),
                money(d.profit),
                '${d.marginPercent.toStringAsFixed(1)}%',
              ];
            }),
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 9,
                color: PdfColors.white),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerDecoration:
                const pw.BoxDecoration(color: PdfReportHeader.accentColor),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.centerRight,
              5: pw.Alignment.centerRight,
              6: pw.Alignment.centerRight,
            },
            cellHeight: 22,
            oddRowDecoration:
                const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF8FAFC)),
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text(
                  'Total — Invoices: $totalInvoices   Sales: ${money(totalSales)}   '
                  'COGS: ${money(totalCogs)}   Profit: ${money(totalProfit)}   '
                  'Margin: ${totalMargin.toStringAsFixed(1)}%',
                  style: pw.TextStyle(
                      fontSize: 10, fontWeight: pw.FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return doc.save();
  }

  // ── Day book / cash flow / P&L / cheques / expiries (v46 reports) ────────

  /// Every cash event in the period. Purchase bills are not cash events;
  /// their separately recorded payments are included instead.
  static Future<List<DayBookEntry>> getDayBook(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    final rows = <DayBookEntry>[];

    final payRows = await db.rawQuery('''
      SELECT date_paid AS d, invoice_number, customer_name,
             SUM(amount_paid) AS amt
      FROM invoice_payments
      JOIN invoices i ON i.id = invoice_payments.invoice_id
      WHERE i.deleted_at IS NULL AND i.type = 'Invoice'
        AND invoice_payments.cheque_status NOT IN ('bounced', 'cancelled')
        AND date_paid >= ? AND date_paid <= ?
        ${currencyCode == null ? '' : 'AND i.currency_code = ?'}
      GROUP BY substr(date_paid, 1, 10), invoice_number
      ORDER BY d
    ''', [
      from.toIso8601String(),
      to.toIso8601String(),
      if (currencyCode != null) currencyCode
    ]);
    for (final r in payRows) {
      rows.add(DayBookEntry(
        date: DateTime.tryParse(r['d'] as String? ?? '') ?? from,
        description:
            'Receipt — ${r['customer_name'] ?? ''} (#${r['invoice_number'] ?? ''})',
        moneyIn: (r['amt'] as num?)?.toDouble() ?? 0,
        moneyOut: 0,
      ));
    }

    final expRows = await db.rawQuery('''
      SELECT e.date, e.description, e.amount FROM expenses e
      LEFT JOIN financial_accounts a ON a.id = e.account_id
      WHERE e.date >= ? AND e.date <= ?
      ${currencyCode == null ? '' : 'AND COALESCE(a.currency_code, \'INR\') = ?'}
      ORDER BY e.date
    ''', [
      from.toIso8601String(),
      to.toIso8601String(),
      if (currencyCode != null) currencyCode
    ]);
    for (final r in expRows) {
      rows.add(DayBookEntry(
        date: DateTime.tryParse(r['date'] as String? ?? '') ?? from,
        description: 'Expense — ${r['description'] ?? ''}',
        moneyIn: 0,
        moneyOut: (r['amount'] as num?)?.toDouble() ?? 0,
      ));
    }

    final pbRows = await db.rawQuery('''
      SELECT p.date_paid AS date, b.supplier_name, p.amount_paid
      FROM purchase_bill_payments p
      JOIN purchase_bills b ON b.id = p.purchase_bill_id
      WHERE p.date_paid >= ? AND p.date_paid <= ?
        ${currencyCode == null ? '' : 'AND b.currency_code = ?'}
      ORDER BY p.date_paid
    ''', [
      from.toIso8601String(),
      to.toIso8601String(),
      if (currencyCode != null) currencyCode
    ]);
    for (final r in pbRows) {
      rows.add(DayBookEntry(
        date: DateTime.tryParse(r['date'] as String? ?? '') ?? from,
        description: 'Purchase payment — ${r['supplier_name'] ?? ''}',
        moneyIn: 0,
        moneyOut: (r['amount_paid'] as num?)?.toDouble() ?? 0,
      ));
    }

    rows.sort((a, b) => a.date.compareTo(b.date));
    return rows;
  }

  /// ACCRUAL-basis P&L, matching LedgerService.getBalanceSheet netProfit
  /// (Sales − Purchases − Expenses on document dates, not payment dates).
  /// `revenue` is net sales (total − tax) for Invoice + Debit Note minus
  /// Credit Note in the period; `purchases` is bill net (total − total_tax)
  /// for ITC-eligible bills (RC uses net too — its tax is a self-assessed
  /// Input/Output pair) or the full total for ITC-ineligible bills.
  /// `collected` (invoice receipts incl. note-linked payments) and `paid`
  /// (purchase-bill payments) are cash memo fields, excluded from profit.
  static Future<PnlSummary> getPnl(DateTime from, DateTime to,
      {String? currencyCode}) async {
    final db = await _db.database;
    // Revenue: same domain calculator as the ledger (InvoiceService), so
    // accrual revenue here always agrees with ledger Sales.
    final allInvoices = await InvoiceService.getAllInvoices();
    double revenue = 0;
    for (final inv in allInvoices) {
      if (inv.date.isBefore(from) || inv.date.isAfter(to)) continue;
      if (currencyCode != null && inv.currencyCode != currencyCode) continue;
      final net = inv.total - inv.tax;
      if (inv.type == 'Invoice' || inv.type == 'Debit Note') {
        revenue += net;
      } else if (inv.type == 'Credit Note') {
        revenue -= net;
      }
    }
    final expRes = await db.rawQuery(
      "SELECT COALESCE(SUM(e.amount), 0) AS v FROM expenses e "
      "LEFT JOIN financial_accounts a ON a.id = e.account_id "
      "WHERE e.date >= ? AND e.date <= ? "
      "${currencyCode == null ? '' : 'AND COALESCE(a.currency_code, \'INR\') = ?'}",
      [
        from.toIso8601String(),
        to.toIso8601String(),
        if (currencyCode != null) currencyCode
      ],
    );
    // Purchases accrual mirrors the ledger ITC rules: eligible (incl. RC)
    // contributes net, ineligible contributes the full total.
    final billRows = await db.rawQuery(
      "SELECT total_amount, total_tax, itc_eligible, reverse_charge, currency_code "
      "FROM purchase_bills WHERE date >= ? AND date <= ? "
      "${currencyCode == null ? '' : 'AND currency_code = ?'}",
      [
        from.toIso8601String(),
        to.toIso8601String(),
        if (currencyCode != null) currencyCode
      ],
    );
    double purchases = 0;
    for (final b in billRows) {
      final total = (b['total_amount'] as num?)?.toDouble() ?? 0;
      final tax = (b['total_tax'] as num?)?.toDouble() ?? 0;
      final eligible = (b['itc_eligible'] as int? ?? 1) == 1;
      purchases += eligible ? total - tax : total;
    }
    final pbRes = await db.rawQuery(
      "SELECT COALESCE(SUM(p.amount_paid), 0) AS v FROM purchase_bill_payments p "
      "JOIN purchase_bills b ON b.id = p.purchase_bill_id "
      "WHERE p.date_paid >= ? AND p.date_paid <= ? "
      "AND p.cheque_status NOT IN ('bounced', 'cancelled') "
      "${currencyCode == null ? '' : 'AND b.currency_code = ?'}",
      [
        from.toIso8601String(),
        to.toIso8601String(),
        if (currencyCode != null) currencyCode
      ],
    );
    // Cash memo: receipts for invoices AND credit/debit notes.
    final collectedRes = await db.rawQuery(
      "SELECT COALESCE(SUM(p.amount_paid), 0) AS v FROM invoice_payments p "
      "JOIN invoices i ON i.id = p.invoice_id "
      "WHERE i.deleted_at IS NULL AND i.type IN ('Invoice', 'Credit Note', 'Debit Note') "
      "AND p.date_paid >= ? AND p.date_paid <= ? "
      "AND p.cheque_status NOT IN ('bounced', 'cancelled') "
      "${currencyCode == null ? '' : 'AND i.currency_code = ?'}",
      [
        from.toIso8601String(),
        to.toIso8601String(),
        if (currencyCode != null) currencyCode
      ],
    );
    final expenses = (expRes.first['v'] as num?)?.toDouble() ?? 0;
    final paid = (pbRes.first['v'] as num?)?.toDouble() ?? 0;
    final collected = (collectedRes.first['v'] as num?)?.toDouble() ?? 0;
    return PnlSummary(
      revenue: revenue,
      expenses: expenses,
      purchases: purchases,
      collected: collected,
      paid: paid,
    );
  }

  /// Payments made by cheque — uncleared first (PDC tracking).
  static Future<List<ChequeEntry>> getCheques() async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT c.source_id AS invoice_payment_id, p.invoice_id,
             p.invoice_number, i.customer_name, c.amount AS amount_paid,
             c.cheque_number, c.cheque_date,
             CASE WHEN c.status = 'cleared' THEN 1 ELSE 0 END AS cheque_cleared
      FROM cheques c
      JOIN invoice_payments p ON p.id = c.source_id
      JOIN invoices i ON i.id = p.invoice_id
      WHERE c.direction = 'received'
        AND c.status NOT IN ('bounced', 'cancelled')
      ORDER BY cheque_cleared ASC, c.cheque_date ASC
    ''');
    return rows.map((r) {
      return ChequeEntry(
        invoiceId: r['invoice_id'] as String? ?? '',
        invoiceNumber: r['invoice_number'] as String? ?? '',
        customerName: r['customer_name'] as String? ?? '',
        amount: (r['amount_paid'] as num?)?.toDouble() ?? 0,
        chequeNumber: r['cheque_number'] as String? ?? '',
        chequeDate: DateTime.tryParse(r['cheque_date'] as String? ?? ''),
        cleared: (r['cheque_cleared'] as int? ?? 0) == 1,
      );
    }).toList();
  }

  static Future<void> markChequeCleared(
      String invoiceId, String chequeNumber) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT c.id FROM cheques c
      JOIN invoice_payments p ON p.id = c.source_id
      WHERE p.invoice_id = ? AND c.cheque_number = ?
      LIMIT 1
    ''', [invoiceId, chequeNumber]);
    if (rows.isEmpty) return;
    final banks = await AccountingService.getAccounts(type: 'bank');
    if (banks.isEmpty) throw StateError('Create a bank account first');
    await AccountingService.transitionCheque(
        chequeId: rows.first['id'] as String,
        status: 'cleared',
        bankAccountId: banks.first.id);
  }

  /// Product metadata batches/expiries within [days].
  static Future<List<ExpiryRow>> getExpiringBatches({int days = 90}) async {
    final db = await _db.database;
    final limit = DateTime.now().add(Duration(days: days)).toIso8601String();
    return db.rawQuery('''
      SELECT p.name AS product_name, pm.batch_number, pm.expiry_date,
             pm.storage_location
      FROM product_metadata pm
      JOIN products p ON p.id = pm.product_id
      WHERE pm.expiry_date IS NOT NULL AND pm.expiry_date != ''
        AND pm.expiry_date <= ?
      ORDER BY pm.expiry_date ASC
    ''', [limit]).then((rows) {
      return rows
          .map((r) => ExpiryRow(
                productName: r['product_name'] as String? ?? '',
                batchNumber: r['batch_number'] as String? ?? '',
                expiryDate:
                    DateTime.tryParse(r['expiry_date'] as String? ?? ''),
                storageLocation: r['storage_location'] as String? ?? '',
              ))
          .toList();
    });
  }
}

/// One day's money movement for the day book / cash flow view.
class DayBookEntry {
  final DateTime date;
  final String description;
  final double moneyIn;
  final double moneyOut;
  const DayBookEntry({
    required this.date,
    required this.description,
    required this.moneyIn,
    required this.moneyOut,
  });
}

class PnlSummary {
  /// Accrual net sales (Invoice + Debit Note − Credit Note, total − tax).
  final double revenue;
  final double expenses;

  /// Accrual purchases: eligible bill net, ineligible bill full total.
  final double purchases;

  /// Cash memo: invoice receipts collected (incl. note-linked payments).
  final double collected;

  /// Cash memo: purchase-bill payments paid.
  final double paid;
  const PnlSummary({
    required this.revenue,
    required this.expenses,
    required this.purchases,
    required this.collected,
    this.paid = 0,
  });

  /// Accrual profit, equals LedgerService BalanceSheet.netProfit.
  double get profit => revenue - expenses - purchases;
}

class ChequeEntry {
  final String invoiceId;
  final String invoiceNumber;
  final String customerName;
  final double amount;
  final String chequeNumber;
  final DateTime? chequeDate;
  final bool cleared;
  const ChequeEntry({
    required this.invoiceId,
    required this.invoiceNumber,
    required this.customerName,
    required this.amount,
    required this.chequeNumber,
    required this.chequeDate,
    required this.cleared,
  });
}

class ExpiryRow {
  final String productName;
  final String batchNumber;
  final DateTime? expiryDate;
  final String storageLocation;
  const ExpiryRow({
    required this.productName,
    required this.batchNumber,
    required this.expiryDate,
    required this.storageLocation,
  });
}
