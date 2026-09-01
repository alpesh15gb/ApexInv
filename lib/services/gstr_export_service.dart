import 'package:intl/intl.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/domain/invoice_totals_calculator.dart';
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
    var exemptTaxable = 0.0;

    for (final inv in data.invoices) {
      final interstate = (inv['is_interstate'] as int? ?? 0) == 1;
      final custGstin =
          (inv['customer_gstin'] as String? ?? '').trim().toUpperCase();
      final invoiceValue = (inv['total'] as num?)?.toDouble() ?? 0.0;

      // Rate-wise taxable for this invoice.
      final rates = <int, double>{}; // rate% -> taxable
      final lineTaxes = <_LineTax>[];
      for (final item in inv['items']) {
        final amount = item['amount'] as InvoiceLineAmount;
        final rate = amount.taxRatePercent;
        if (rate <= 0) {
          exemptTaxable += amount.lineTotal;
        } else {
          rates[rate.toInt()] = (rates[rate.toInt()] ?? 0) + amount.lineTotal;
        }
        lineTaxes.add(_LineTax(
          hsn: ((item['row']['hsncode'] as String? ?? '')).trim(),
          description: item['row']['product_name'] as String? ?? '',
          unit: item['row']['unit'] as String? ?? '',
          qty: (item['row']['quantity'] as num?)?.toDouble() ?? 0,
          rate: rate,
          taxable: amount.lineTotal,
          tax: amount.itemTax,
          interstate: interstate,
        ));
      }

      for (final entry in rates.entries) {
        final rate = entry.key;
        final taxable = entry.value;
        if (custGstin.isNotEmpty) {
          final recipientState = _stateFromGstin(custGstin);
          b2bRows.add([
            custGstin,
            inv['customer_name'] ?? '',
            inv['invoice_number'] ?? '',
            _fmtDate(inv['date']),
            _n2(invoiceValue),
            recipientState,
            'N', // reverse charge
            '0', // applicable % of tax rate
            rate,
            _n2(taxable),
            '0', // cess
          ]);
        } else if (interstate && invoiceValue > 250000) {
          b2clRows.add([
            '', // B2CL recipients are unregistered
            inv['customer_name'] ?? '',
            inv['invoice_number'] ?? '',
            _fmtDate(inv['date']),
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
  /// produces the outward-supply figures for Table 3.1 so they can be keyed
  /// into the portal or cross-checked.
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
      for (final item in inv['items']) {
        final amount = item['amount'] as InvoiceLineAmount;
        if (amount.taxRatePercent <= 0) {
          exempt += amount.lineTotal;
          continue;
        }
        taxable += amount.lineTotal;
        final tax = amount.itemTax;
        if (interstate) {
          igst += tax;
        } else {
          cgst += tax / 2;
          sgst += tax / 2;
        }
      }
    }

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
      ['Table 4 — Input Tax Credit'],
      [
        'Purchases/inward supplies with GSTIN are not tracked as tax '
            'invoices in this app; enter ITC from supplier invoices in the '
            'portal directly.',
        '0',
        '0',
        '0',
        '0'
      ],
    ];

    return GstrFile(
      filename: _name('gstr3b_summary', from, to),
      csv: _toCsv(rows),
      section: 'GSTR-3B summary',
    );
  }

  // ── Data loading ──

  static Future<_PeriodData> _loadPeriod(DateTime from, DateTime to) async {
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
    return _PeriodData(invoices: result, supplierStateCode: supplierState);
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
  const _PeriodData({required this.invoices, required this.supplierStateCode});
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
