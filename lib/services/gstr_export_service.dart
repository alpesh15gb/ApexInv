import 'dart:convert';

import 'package:intl/intl.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
import 'package:apexbooks/models/additional_cost.dart';
import 'package:apexbooks/services/backend_services.dart';

/// GSTR CSV exports shaped for the GST Offline Tool (GSTN's desktop utility).
///
/// The tool imports ONE CSV per section; it computes IGST vs CGST/SGST
/// itself from Place of Supply vs the supplier state (taken from the GSTIN
/// you log in with), so B2B/B2CL/B2CS templates carry rate-wise taxable
/// value only. HSN carries explicit tax columns.
///
/// Classification:
///  - B2B  : recipient GSTIN present
///  - B2CL : no GSTIN, inter-state, invoice value > 2,50,000
///  - B2CS : everything else (intra-state / small B2C)
///
/// Place of Supply = first 2 digits of the recipient GSTIN; unregistered
/// buyers fall back to the supplier state (from the company GSTIN) — flagged
/// in the UI since true ship-to state isn't captured for walk-in customers.
///
/// GSTR-2 needs inward tax invoices with supplier GSTINs, which the app
/// does not model (expenses/purchase orders carry no GST party data) — not
/// exportable until purchase billing exists.
class GstrExportService {
  static const _stateCodes = {
    '01',
    '02',
    '03',
    '04',
    '05',
    '06',
    '07',
    '08',
    '09',
    '10',
    '11',
    '12',
    '13',
    '14',
    '15',
    '16',
    '17',
    '18',
    '19',
    '20',
    '21',
    '22',
    '23',
    '24',
    '26',
    '27',
    '29',
    '30',
    '31',
    '32',
    '33',
    '34',
    '35',
    '36',
    '37',
    '38',
    '97',
  };

  static String _fmtDate(DateTime d) => DateFormat('dd-MMM-yy').format(d);

  static String _n2(num v) => v.toStringAsFixed(2);

  /// B2CL threshold: interstate B2C invoices with value above this go to
  /// B2CL, the rest to B2CS.
  static const double _b2clThreshold = 250000;

  static TaxMode _taxModeOf(Map<String, dynamic> inv) =>
      TaxModeExtension.fromKey(inv['tax_mode'] as String?);

  static double _globalRateFractionOf(Map<String, dynamic> inv) =>
      (inv['tax_rate'] as num?)?.toDouble() ?? 0.0;

  static double _additionalCostsOf(Map<String, dynamic> inv) =>
      AdditionalCost.listFromJson(inv['additional_costs'] as String?)
          .fold(0.0, (s, c) => s + c.amount);

  static InvoiceDiscountType _discountTypeOf(Map<String, dynamic> inv) =>
      InvoiceDiscountTypeExtension.fromKey(
          inv['invoice_discount_type'] as String?);

  static double _discountValueOf(Map<String, dynamic> inv) =>
      (inv['invoice_discount_value'] as num?)?.toDouble() ?? 0.0;

  static DateTime _dateOf(Map<String, dynamic> inv) {
    final v = inv['date'];
    if (v is DateTime) return v;
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  static InvoiceTotals _totalsOf(Map<String, dynamic> inv) {
    final rawItems = inv['items'] as List? ?? const [];
    final lines = <InvoiceLineAmount>[];
    for (final e in rawItems) {
      if (e is Map<String, dynamic> && e['amount'] is InvoiceLineAmount) {
        lines.add(e['amount'] as InvoiceLineAmount);
      } else if (e is Map && e['amount'] is InvoiceLineAmount) {
        lines.add(e['amount'] as InvoiceLineAmount);
      }
    }
    return InvoiceTotalsCalculator.totals(
      lines: lines,
      taxMode: _taxModeOf(inv),
      globalTaxRate: _globalRateFractionOf(inv),
      globalTaxRateFormat: TaxRateFormat.fraction,
      additionalCostsTotal: _additionalCostsOf(inv),
      invoiceDiscountType: _discountTypeOf(inv),
      invoiceDiscountValue: _discountValueOf(inv),
    );
  }

  static double _invoiceValueOf(Map<String, dynamic> inv) =>
      _totalsOf(inv).total;

  /// Rate-wise GSTR figures for one invoice, consistent with the ledger
  /// (taxable + exempt = net, net + tax = total).
  ///
  /// - global mode: every line taxed at the invoice global rate; the single
  ///   bucket holds [net] as taxable and [tax] as tax.
  /// - per-item mode: lines grouped by their own product rate.
  /// - none / zero rate: everything is exempt.
  /// Invoice-level discount and additional costs are folded into [net] via
  /// [_totalsOf] and spread across lines proportionally to their base
  /// taxable share (line net proportion of subtotal); per-line tax amounts
  /// are NOT rescaled by the discount (tax is computed pre-discount, matching
  /// [InvoiceTotalsCalculator]).
  static _GstrFigures _figuresForInvoice(Map<String, dynamic> inv,
      [InvoiceTotals? cachedTotals]) {
    final taxMode = _taxModeOf(inv);
    final globalFraction = _globalRateFractionOf(inv);
    final globalPercent = globalFraction * 100;
    final rawItems = inv['items'] as List? ?? const [];
    final entries = <Map<String, dynamic>>[];
    final amounts = <InvoiceLineAmount>[];
    for (final e in rawItems) {
      if (e is Map<String, dynamic> && e['amount'] is InvoiceLineAmount) {
        entries.add(e);
        amounts.add(e['amount'] as InvoiceLineAmount);
      } else if (e is Map && e['amount'] is InvoiceLineAmount) {
        final m = Map<String, dynamic>.from(e);
        entries.add(m);
        amounts.add(m['amount'] as InvoiceLineAmount);
      }
    }
    final totals = cachedTotals ?? _totalsOf(inv);
    final total = totals.total;
    final tax = totals.tax;
    double net = total - tax;
    if (net < 0) net = 0;
    if (!(net.isFinite)) net = 0;
    final subtotalAll = amounts.fold(0.0, (s, a) => s + a.lineTotal);
    const eps = 1e-9;
    final taxableByRate = <int, double>{};
    final taxByRate = <int, double>{};
    double exempt = 0;
    final hsnLines = <_LineTax>[];
    final interstate = (inv['is_interstate'] as int? ?? 0) == 1;

    String hsnOf(Map<String, dynamic> row) =>
        ((row['product_hsn_code'] as String? ??
                row['hsncode'] as String? ??
                ''))
            .trim();
    String unitOf(Map<String, dynamic> row) =>
        (row['unit'] as String? ?? row['product_unit'] as String? ?? '');
    String descOf(Map<String, dynamic> row) =>
        row['product_name'] as String? ?? '';
    double qtyOf(Map<String, dynamic> row) =>
        (row['quantity'] as num?)?.toDouble() ?? 0;

    if (subtotalAll <= eps) {
      // Degenerate (no taxable base): keep ledger identity by reporting net
      // as a single bucket when a positive global rate applies, else exempt.
      if (net > eps) {
        if (taxMode == TaxMode.global && globalPercent > 0) {
          final bucket = globalPercent.round();
          taxableByRate[bucket] = net;
          taxByRate[bucket] = 0;
          if (entries.isEmpty) {
            // No lines at all: nothing for HSN.
          } else {
            final perLine = net / entries.length;
            for (final entry in entries) {
              final row = (entry['row'] as Map<String, dynamic>? ??
                  <String, dynamic>{});
              hsnLines.add(_LineTax(
                hsn: hsnOf(row),
                description: descOf(row),
                unit: unitOf(row),
                qty: qtyOf(row),
                rate: globalPercent,
                taxable: perLine,
                tax: 0,
                interstate: interstate,
              ));
            }
          }
        } else {
          exempt = net;
          for (final entry in entries) {
            final row =
                (entry['row'] as Map<String, dynamic>? ?? <String, dynamic>{});
            final perLine = net / entries.length;
            hsnLines.add(_LineTax(
              hsn: hsnOf(row),
              description: descOf(row),
              unit: unitOf(row),
              qty: qtyOf(row),
              rate: 0,
              taxable: perLine,
              tax: 0,
              interstate: interstate,
            ));
          }
        }
      } else {
        for (final entry in entries) {
          final row =
              (entry['row'] as Map<String, dynamic>? ?? <String, dynamic>{});
          hsnLines.add(_LineTax(
            hsn: hsnOf(row),
            description: descOf(row),
            unit: unitOf(row),
            qty: qtyOf(row),
            rate: taxMode == TaxMode.global
                ? globalPercent
                : (taxMode == TaxMode.perItem
                    ? (entry['amount'] as InvoiceLineAmount).taxRatePercent
                    : 0),
            taxable: 0,
            tax: 0,
            interstate: interstate,
          ));
        }
      }
      return _GstrFigures(
        total: total,
        tax: tax,
        net: net,
        taxableByRate: taxableByRate,
        taxByRate: taxByRate,
        exempt: exempt,
        hsnLines: hsnLines,
      );
    }

    final factor = net / subtotalAll;
    for (final entry in entries) {
      final row =
          (entry['row'] as Map<String, dynamic>? ?? <String, dynamic>{});
      final amount = entry['amount'] as InvoiceLineAmount;
      final base = amount.lineTotal;
      final adjusted = base * factor;
      double effectiveRate;
      double lineTax;
      int bucket;
      if (taxMode == TaxMode.global) {
        effectiveRate = globalPercent;
        bucket = globalPercent.round();
        lineTax = base * globalFraction;
      } else if (taxMode == TaxMode.perItem) {
        effectiveRate = amount.taxRatePercent;
        bucket = amount.taxRatePercent.toInt();
        lineTax = amount.itemTax;
      } else {
        effectiveRate = 0;
        bucket = 0;
        lineTax = 0;
      }
      hsnLines.add(_LineTax(
        hsn: hsnOf(row),
        description: descOf(row),
        unit: unitOf(row),
        qty: qtyOf(row),
        rate: effectiveRate,
        taxable: adjusted,
        tax: lineTax,
        interstate: interstate,
      ));
      if (effectiveRate <= 0) {
        exempt += adjusted;
      } else {
        taxableByRate[bucket] = (taxableByRate[bucket] ?? 0) + adjusted;
        taxByRate[bucket] = (taxByRate[bucket] ?? 0) + lineTax;
      }
    }
    return _GstrFigures(
      total: total,
      tax: tax,
      net: net,
      taxableByRate: taxableByRate,
      taxByRate: taxByRate,
      exempt: exempt,
      hsnLines: hsnLines,
    );
  }

  /// Builds every GSTR-1 section CSV for the period.
  static Future<List<GstrFile>> buildGstr1({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _loadPeriod(from, to);
    if (data.supplierStateCode == null) {
      throw GstrExportException(
          'Set your company GSTIN in Company Info first — it supplies the '
          'supplier state the Offline Tool needs.');
    }
    final pos = data.supplierStateCode!;

    final b2bRows = <List<dynamic>>[
      [
        'GSTIN of Recipient',
        'Receiver Name',
        'Invoice Number',
        'Invoice date',
        'Invoice Value',
        'Place of Supply',
        'Reverse Charge',
        'Applicable % of Tax Rate',
        'Rate',
        'Taxable Value',
        'Cess'
      ],
    ];
    final b2clRows = <List<dynamic>>[
      [
        'GSTIN of Recipient',
        'Receiver Name',
        'Invoice Number',
        'Invoice date',
        'Invoice Value',
        'Place of Supply',
        'Rate',
        'Taxable Value',
        'Cess'
      ],
    ];
    final b2csAgg = <String, List<double>>{}; // 'pos|rate' -> [taxable, cess]
    final hsnAgg = <String,
        List<
            double>>{}; // 'hsn|rate' -> [qty, value, taxable, igst, cgst, sgst, cess]
    final hsnDesc = <String, String>{};

    for (final inv in data.invoices) {
      final interstate = (inv['is_interstate'] as int? ?? 0) == 1;
      final custGstin =
          (inv['customer_gstin'] as String? ?? '').trim().toUpperCase();
      final totals = _totalsOf(inv);
      final figures = _figuresForInvoice(inv, totals);
      final invoiceValue = figures.total;

      // Rate-wise taxable for this invoice: global mode uses the invoice
      // global rate with proportional taxable shares; discount/additional
      // already folded into [figures] so taxable sums to ledger net.
      final rates = figures.taxableByRate;
      final lineTaxes = figures.hsnLines;

      for (final entry in rates.entries) {
        final rate = entry.key;
        final taxable = entry.value;
        if (custGstin.isNotEmpty) {
          final recipientState = _stateFromGstin(custGstin);
          b2bRows.add([
            custGstin,
            inv['customer_name'] ?? '',
            inv['invoice_number'] ?? '',
            _fmtDate(_dateOf(inv)),
            _n2(invoiceValue),
            recipientState,
            'N', // reverse charge
            '0', // applicable % of tax rate
            rate,
            _n2(taxable),
            '0', // cess
          ]);
        } else if (interstate && invoiceValue > _b2clThreshold) {
          b2clRows.add([
            '', // B2CL recipients are unregistered
            inv['customer_name'] ?? '',
            inv['invoice_number'] ?? '',
            _fmtDate(_dateOf(inv)),
            _n2(invoiceValue),
            pos,
            rate,
            _n2(taxable),
            '0',
          ]);
        } else {
          final key = '$pos|$rate';
          final agg = b2csAgg.putIfAbsent(key, () => [0.0, 0.0]);
          agg[0] += taxable;
        }
      }

      // HSN summary (all lines, incl. zero-rated ones at their rate).
      for (final t in lineTaxes) {
        final hsn = t.hsn.isEmpty ? '999999' : t.hsn; // 999999 = services/none
        final key = '$hsn|${t.rate}';
        final agg = hsnAgg.putIfAbsent(key, () => [0, 0, 0, 0, 0, 0, 0]);
        agg[0] += t.qty;
        agg[2] += t.taxable;
        if (t.interstate) {
          agg[3] += t.tax;
        } else {
          agg[4] += t.tax / 2;
          agg[5] += t.tax / 2;
        }
        agg[1] += t.taxable + t.tax;
        hsnDesc[key] = t.description;
      }
    }

    final b2csRows = <List<dynamic>>[
      [
        'Place of Supply',
        'Rate',
        'Taxable Value',
        'Cess',
        'Type(E/N)',
        'E-Commerce GSTIN'
      ],
    ];
    for (final entry in b2csAgg.entries) {
      final parts = entry.key.split('|');
      b2csRows.add(
          [parts[0], num.parse(parts[1]), _n2(entry.value[0]), '0', 'N', '']);
    }

    final hsnRows = <List<dynamic>>[
      [
        'HSN',
        'Description',
        'UQC',
        'Total Quantity',
        'Total Value',
        'Rate',
        'Taxable Value',
        'IGST',
        'CGST',
        'SGST',
        'Cess'
      ],
    ];
    final hsnKeys = hsnAgg.keys.toList()..sort();
    for (final key in hsnKeys) {
      final agg = hsnAgg[key]!;
      final parts = key.split('|');
      final rate = num.parse(parts[1]);
      hsnRows.add([
        parts[0],
        hsnDesc[key] ?? '',
        _uqc(hsnDesc[key] ?? ''),
        _n2(agg[0]),
        _n2(agg[1]),
        rate,
        _n2(agg[2]),
        _n2(agg[3]),
        _n2(agg[4]),
        _n2(agg[5]),
        '0',
      ]);
    }

    return [
      GstrFile(
          filename: _name('gstr1_b2b', from, to),
          csv: _toCsv(b2bRows),
          section: 'GSTR-1 B2B'),
      GstrFile(
          filename: _name('gstr1_b2cl', from, to),
          csv: _toCsv(b2clRows),
          section: 'GSTR-1 B2CL'),
      GstrFile(
          filename: _name('gstr1_b2cs', from, to),
          csv: _toCsv(b2csRows),
          section: 'GSTR-1 B2CS'),
      GstrFile(
          filename: _name('gstr1_hsn', from, to),
          csv: _toCsv(hsnRows),
          section: 'GSTR-1 HSN summary'),
    ];
  }

  /// GSTR-3B is filed as a summary (no offline-tool CSV import) — this
  /// produces the outward-supply figures for Table 3.1 plus real ITC from
  /// purchase bills for Table 4, so they can be keyed into the portal or
  /// cross-checked.
  static Future<GstrFile> buildGstr3bSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _loadPeriod(from, to);
    if (data.supplierStateCode == null) {
      throw GstrExportException(
          'Set your company GSTIN in Company Info first.');
    }

    double taxable = 0, igst = 0, cgst = 0, sgst = 0, exempt = 0;
    for (final inv in data.invoices) {
      final interstate = (inv['is_interstate'] as int? ?? 0) == 1;
      final figures = _figuresForInvoice(inv);
      taxable += figures.taxableTotal;
      exempt += figures.exempt;
      final tax = figures.tax;
      if (interstate) {
        igst += tax;
      } else {
        cgst += tax / 2;
        sgst += tax / 2;
      }
    }

    final itc = await _loadItc(from, to);

    final rows = <List<dynamic>>[
      ['GSTR-3B Summary', _fmtDate(from), 'to', _fmtDate(to)],
      [],
      ['Table 3.1(a) Outward taxable supplies'],
      ['Particulars', 'Taxable Value', 'IGST', 'CGST', 'SGST', 'Cess'],
      [
        '(a) Outward taxable supplies',
        _n2(taxable),
        _n2(igst),
        _n2(cgst),
        _n2(sgst),
        '0'
      ],
      ['(b) Unregistered/composition/exempt', _n2(exempt), '', '', '', ''],
      [],
      ['Table 4 — Eligible ITC (from purchase bills)'],
      ['ITC Type', 'IGST', 'CGST', 'SGST', 'Cess'],
      ['Import of goods', _n2(0), '0', '0', '0'],
      ['Import of services', _n2(0), '0', '0', '0'],
      [
        'Inward supplies liable to reverse charge',
        _n2(itc.rcIgst),
        _n2(itc.rcCgst),
        _n2(itc.rcSgst),
        '0'
      ],
      ['All other ITC', _n2(itc.igst), _n2(itc.cgst), _n2(itc.sgst), '0'],
      [],
      ['Note: enter ITC from invoices missing in the app via the portal.'],
    ];

    return GstrFile(
      filename: _name('gstr3b_summary', from, to),
      csv: _toCsv(rows),
      section: 'GSTR-3B summary',
    );
  }

  /// Inward supplies (purchase bills) as a GSTR-2 B2B-format CSV for the
  /// Offline Tool's invoice-import (for ITC claim records / reconciliation).
  static Future<GstrFile> buildGstr2Csv({
    required DateTime from,
    required DateTime to,
  }) async {
    final itc = await _loadItc(from, to, withRows: true);
    final rows = <List<dynamic>>[
      [
        'GSTIN of Supplier',
        'Supplier Name',
        'Invoice Number',
        'Invoice date',
        'Invoice Value',
        'Place of Supply',
        'Reverse Charge',
        'Rate',
        'Taxable Value',
        'IGST',
        'CGST',
        'SGST',
        'Cess',
        'ITC Eligible'
      ],
      for (final r in itc.rows)
        [
          r.gstin,
          r.supplierName,
          r.billNumber,
          _fmtDate(r.date),
          _n2(r.total),
          r.placeOfSupply,
          r.reverseCharge ? 'Y' : 'N',
          r.rate,
          _n2(r.taxable),
          _n2(r.igst),
          _n2(r.cgst),
          _n2(r.sgst),
          '0',
          r.itcEligible ? (r.reverseCharge ? 'Y (RC)' : 'Y') : 'N',
        ],
    ];
    return GstrFile(
      filename: _name('gstr2_purchase_bills', from, to),
      csv: _toCsv(rows),
      section: 'GSTR-2 purchase bills',
    );
  }

  static Future<ItcTotals> _loadItc(DateTime from, DateTime to,
      {bool withRows = false}) async {
    final db = await DatabaseHelper().database;
    final billRows = await db.rawQuery(
      'SELECT b.*, i.igst, i.cgst, i.sgst, i.taxable_value, i.tax_rate '
      'FROM purchase_bills b '
      'JOIN purchase_bill_items i ON i.purchase_bill_id = b.id '
      'WHERE b.date >= ? AND b.date <= ?',
      [from.toIso8601String(), to.toIso8601String()],
    );
    double igst = 0, cgst = 0, sgst = 0, rcIgst = 0, rcCgst = 0, rcSgst = 0;
    final rows = <ItcRow>[];
    for (final r in billRows) {
      final eligible = (r['itc_eligible'] as int? ?? 1) == 1;
      final rc = (r['reverse_charge'] as int? ?? 0) == 1;
      final iIgst = (r['igst'] as num?)?.toDouble() ?? 0;
      final iCgst = (r['cgst'] as num?)?.toDouble() ?? 0;
      final iSgst = (r['sgst'] as num?)?.toDouble() ?? 0;
      if (eligible) {
        if (rc) {
          rcIgst += iIgst;
          rcCgst += iCgst;
          rcSgst += iSgst;
        } else {
          igst += iIgst;
          cgst += iCgst;
          sgst += iSgst;
        }
      }
      if (withRows) {
        rows.add(ItcRow(
          gstin: r['supplier_gstin'] as String? ?? '',
          supplierName: r['supplier_name'] as String? ?? '',
          billNumber: r['bill_number'] as String? ?? '',
          date: DateTime.tryParse(r['date'] as String? ?? '') ?? DateTime.now(),
          total: (r['total_amount'] as num?)?.toDouble() ?? 0,
          taxable: (r['taxable_value'] as num?)?.toDouble() ?? 0,
          igst: iIgst,
          cgst: iCgst,
          sgst: iSgst,
          rate: (r['tax_rate'] as num?)?.toDouble() ?? 0,
          placeOfSupply: ((r['supplier_gstin'] as String? ?? '')).length >= 2
              ? (r['supplier_gstin'] as String).substring(0, 2)
              : '',
          itcEligible: eligible,
          reverseCharge: rc,
        ));
      }
    }
    return ItcTotals(
      igst: igst,
      cgst: cgst,
      sgst: sgst,
      rcIgst: rcIgst,
      rcCgst: rcCgst,
      rcSgst: rcSgst,
      rows: rows,
    );
  }

  // ── Data loading ──

  static Future<_PeriodData> _loadPeriod(DateTime from, DateTime to,
      {bool withNotes = false}) async {
    final db = await DatabaseHelper().database;
    final info = await BackendServices.companyInfo.getCompanyInfo();
    final companyGstin = (info?.gstin ?? '').trim().toUpperCase();
    final supplierState =
        companyGstin.length >= 2 ? companyGstin.substring(0, 2) : null;

    final invRows = await db.rawQuery(
      "SELECT * FROM invoices "
      "WHERE deleted_at IS NULL AND type = 'Invoice' "
      "AND date >= ? AND date <= ? ORDER BY date",
      [from.toIso8601String(), to.toIso8601String()],
    );
    if (withNotes) {
      final noteRows = await db.rawQuery(
        "SELECT * FROM invoices "
        "WHERE deleted_at IS NULL AND type IN ('Credit Note', 'Debit Note') "
        "AND date >= ? AND date <= ? ORDER BY date",
        [from.toIso8601String(), to.toIso8601String()],
      );
      invRows.addAll(noteRows);
    }

    final result = <Map<String, dynamic>>[];
    for (final inv in invRows) {
      final id = inv['id'] as String;
      final itemRows = await db
          .query('invoice_items', where: 'invoice_id = ?', whereArgs: [id]);
      final taxModeRaw = inv['tax_mode'] as String? ?? 'global';
      final taxMode = TaxModeExtension.fromKey(taxModeRaw);
      final globalRate = ((inv['tax_rate'] as num?)?.toDouble() ?? 0.0) * 100;

      final items = <Map<String, dynamic>>[];
      for (final row in itemRows) {
        final amount = InvoiceTotalsCalculator.lineFromDbRow(
          row,
          taxMode: taxMode,
          globalTaxRatePercent: globalRate,
        );
        items.add({'row': row, 'amount': amount});
      }
      result.add({...inv, 'items': items});
    }
    return _PeriodData(
        invoices: result,
        supplierStateCode: supplierState,
        companyGstin: companyGstin);
  }

  static String? _stateFromGstin(String gstin) {
    if (gstin.length < 2) return null;
    final code = gstin.substring(0, 2);
    return _stateCodes.contains(code) ? code : null;
  }

  /// Maps the app's free-form units onto the Offline Tool's standard UQCs.
  static String _uqc(String unit) {
    final u = unit.trim().toLowerCase();
    const map = {
      'pcs': 'PCS',
      'unit': 'PCS',
      'kg': 'KGS',
      'gm': 'GMS',
      'ltr': 'LTR',
      'ml': 'MLT',
      'mtr': 'MTR',
      'cm': 'CMS',
      'box': 'BOX',
      'bag': 'BAG',
      'dozen': 'DOZ',
      'set': 'SET',
      'pair': 'PRS',
      'roll': 'ROL',
      'sqft': 'SQF',
    };
    return map[u] ?? 'PCS';
  }

  static String _name(String prefix, DateTime from, DateTime to) =>
      '${prefix}_${DateFormat('yyyyMMdd').format(from)}_'
      '${DateFormat('yyyyMMdd').format(to)}.csv';

  /// Portal-uploadable GSTR-1 JSON (offline-import format): sections b2b,
  /// b2cl, b2cs, cdnr (credit/debit notes), hsn.
  static Future<GstrFile> buildGstr1Json({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _loadPeriod(from, to, withNotes: true);
    if (data.supplierStateCode == null) {
      throw GstrExportException(
          'Set your company GSTIN in Company Info first.');
    }
    final pos = data.supplierStateCode!;
    String fp() => '${from.month.toString().padLeft(2, '0')}'
        '${from.year}';

    final b2b = <Map<String, dynamic>>[];
    final b2cl = <Map<String, dynamic>>[];
    final b2csList = <Map<String, dynamic>>[];
    final cdnr = <Map<String, dynamic>>[];
    final hsn = <Map<String, dynamic>>[];
    final b2csAgg = <String, List<double>>{};
    double exemptVal = 0;

    void addItemTaxLines(
        Map<String, dynamic> inv, bool interstate, bool interStateOverride) {
      final taxMode = _taxModeOf(inv);
      final figures = _figuresForInvoice(inv);
      final invoiceValue = figures.total;
      final custGstin =
          (inv['customer_gstin'] as String? ?? '').trim().toUpperCase();
      final useIgstBase = interstate || interStateOverride;
      var lineNum = 1;
      for (final t in figures.hsnLines) {
        final rate = t.rate;
        final tax = t.tax;
        final taxable = t.taxable;
        final lineItms = <String, dynamic>{
          'num': lineNum++,
          'rt': rate,
          'txval': _r2(taxable),
          'csamt': 0,
        };
        final useIgst = useIgstBase;
        if (useIgst) {
          lineItms['iamt'] = _r2(tax);
        } else {
          lineItms['camt'] = _r2(tax / 2);
          lineItms['samt'] = _r2(tax / 2);
        }
        final hsnCode = t.hsn.trim();
        hsn.add({
          'num': hsnCode.length,
          'hsn': hsnCode.isEmpty ? '999999' : hsnCode,
          'desc': t.description,
          'uqc': _uqc(t.unit),
          'qty': _r2(t.qty),
          'val': _r2(taxable + tax),
          'txval': _r2(taxable),
          'iamt': useIgst ? _r2(tax) : 0,
          'camt': !useIgst ? _r2(tax / 2) : 0,
          'samt': !useIgst ? _r2(tax / 2) : 0,
          'csamt': 0,
        });
        if (rate <= 0) {
          exemptVal += taxable;
          continue;
        }
        if (custGstin.isNotEmpty) {
          _appendLine(b2b, custGstin, inv, lineItms, pos);
        } else if ((inv['is_interstate'] as int? ?? 0) == 1 &&
            invoiceValue > _b2clThreshold) {
          _appendLine(b2cl, '', inv, lineItms, pos);
        } else {
          final bucket =
              taxMode == TaxMode.global ? rate.round() : rate.toInt();
          final key = '$pos|$bucket';
          final agg = b2csAgg.putIfAbsent(key, () => [0, 0, 0]);
          agg[0] += taxable;
          agg[1] = useIgst ? agg[1] + tax : agg[1];
          agg[2] = !useIgst ? agg[2] + tax / 2 : agg[2];
        }
      }
    }

    for (final inv in data.invoices) {
      final type = inv['type'] as String? ?? 'Invoice';
      if (type == 'Credit Note' || type == 'Debit Note') {
        try {
          final custGstin =
              (inv['customer_gstin'] as String? ?? '').trim().toUpperCase();
          if (custGstin.isNotEmpty) {
            final ntItems = <Map<String, dynamic>>[];
            var ntNum = 1;
            final rawItems = inv['items'] as List? ?? const [];
            for (final item in rawItems) {
              if (item is! Map) continue;
              final amount = item['amount'];
              if (amount is! InvoiceLineAmount) continue;
              final tax = amount.itemTax;
              final itms = <String, dynamic>{
                'num': ntNum++,
                'rt': amount.taxRatePercent,
                'txval': _r2(amount.lineTotal),
                'csamt': 0,
              };
              if ((inv['is_interstate'] as int? ?? 0) == 1) {
                itms['iamt'] = _r2(tax);
              } else {
                itms['camt'] = _r2(tax / 2);
                itms['samt'] = _r2(tax / 2);
              }
              ntItems.add(itms);
            }
            cdnr.add({
              'ctin': custGstin,
              'gstin': data.supplierStateCode,
              'nt': [
                {
                  'nt_num': inv['invoice_number']?.toString() ??
                      inv['id']?.toString() ??
                      '',
                  'nt_dt': _fmtDate(_dateOf(inv)),
                  'val': _r2(_invoiceValueOf(inv)),
                  'ntty': type == 'Credit Note' ? 'C' : 'D',
                  'pos': _stateFromGstin(custGstin) ?? pos,
                  'rchrg': 'N',
                  'inv_typ': 'B2B',
                  'itms': ntItems,
                }
              ],
            });
          }
        } catch (_) {
          // Never let a malformed note break the whole GSTR-1 JSON export;
          // ledger postings for notes are owned elsewhere.
        }
        continue; // CDNR handled; not in B2B/B2C
      }
      if (type != 'Invoice') continue; // challan/proforma/receipts excluded
      final interstate = (inv['is_interstate'] as int? ?? 0) == 1;
      addItemTaxLines(inv, interstate, false);
    }

    for (final entry in b2csAgg.entries) {
      final parts = entry.key.split('|');
      final rate = num.parse(parts[1]);
      final agg = entry.value;
      b2csList.add({
        'sply_ty': 'INTRA',
        'pos': parts[0],
        'typ': 'OE',
        'txval': _r2(agg[0]),
        'iamt': _r2(agg[1]),
        'camt': _r2(agg[2]),
        'samt': _r2(agg[2]),
        'csamt': 0,
        'rt': rate,
      });
    }

    final json = <String, dynamic>{
      'version': '1.1',
      'fp': fp(),
      'gstin': data.companyGstin,
      'b2b': b2b,
      'b2cl': b2cl,
      'b2cs': b2csList,
      'cdnr': cdnr,
      'exempted': exemptVal,
      'hsn': {'data': hsn},
    };
    return GstrFile(
      filename: _name('gstr1', from, to).replaceFirst('.csv', '.json'),
      csv: const JsonEncoder.withIndent(' ').convert(json),
      section: 'GSTR-1 JSON',
    );
  }

  /// Portal-uploadable GSTR-3B JSON (outward supplies + ITC).
  static Future<GstrFile> buildGstr3bJson({
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await _loadPeriod(from, to);
    if (data.supplierStateCode == null) {
      throw GstrExportException(
          'Set your company GSTIN in Company Info first.');
    }
    final pos = data.supplierStateCode!;
    double taxable = 0, igst = 0, cgst = 0, sgst = 0;
    for (final inv in data.invoices) {
      if ((inv['type'] as String? ?? 'Invoice') != 'Invoice') continue;
      final interstate = (inv['is_interstate'] as int? ?? 0) == 1;
      final figures = _figuresForInvoice(inv);
      taxable += figures.taxableTotal;
      final tax = figures.tax;
      if (interstate) {
        igst += tax;
      } else {
        cgst += tax / 2;
        sgst += tax / 2;
      }
    }
    final itc = await _loadItc(from, to);
    String fp() => '${from.month.toString().padLeft(2, '0')}${from.year}';
    final json = <String, dynamic>{
      'gstin': data.companyGstin,
      'ret_period': fp(),
      'inward_sup': [
        {
          'ty': 'GST',
          'pos': pos,
          'txval': _r2(taxable),
          'iamt': _r2(igst),
          'camt': _r2(cgst),
          'samt': _r2(sgst),
          'csamt': 0,
        }
      ],
      'itc_elg': {
        'itc_avld': [
          {
            'ty': 'ITC_ALL_OTHER',
            'iamt': _r2(itc.igst + itc.rcIgst),
            'camt': _r2(itc.cgst + itc.rcCgst),
            'samt': _r2(itc.sgst + itc.rcSgst),
            'csamt': 0,
          }
        ]
      },
    };
    return GstrFile(
      filename: _name('gstr3b', from, to).replaceFirst('.csv', '.json'),
      csv: const JsonEncoder.withIndent(' ').convert(json),
      section: 'GSTR-3B JSON',
    );
  }

  static double _r2(num v) => double.parse(v.toStringAsFixed(2));

  static void _appendLine(List<Map<String, dynamic>> section, String ctin,
      Map<String, dynamic> inv, Map<String, dynamic> itms, String pos) {
    final inum = inv['invoice_number']?.toString() ?? '';
    Map<String, dynamic>? doc;
    for (final d in section) {
      if (ctin.isEmpty ? d['pos'] == pos : d['ctin'] == ctin) {
        doc = d;
        break;
      }
    }
    doc ??= () {
      final d = <String, dynamic>{
        if (ctin.isNotEmpty) 'ctin': ctin,
        'inv': <Map<String, dynamic>>[],
      };
      section.add(d);
      return d;
    }();
    final invList = (doc['inv'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic>? invEntry;
    for (final e in invList) {
      if (e['inum'] == inum) {
        invEntry = e;
        break;
      }
    }
    invEntry ??= () {
      final e = <String, dynamic>{
        'inum': inum,
        'idt': _fmtDate(_dateOf(inv)),
        'val': _r2(_invoiceValueOf(inv)),
        'pos': ctin.isNotEmpty ? (_stateFromGstin(ctin) ?? pos) : pos,
        'rchrg': 'N',
        'inv_typ': 'B2B',
        'itms': <Map<String, dynamic>>[],
      };
      invList.add(e);
      return e;
    }();
    (invEntry['itms'] as List).add(itms);
  }

  static String _toCsv(List<List<dynamic>> rows) {
    return rows.map((row) {
      return row.map((cell) {
        final s = cell?.toString() ?? '';
        if (s.contains(',') || s.contains('"') || s.contains('\n')) {
          return '"${s.replaceAll('"', '""')}"';
        }
        return s;
      }).join(',');
    }).join('\r\n');
  }
}

/// One sync period's invoices plus the resolved supplier state code.
class _PeriodData {
  final List<Map<String, dynamic>> invoices;
  final String? supplierStateCode;
  final String companyGstin;
  const _PeriodData({
    required this.invoices,
    required this.supplierStateCode,
    this.companyGstin = '',
  });
}

class GstrFile {
  final String filename;
  final String csv;
  final String section;
  const GstrFile({
    required this.filename,
    required this.csv,
    required this.section,
  });
}

/// ITC rollup from purchase bills for a period.
class ItcTotals {
  final double igst;
  final double cgst;
  final double sgst;
  final double rcIgst;
  final double rcCgst;
  final double rcSgst;
  final List<ItcRow> rows;
  const ItcTotals({
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.rcIgst,
    required this.rcCgst,
    required this.rcSgst,
    this.rows = const [],
  });
}

class ItcRow {
  final String gstin;
  final String supplierName;
  final String billNumber;
  final DateTime date;
  final double total;
  final double taxable;
  final double igst;
  final double cgst;
  final double sgst;
  final double rate;
  final String placeOfSupply;
  final bool itcEligible;
  final bool reverseCharge;
  const ItcRow({
    required this.gstin,
    required this.supplierName,
    required this.billNumber,
    required this.date,
    required this.total,
    required this.taxable,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.rate,
    required this.placeOfSupply,
    required this.itcEligible,
    this.reverseCharge = false,
  });
}

class GstrExportException implements Exception {
  final String message;
  const GstrExportException(this.message);
  @override
  String toString() => message;
}

class _LineTax {
  final String hsn;
  final String description;
  final String unit;
  final double qty;
  final double rate;
  final double taxable;
  final double tax;
  final bool interstate;
  const _LineTax({
    required this.hsn,
    required this.description,
    required this.unit,
    required this.qty,
    required this.rate,
    required this.taxable,
    required this.tax,
    required this.interstate,
  });
}

/// Rate-wise GSTR figures for a single invoice, already adjusted for
/// invoice-level discount and additional costs.
class _GstrFigures {
  final double total;
  final double tax;
  final double net;
  final Map<int, double> taxableByRate;
  final Map<int, double> taxByRate;
  final double exempt;
  final List<_LineTax> hsnLines;
  const _GstrFigures({
    required this.total,
    required this.tax,
    required this.net,
    required this.taxableByRate,
    required this.taxByRate,
    required this.exempt,
    required this.hsnLines,
  });

  double get taxableTotal => taxableByRate.values.fold(0.0, (s, v) => s + v);
}
