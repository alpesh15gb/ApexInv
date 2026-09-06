import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/sync_schema.dart';

/// Sync conflict review log (companion to the LWW apply in
/// `sync_engine.dart`).
///
/// A row is recorded — in the SAME pull transaction as the apply, snapshots
/// taken BEFORE the overwrite — whenever a pulled remote op contends with a
/// locally-modified row:
///  - update-over-update (remote edit vs local edit),
///  - update-over-delete (remote edit resurrects a locally-deleted row),
///  - delete-over-update (remote tombstone vs local edit).
/// [winner] is which side LWW kept ('local' or 'remote'); the snapshots let
/// the user see what changed on each side. `local_snapshot` is null when the
/// row was locally deleted; `remote_snapshot` is null when the remote side
/// deleted.
///
/// The `reviewed` flag is LOCAL-ONLY (see [createSyncConflictsTable]): each
/// device logs and reviews its own overwrites; nothing here enters the
/// outbox or travels to the server.
class SyncConflict {
  final int id;
  final String tableName;
  final String rowPk;
  final Map<String, dynamic>? localSnapshot;
  final Map<String, dynamic>? remoteSnapshot;
  final String winner;
  final DateTime occurredAt;
  final bool reviewed;

  const SyncConflict({
    required this.id,
    required this.tableName,
    required this.rowPk,
    required this.localSnapshot,
    required this.remoteSnapshot,
    required this.winner,
    required this.occurredAt,
    required this.reviewed,
  });

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw == null) return null;
    final text = raw as String;
    if (text.isEmpty) return null;
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  factory SyncConflict.fromRow(Map<String, dynamic> row) => SyncConflict(
        id: (row['id'] as int?) ?? 0,
        tableName: row['table_name'] as String? ?? '',
        rowPk: row['row_pk'] as String? ?? '',
        localSnapshot: _decode(row['local_snapshot']),
        remoteSnapshot: _decode(row['remote_snapshot']),
        winner: row['winner'] as String? ?? 'remote',
        occurredAt: DateTime.tryParse(row['occurred_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        reviewed: (row['reviewed'] as int? ?? 0) != 0,
      );

  /// True when the remote side won and there is something to restore.
  bool get canRestore => winner == 'remote';
}

/// Columns that describe sync bookkeeping rather than user data — hidden from
/// the "what changed" diff (they always differ and carry no review value).
const syncConflictMetaColumns = <String>{
  'company_id',
  'cloud_id',
  'updated_at',
  'rowid',
};

/// Field-level diff between the two snapshots: entries of
/// (column, local value, remote value) for every business column whose value
/// differs, plus a null side when one side deleted the row.
List<({String column, Object? local, Object? remote})> diffSnapshots(
  Map<String, dynamic>? local,
  Map<String, dynamic>? remote,
) {
  final keys = <String>{
    ...?local?.keys,
    ...?remote?.keys,
  }..removeAll(syncConflictMetaColumns);
  final out = <({String column, Object? local, Object? remote})>[];
  for (final key in keys.toList()..sort()) {
    final l = local?[key];
    final r = remote?[key];
    if (!_snapshotValuesEqual(l, r)) {
      out.add((column: key, local: l, remote: r));
    }
  }
  return out;
}

bool _snapshotValuesEqual(Object? a, Object? b) {
  if (a == b) return true;
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  return false;
}

/// Reads/writes the `sync_conflicts` review log. All methods take the
/// database explicitly so tests can pass in-memory handles.
class SyncConflictsRepository {
  const SyncConflictsRepository();

  Future<List<SyncConflict>> list(
    DatabaseExecutor db, {
    bool onlyUnreviewed = false,
  }) async {
    final rows = await db.query(
      'sync_conflicts',
      where: onlyUnreviewed ? 'reviewed = 0' : null,
      orderBy: 'reviewed ASC, occurred_at DESC, id DESC',
    );
    return rows.map(SyncConflict.fromRow).toList();
  }

  Future<int> unreviewedCount(DatabaseExecutor db) async {
    return Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM sync_conflicts WHERE reviewed = 0',
        )) ??
        0;
  }

  Future<void> markReviewed(DatabaseExecutor db, int id) async {
    await db.update(
      'sync_conflicts',
      {'reviewed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Re-applies the conflict's LOCAL snapshot as a fresh local edit, so the
  /// capture triggers enqueue it into `_sync_outbox` and it syncs back out
  /// on the next cycle (where it wins arbitration with a newer `updated_at`).
  ///
  ///  - local snapshot present but the row is gone (remote deleted it):
  ///    re-inserts the snapshot.
  ///  - local snapshot present and the row exists: overwrites it.
  ///  - local snapshot null (we had deleted the row): deletes it again, i.e.
  ///    re-issues our delete as a new tombstone.
  /// The conflict is marked reviewed — restoring resolves it.
  Future<void> restoreMyVersion(Database db, SyncConflict conflict) async {
    final table = conflict.tableName;
    if (!syncTableOrder.contains(table)) {
      throw ArgumentError('Not a synced table: $table');
    }
    final rowPk = conflict.rowPk;
    final local = conflict.localSnapshot;

    await db.transaction((txn) async {
      if (local == null) {
        if (table == 'company_info') {
          await txn.delete(table,
              where: 'id = ?', whereArgs: [int.tryParse(rowPk) ?? -1]);
        } else {
          await txn.delete(table, where: 'id = ?', whereArgs: [rowPk]);
        }
      } else {
        final cols = await txn.rawQuery('PRAGMA table_info($table)');
        final known = {for (final c in cols) c['name'] as String};
        final values = Map<String, dynamic>.from(local)
          ..remove('rowid')
          ..remove('updated_at') // the UPDATE/INSERT trigger re-stamps fresh
          ..removeWhere((k, _) => !known.contains(k));
        if (table == 'company_info') {
          values['id'] = int.tryParse(rowPk) ?? values['id'];
        } else {
          values['id'] = rowPk;
        }
        final existing = table == 'company_info'
            ? await txn.query(table,
                where: 'id = ?',
                whereArgs: [int.tryParse(rowPk) ?? -1],
                limit: 1)
            : await txn.query(table,
                where: 'id = ?', whereArgs: [rowPk], limit: 1);
        if (existing.isEmpty) {
          await txn.insert(table, values);
        } else if (table == 'company_info') {
          await txn.update(table, values,
              where: 'id = ?', whereArgs: [int.tryParse(rowPk) ?? -1]);
        } else {
          await txn.update(table, values, where: 'id = ?', whereArgs: [rowPk]);
        }
      }
      await txn.update(
        'sync_conflicts',
        {'reviewed': 1},
        where: 'id = ?',
        whereArgs: [conflict.id],
      );
    });
  }
}
