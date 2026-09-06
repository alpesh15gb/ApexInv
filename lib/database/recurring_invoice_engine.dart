import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/utils/app_logger.dart';

const _tag = 'RecurringInvoiceEngine';

/// Generates due instances of recurring invoice templates. A template is any
/// non-trashed invoice row with is_recurring = 1 and a recurring_frequency
/// ('weekly' | 'monthly' | 'quarterly' | 'yearly'). Each run creates the
/// next dated copy when recurring_next_date <= today, reusing the source
/// invoice's items — offline-first: the run happens on app start, so no
/// background service is needed.
class RecurringInvoiceEngine {
  static final _dbHelper = DatabaseHelper();

  /// Runs once per app start; idempotent via recurring_next_date advancing
  /// past today after each generation. Returns the count created.
  static Future<int> generateDue() async {
    final db = await _dbHelper.database;
    // E4e: date-only boundary — a template due today must generate even if
    // its stored time is later than now. Compare calendar dates only.
    final todayKey = _dateKey(DateTime.now());
    final templates = await db.rawQuery('''
      SELECT id, recurring_frequency, recurring_next_date
      FROM invoices
      WHERE deleted_at IS NULL AND is_recurring = 1
        AND recurring_frequency IS NOT NULL
        AND recurring_next_date IS NOT NULL
        AND substr(recurring_next_date, 1, 10) <= ?
    ''', [todayKey]);

    var created = 0;
    for (final t in templates) {
      try {
        created += await _generateOne(
          templateId: t['id'] as String,
          frequency: t['recurring_frequency'] as String? ?? 'monthly',
        );
      } catch (e) {
        AppLogger.e(_tag, 'Failed to generate for template ${t['id']}', e);
      }
    }
    return created;
  }

  static Future<int> _generateOne({
    required String templateId,
    required String frequency,
  }) async {
    final db = await _dbHelper.database;
    final tplRows = await db.query('invoices',
        where: 'id = ?', whereArgs: [templateId], limit: 1);
    if (tplRows.isEmpty) return 0;
    final tpl = tplRows.first;
    final itemRows = await db.query('invoice_items',
        where: 'invoice_id = ?', whereArgs: [templateId]);
    if (itemRows.isEmpty) return 0;

    final nextDate =
        DateTime.tryParse(tpl['recurring_next_date'] as String? ?? '') ??
            DateTime.now();

    // E4c: reuse the canonical padded numbering so instances match the rest
    // of the app (bare '43' vs '00000043' divergence). E4g: if the base has
    // no trailing digits, fall back to a fresh canonical number per instance
    // instead of returning the raw base (which would duplicate).
    final type = tpl['type'] as String? ?? 'Invoice';
    var baseNumber = await InvoiceService.generateNextInvoiceNumber(type);
    if (RegExp(r'\d+$').firstMatch(baseNumber) == null) {
      baseNumber = await InvoiceService.generateNextInvoiceNumber(type);
    }
    var count = 0;

    // E4e: date-only due check — due today counts as due.
    bool isDue(DateTime cursor) => !_isAfterDateOnly(cursor, DateTime.now());
    // Catch up if multiple periods have elapsed.
    var cursor = nextDate;
    var guard = 0;
    final pending = <Map<String, dynamic>>[];
    final pendingItems = <List<Map<String, dynamic>>>[];
    while (isDue(cursor) && guard < 24) {
      final newId = const Uuid().v4();
      final instanceDate = cursor;
      final insertMap = Map<String, dynamic>.from(tpl);
      insertMap['id'] = newId;
      insertMap['invoice_number'] = _shiftInvoiceNumber(baseNumber, count);
      insertMap['date'] = instanceDate.toIso8601String();
      insertMap['due_date'] = null;
      insertMap['is_recurring'] = 0; // the instance is not itself a template
      insertMap['recurring_frequency'] = null;
      insertMap['recurring_next_date'] = null;
      insertMap['updated_at'] = null; // trigger re-stamps
      // E4a: strip sync identity from the copy. cloud_id is UNIQUE WHERE NOT
      // NULL — copying it violates on synced DBs. company_id is re-derived
      // by the capture trigger default ('local') when left as the template's
      // value, so keep it; only the cloud identity must be nulled.
      insertMap['cloud_id'] = null;
      insertMap.remove('rowid');

      final items = <Map<String, dynamic>>[];
      for (final row in itemRows) {
        final item = Map<String, dynamic>.from(row);
        item['id'] = const Uuid().v4();
        item['invoice_id'] = newId;
        item['updated_at'] = null;
        item.remove('rowid');
        // invoice_items has no cloud_id; guard anyway for forward compat.
        if (item.containsKey('cloud_id')) item['cloud_id'] = null;
        items.add(item);
      }
      pending.add(insertMap);
      pendingItems.add(items);
      count++;
      cursor = _advance(cursor, frequency);
      guard++;
    }

    if (pending.isEmpty) {
      // Nothing due: still advance a stale cursor past today only if this is
      // still a live template (E4f guard), without creating anything.
      if (_isAfterDateOnly(nextDate, DateTime.now())) return 0;
      await db.update(
        'invoices',
        {'recurring_next_date': cursor.toIso8601String()},
        where: 'id = ? AND is_recurring = 1',
        whereArgs: [templateId],
      );
      return 0;
    }

    // E4b: inserts + cursor advance commit in ONE txn — a crash between them
    // can no longer leave duplicates on the next run. E4f: the advance only
    // applies while the template is still live.
    await db.transaction((txn) async {
      for (var i = 0; i < pending.length; i++) {
        await txn.insert('invoices', pending[i]);
        for (final item in pendingItems[i]) {
          await txn.insert('invoice_items', item);
        }
      }
      await txn.update(
        'invoices',
        {'recurring_next_date': cursor.toIso8601String()},
        where: 'id = ? AND is_recurring = 1',
        whereArgs: [templateId],
      );
    });
    return count;
  }

  static String _shiftInvoiceNumber(String? base, int offset) {
    final raw = base ?? '';
    final match = RegExp(r'^(.*?)(\d+)$').firstMatch(raw);
    // E4g: non-numeric base — never return the raw duplicate. Synthesize a
    // fresh numeric number so concurrent catch-up instances stay unique.
    if (match == null) {
      final fresh = DateTime.now().millisecondsSinceEpoch + offset;
      return fresh.toString();
    }
    final prefix = match.group(1)!;
    final number = int.tryParse(match.group(2)!) ?? 0;
    final next = (number + offset).toString();
    final width = match.group(2)!.length;
    return '$prefix${next.padLeft(width, '0')}';
  }

  /// Calendar-aware stepping (E4d): clamps to the last day of the target
  /// month instead of letting DateTime overflow (Jan 31 + 1 month = Mar 3).
  static DateTime _advance(DateTime from, String frequency) {
    switch (frequency) {
      case 'weekly':
        return from.add(const Duration(days: 7));
      case 'quarterly':
        return _addMonths(from, 3);
      case 'yearly':
        return _addMonths(from, 12);
      case 'monthly':
      default:
        return _addMonths(from, 1);
    }
  }

  static DateTime _addMonths(DateTime from, int months) {
    final total = (from.month - 1) + months;
    final year = from.year + total ~/ 12;
    final month = total % 12 + 1;
    final last = _daysInMonth(year, month);
    final day = from.day > last ? last : from.day;
    return DateTime(
      year,
      month,
      day,
      from.hour,
      from.minute,
      from.second,
      from.millisecond,
      from.microsecond,
    );
  }

  static int _daysInMonth(int year, int month) {
    // Day 0 of the next month is the last day of this month.
    final next =
        month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
    return next.subtract(const Duration(days: 1)).day;
  }

  static String _dateKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  static bool _isAfterDateOnly(DateTime a, DateTime b) =>
      _dateKey(a).compareTo(_dateKey(b)) > 0;

  @visibleForTesting
  static DateTime advanceForTest(DateTime from, String frequency) =>
      _advance(from, frequency);

  @visibleForTesting
  static String shiftForTest(String? base, int offset) =>
      _shiftInvoiceNumber(base, offset);

  @visibleForTesting
  static bool isAfterDateOnlyForTest(DateTime a, DateTime b) =>
      _isAfterDateOnly(a, b);

  /// Marks/unmarks an invoice as a recurring template.
  static Future<void> setRecurring({
    required String invoiceId,
    required bool recurring,
    String frequency = 'monthly',
    DateTime? nextDate,
  }) async {
    final db = await _dbHelper.database;
    await db.update(
      'invoices',
      {
        'is_recurring': recurring ? 1 : 0,
        'recurring_frequency': recurring ? frequency : null,
        'recurring_next_date':
            recurring ? (nextDate ?? DateTime.now()).toIso8601String() : null,
      },
      where: 'id = ?',
      whereArgs: [invoiceId],
    );
  }
}
