import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/utils/app_logger.dart';

const _tag = 'AuditLogService';

/// Global holder for the currently signed-in username so service-layer writes
/// can attribute audit rows even when callers omit an explicit [actor].
/// UI sets this once at login (see DashboardScreen); every mutation accepts
/// an optional `actor` override that wins over this value; fallback is
/// 'system' (background jobs, tests without an actor, license screen).
class AuditActor {
  static String? _current;

  static String? get current => _current;

  static void setCurrent(String? username) {
    final v = username?.trim();
    _current = (v == null || v.isEmpty) ? null : v;
  }

  static void clear() => _current = null;

  static String resolve(String? actor) {
    final v = actor?.trim();
    if (v != null && v.isNotEmpty) return v;
    final c = _current?.trim();
    if (c != null && c.isNotEmpty) return c;
    return 'system';
  }
}

/// Canonical audit action names. Legacy rows may contain 'purchase_payment'
/// (purchase-side add); the viewer treats it as [purchasePaymentAdd].
class AuditActions {
  static const invoiceCreate = 'invoice_create';
  static const invoiceUpdate = 'invoice_update';
  static const invoiceDelete = 'invoice_delete';
  static const invoiceRestore = 'invoice_restore';
  static const invoicePermanentDelete = 'invoice_permanent_delete';

  static const paymentAdd = 'payment_add';
  static const paymentDelete = 'payment_delete';

  static const purchaseBillCreate = 'purchase_bill_create';
  static const purchaseBillUpdate = 'purchase_bill_update';
  static const purchaseBillDelete = 'purchase_bill_delete';

  static const purchasePaymentAdd = 'purchase_payment_add';
  static const purchasePaymentDelete = 'purchase_payment_delete';
  // Legacy UI action for purchase payment adds.
  static const purchasePaymentLegacy = 'purchase_payment';

  static const expenseCreate = 'expense_create';
  static const expenseUpdate = 'expense_update';
  static const expenseDelete = 'expense_delete';

  static const chequeCreate = 'cheque_create';
  static const chequeTransition = 'cheque_transition';

  static const loanCreate = 'loan_create';
  static const loanRepay = 'loan_repay';

  static const transfer = 'transfer';
  static const adjustment = 'adjustment';

  static const periodLock = 'period_lock';
  static const periodUnlock = 'period_unlock';

  static const licenseActivate = 'license_activate';
}

/// Audit-trail writer. Fire-and-forget — audit failures must never break a
/// business write. Money mutations call [logInTxn] with the open [txn] so
/// the audit row commits atomically with the write itself (no partial
/// log/write splits). [log] opens its own connection for non-transactional
/// callers (e.g. license activation fallback).
class AuditLogService {
  static final dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

  static String resolveActor(String? actor) => AuditActor.resolve(actor);

  static String fmtMoney(double? v) => (v ?? 0).toStringAsFixed(2);

  /// Compact "k: a → b; ..." diff. Null/empty sides render as "—".
  static String diff(Map<String, (Object?, Object?)> fields) {
    final parts = <String>[];
    for (final e in fields.entries) {
      final before = _short(e.value.$1);
      final after = _short(e.value.$2);
      if (before == after) continue;
      parts.add('${e.key}: $before → $after');
    }
    return parts.join('; ');
  }

  static String _short(Object? v) {
    if (v == null) return '—';
    final s = v is double
        ? v.toStringAsFixed(2)
        : v is num
            ? v.toString()
            : v.toString().trim();
    if (s.isEmpty) return '—';
    return s.length > 48 ? '${s.substring(0, 48)}…' : s;
  }

  static Future<void> logInTxn(
    DatabaseExecutor txn, {
    required String action,
    String? username,
    String? entity,
    String? entityId,
    String? details,
  }) async {
    try {
      await txn.insert('audit_log', {
        'id': _uuid.v4(),
        'username': username ?? AuditActor.current ?? 'system',
        'action': action,
        'entity': entity,
        'entity_id': entityId,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      AppLogger.e(_tag, 'audit log (txn) failed', e);
    }
  }

  static Future<void> log({
    required String action,
    String? username,
    String? entity,
    String? entityId,
    String? details,
  }) async {
    try {
      final db = await dbHelper.database;
      await db.insert('audit_log', {
        'id': _uuid.v4(),
        'username': username ?? AuditActor.current ?? 'system',
        'action': action,
        'entity': entity,
        'entity_id': entityId,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      AppLogger.e(_tag, 'audit log failed', e);
    }
  }

  static Future<List<Map<String, dynamic>>> recent({int limit = 500}) async {
    final db = await dbHelper.database;
    return db.query('audit_log', orderBy: 'created_at DESC', limit: limit);
  }

  static Future<List<Map<String, dynamic>>> forEntity(
    String entity,
    String entityId, {
    int limit = 200,
  }) async {
    final db = await dbHelper.database;
    return db.query(
      'audit_log',
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [entity, entityId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }
}
