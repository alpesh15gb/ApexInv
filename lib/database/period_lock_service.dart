import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'audit_log_service.dart';
import 'database_helper.dart';
import 'settings_service.dart';

/// Financial period locking: once a period is closed/filed, documents dated
/// on or before [lockedBeforeDate] cannot be created, edited, or deleted —
/// at the SERVICE layer, so no UI path can silently rewrite a closed period.
///
/// Storage is one `settings` row ([SettingKey.lockedBeforeDate], ISO
/// `yyyy-MM-dd`); absent/empty/unparseable means unlocked, so databases that
/// never set a lock behave exactly as before (zero behavior change).
///
/// Comparison is calendar-date only (time-of-day is dropped on both sides):
/// with a lock of 2026-03-31, anything dated 2026-03-31 or earlier is
/// refused, 2026-04-01 and later is allowed.
///
/// Read-only operations (viewing, printing, exporting, reports) never call
/// this service and are unaffected.
class PeriodLockService {
  static final _dbHelper = DatabaseHelper();

  /// Current lock cutoff, date-only. Null = unlocked.
  static Future<DateTime?> getLockedBeforeDate() =>
      SettingsService.getLockedBeforeDate();

  /// Pure calendar-date comparison, extracted for unit testing:
  /// true when [date] falls on or before [lock] (either may carry a
  /// time-of-day; both are truncated to the day). A null lock never locks.
  static bool isDateLocked(DateTime date, DateTime? lock) {
    if (lock == null) return false;
    final d = DateTime(date.year, date.month, date.day);
    final l = DateTime(lock.year, lock.month, lock.day);
    return !d.isAfter(l);
  }

  /// Throws a [StateError] when [date] falls in a locked period (on or
  /// before the cutoff). [entity] names the document for a clear message,
  /// e.g. 'Invoice', 'Purchase bill', 'Expense', 'Transfer'.
  static Future<void> assertDateUnlocked(
    DateTime date, {
    String entity = 'Document',
  }) async {
    final lock = await getLockedBeforeDate();
    if (isDateLocked(date, lock)) {
      throw StateError(
        'Cannot save $entity dated ${AppDate.dateKey(date)}: '
        'financial period is locked on or before ${AppDate.dateKey(lock!)}',
      );
    }
  }

  /// Reads the stored date of one row and refuses when it is locked.
  /// Missing rows and unparseable dates pass through untouched so callers
  /// keep their own not-found behavior.
  static Future<void> assertStoredDateUnlocked(
    Database db, {
    required String table,
    required String id,
    String dateColumn = 'date',
    String entity = 'Document',
  }) async {
    final rows = await db.query(
      table,
      columns: [dateColumn],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final parsed = DateTime.tryParse(rows.first[dateColumn] as String? ?? '');
    if (parsed == null) return;
    await assertDateUnlocked(parsed, entity: entity);
  }

  /// Sets (or clears, when null) the lock and audit-logs the change.
  /// Time-of-day on [date] is dropped; [username] attributes the audit row.
  static Future<void> setLockedBeforeDate(
    DateTime? date, {
    String? username,
  }) async {
    final previous = await SettingsService.getLockedBeforeDate();
    final normalized =
        date == null ? null : DateTime(date.year, date.month, date.day);
    await SettingsService.setLockedBeforeDate(normalized);
    final actor = AuditActor.resolve(username);
    await AuditLogService.log(
      action: normalized == null
          ? AuditActions.periodUnlock
          : AuditActions.periodLock,
      username: actor,
      entity: 'settings',
      entityId: SettingKey.lockedBeforeDate.key,
      details: 'locked_before_date: '
          '${previous == null ? '—' : AppDate.dateKey(previous)} → '
          '${normalized == null ? '—' : AppDate.dateKey(normalized)} '
          'by $actor',
    );
  }
}
