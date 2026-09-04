// Post-restore sync re-arm (dbplan §3.7): after the DB file is replaced,
// SyncEngine.onDatabaseReplaced must clear stale pull cursors, mark the
// baseline done so the next cycle pulls deltas again, and keep the outbox
// (durable local truth) so pending writes still reach the server.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_transport.dart';

/// Minimal stand-in server for an empty company: pushes succeed with a fresh
/// server timestamp; pulls return no rows but advance the cursor.
class _EmptyTransport implements SyncTransport {
  final List<SyncOp> pushedOps = [];

  @override
  Future<bool> companyHasData(String companyId) async => false;

  @override
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops) async {
    pushedOps.addAll(ops);
    return SyncPushReceipt(
        serverTime: DateTime.now().toUtc().toIso8601String());
  }

  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    return SyncPullPage(
      ops: const [],
      nextCursor: DateTime.now().toUtc().toIso8601String(),
      hasMore: false,
    );
  }
}

/// Opens a real SQLite DB with the full current schema, like the app does.
/// singleInstance must be OFF: sqflite keys instances by path, and every
/// in-memory path is the same — without it all "devices" share one DB.
Future<Database> _createDevice() {
  return openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
  );
}

Future<String?> _state(Database db, String key) async {
  final rows = await db.query('_sync_state',
      where: 'key = ?', whereArgs: [key], limit: 1);
  return rows.isEmpty ? null : rows.first['value'] as String?;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('onDatabaseReplaced re-arms delta pull and keeps the outbox', () async {
    final db = await _createDevice();
    try {
      final transport = _EmptyTransport();
      final engine = SyncEngine(dbAccessor: () => db, transport: transport);
      await engine.linkCompany(db, 'company-1');
      expect(await _state(db, 'baseline_done'), '1');

      // Simulate the restored file's stale sync state: baseline lost and an
      // ancient cursor carried over from the old device.
      const staleCursor = '2020-01-01T00:00:00.000Z';
      await db.insert('_sync_state', {'key': 'baseline_done', 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert(
          '_sync_state', {'key': 'last_pulled_customers', 'value': staleCursor},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // A local write made after the restore — captured into the outbox by
      // the sync triggers and still pending upload.
      await db.insert(
          'customers', {'id': 'c-restore', 'name': 'Restored Customer'});
      expect(await _state(db, 'baseline_done'), '0');
      expect(await _state(db, 'last_pulled_customers'), staleCursor);

      await engine.onDatabaseReplaced();

      // Baseline is done again (the restored DB already holds a full
      // dataset), so the next cycle pulls instead of skipping pulls forever.
      expect(await _state(db, 'baseline_done'), '1');
      // The stale cursor is gone — the pull re-ran from scratch and reseeded
      // it. (With the old '0' this stayed stale and _runCycle never pulled.)
      expect(await _state(db, 'last_pulled_customers'), isNot(staleCursor));
      // The outbox survived the restore hook: the pending write was pushed,
      // not dropped...
      expect(
          transport.pushedOps.where(
              (op) => op.tableName == 'customers' && op.rowPk == 'c-restore'),
          isNotEmpty);
      // ...and its outbox row was retained (marked pushed; pruned only once
      // older than 7 days), never wiped.
      final outbox = await db.query('_sync_outbox',
          where: 'table_name = ? AND row_pk = ?',
          whereArgs: ['customers', 'c-restore']);
      expect(outbox, isNotEmpty);
    } finally {
      await db.close();
    }
  });
}
