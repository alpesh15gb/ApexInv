import 'package:sqflite/sqflite.dart';

import '../database/sync_schema.dart';

/// Outbox reader/coalescer (dbplan.md §3.3).
///
/// The outbox accumulates one row per captured write. Before pushing we
/// collapse to the *latest* op per (table, row_pk): insert+3 updates push as
/// one upsert, insert+delete pushes as a tombstone. This bounds worst-case
/// push size to O(rows), not O(ops), and never transmits intermediate states.
class SyncOutbox {
  final DatabaseExecutor db;
  SyncOutbox(this.db);

  /// Number of un-pushed ops (for the status indicator).
  Future<int> pendingCount() async {
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM _sync_outbox WHERE pushed_at IS NULL');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Collapsed pending ops in insertion order (parents precede children —
  /// outbox rows are captured in commit order, and [syncTableOrder] keeps
  /// baseline/pull ordering deterministic).
  Future<List<OutboxEntry>> pendingCoalesced({int limit = 500}) async {
    final rows = await db.rawQuery('''
      SELECT o.table_name, o.row_pk, o.op, o.changed_at
      FROM _sync_outbox o
      JOIN (
        SELECT table_name, row_pk, MAX(seq) AS max_seq
        FROM _sync_outbox
        WHERE pushed_at IS NULL
        GROUP BY table_name, row_pk
      ) latest
        ON latest.table_name = o.table_name
       AND latest.row_pk = o.row_pk
       AND latest.max_seq = o.seq
      ORDER BY o.seq
      LIMIT ?
    ''', [limit]);

    return rows
        .map((r) => OutboxEntry(
              tableName: r['table_name'] as String,
              rowPk: r['row_pk'] as String,
              op: r['op'] as String,
              changedAt: DateTime.parse(r['changed_at'] as String),
            ))
        .toList();
  }

  /// Reads the current row for [rowPk] from [table] with the shared
  /// local-only columns stripped — the payload that goes on the wire.
  /// Per-table local-only columns (invoices.deleted_at) are deliberately
  /// KEPT so the engine can act on them (soft-delete → tombstone); the
  /// engine strips them before pushing. Handles company_info's INTEGER pk
  /// (outbox stores pks as strings on the wire).
  Future<Map<String, dynamic>?> readRowPayload(
      String table, String rowPk) async {
    late List<Map<String, dynamic>> rows;
    final pk = syncPkColumn(table);
    if (table == 'company_info') {
      rows = await db.query(table,
          where: 'id = ?', whereArgs: [int.tryParse(rowPk) ?? -1], limit: 1);
    } else {
      rows = await db.query(table,
          where: '$pk = ?', whereArgs: [rowPk], limit: 1);
    }
    if (rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.first);
    row.removeWhere((k, _) => syncLocalOnlyColumns.contains(k));
    return row;
  }

  /// Marks all ops for the given (table, pk) pairs as pushed, inside the
  /// caller's transaction. Rows are retained for 7 days of diagnostics
  /// (pruned by [prunePushed]).
  Future<void> markPushed(DatabaseExecutor txn, List<OutboxEntry> entries,
      String pushedAtIso) async {
    for (final e in entries) {
      await txn.update(
        '_sync_outbox',
        {'pushed_at': pushedAtIso},
        where: 'table_name = ? AND row_pk = ? AND pushed_at IS NULL',
        whereArgs: [e.tableName, e.rowPk],
      );
    }
  }

  /// Deletes pushed entries older than [days]. Called opportunistically
  /// after a successful sync cycle.
  Future<void> prunePushed({int days = 7}) async {
    final cutoff =
        DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();
    await db.delete('_sync_outbox',
        where: 'pushed_at IS NOT NULL AND pushed_at < ?', whereArgs: [cutoff]);
  }
}

class OutboxEntry {
  final String tableName;
  final String rowPk;
  final String op;
  final DateTime changedAt;

  const OutboxEntry({
    required this.tableName,
    required this.rowPk,
    required this.op,
    required this.changedAt,
  });
}
