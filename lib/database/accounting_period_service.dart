import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/database/audit_log_service.dart';
import 'package:apexbooks/database/database_helper.dart';

/// Minimal accounting-period lock with audit trail.
///
/// Stores the lock cutoff as a plain `settings` row (`accounting_period_lock`
/// = ISO-8601 date string, absent/empty = unlocked) so no schema migration is
/// needed. The setting write and its audit row commit in ONE transaction, so
/// a crash can never leave a lock without a log entry or vice versa.
///
/// Enforcement at write paths is intentionally out of scope: this service
/// owns the lock state + its audit events; callers can gate on [isLocked].
class AccountingPeriodService {
  static const _key = 'accounting_period_lock';
  static final _dbHelper = DatabaseHelper();

  static Future<DateTime?> getLockedUntil() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = (rows.first['value'] as String?)?.trim() ?? '';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static Future<bool> isLocked({DateTime? at}) async {
    final until = await getLockedUntil();
    if (until == null) return false;
    return !(at ?? DateTime.now()).isAfter(until);
  }

  /// Locks postings on or before [until]. Audit detail carries before→after.
  static Future<void> lock({
    required DateTime until,
    String? actor,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final beforeRows = await txn.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [_key],
        limit: 1,
      );
      final before = beforeRows.isEmpty
          ? '—'
          : ((beforeRows.first['value'] as String?)?.trim().isEmpty ?? true)
              ? '—'
              : (beforeRows.first['value'] as String);
      final after = until.toIso8601String();
      await txn.insert(
        'settings',
        {'key': _key, 'value': after},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final resolved = AuditActor.resolve(actor);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.periodLock,
        username: resolved,
        entity: 'accounting_period',
        entityId: 'global',
        details: 'locked_until: $before → $after · by $resolved',
      );
    });
  }

  static Future<void> unlock({String? actor}) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final beforeRows = await txn.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [_key],
        limit: 1,
      );
      final before = beforeRows.isEmpty
          ? '—'
          : ((beforeRows.first['value'] as String?)?.trim().isEmpty ?? true)
              ? '—'
              : (beforeRows.first['value'] as String? ?? '—');
      await txn.delete('settings', where: 'key = ?', whereArgs: [_key]);
      final resolved = AuditActor.resolve(actor);
      await AuditLogService.logInTxn(
        txn,
        action: AuditActions.periodUnlock,
        username: resolved,
        entity: 'accounting_period',
        entityId: 'global',
        details: 'locked_until: $before → — · by $resolved',
      );
    });
  }
}
