import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/database_helper.dart';
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
    final templates = await db.rawQuery('''
      SELECT id, recurring_frequency, recurring_next_date
      FROM invoices
      WHERE deleted_at IS NULL AND is_recurring = 1
        AND recurring_frequency IS NOT NULL
        AND recurring_next_date IS NOT NULL
        AND recurring_next_date <= ?
    ''', [DateTime.now().toIso8601String()]);

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
    final tplRows =
        await db.query('invoices', where: 'id = ?', whereArgs: [templateId], limit: 1);
    if (tplRows.isEmpty) return 0;
    final tpl = tplRows.first;
    final itemRows = await db.query('invoice_items',
        where: 'invoice_id = ?', whereArgs: [templateId]);
    if (itemRows.isEmpty) return 0;

    final nextDate =
        DateTime.tryParse(tpl['recurring_next_date'] as String? ?? '') ??
            DateTime.now();

    // Reuse the app's numbering rules for the new instance.
    final invoiceNumber = await _nextInvoiceNumber(tpl['type'] as String? ?? 'Invoice');
    final created = <String>[];
    var count = 0;

    // Catch up if multiple periods have elapsed.
    var cursor = nextDate;
    var guard = 0;
    while (cursor.isBefore(DateTime.now()) && guard < 24) {
      final newId = const Uuid().v4();
      final instanceDate = cursor;
      final insertMap = Map<String, dynamic>.from(tpl);
      insertMap['id'] = newId;
      insertMap['invoice_number'] = _shiftInvoiceNumber(invoiceNumber, count);
      insertMap['date'] = instanceDate.toIso8601String();
      insertMap['due_date'] = null;
      insertMap['is_recurring'] = 0; // the instance is not itself a template
      insertMap['recurring_frequency'] = null;
      insertMap['recurring_next_date'] = null;
      insertMap['updated_at'] = null; // trigger re-stamps
      insertMap.remove('rowid');

      await db.transaction((txn) async {
        await txn.insert('invoices', insertMap);
        for (final row in itemRows) {
          final item = Map<String, dynamic>.from(row);
          item['id'] = const Uuid().v4();
          item['invoice_id'] = newId;
          await txn.insert('invoice_items', item);
        }
      });
      created.add(newId);
      count++;
      cursor = _advance(cursor, frequency);
      guard++;
    }

    // Advance the template's next-run date past today.
    await db.update(
      'invoices',
      {'recurring_next_date': cursor.toIso8601String()},
      where: 'id = ?',
      whereArgs: [templateId],
    );
    return count;
  }

  static String _shiftInvoiceNumber(String? base, int offset) {
    final raw = base ?? '';
    final match = RegExp(r'^(.*?)(\d+)$').firstMatch(raw);
    if (match == null) return raw;
    final prefix = match.group(1)!;
    final number = int.tryParse(match.group(2)!) ?? 0;
    final next = (number + offset).toString();
    final width = match.group(2)!.length;
    return '$prefix${next.padLeft(width, '0')}';
  }

  static DateTime _advance(DateTime from, String frequency) {
    switch (frequency) {
      case 'weekly':
        return from.add(const Duration(days: 7));
      case 'quarterly':
        return DateTime(from.year, from.month + 3, from.day);
      case 'yearly':
        return DateTime(from.year + 1, from.month, from.day);
      case 'monthly':
      default:
        return DateTime(from.year, from.month + 1, from.day);
    }
  }

  static Future<String> _nextInvoiceNumber(String type) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      "SELECT MAX(CAST(invoice_number AS INTEGER)) AS m FROM invoices "
      "WHERE type = ? AND deleted_at IS NULL",
      [type],
    );
    final max = (rows.first['m'] as num?)?.toInt() ?? 0;
    return (max + 1).toString();
  }

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
