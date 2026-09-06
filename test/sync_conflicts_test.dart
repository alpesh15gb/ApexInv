// Tests for the sync conflict review log: conflicting pull-applies record
// both snapshots (LWW outcomes unchanged) and restore-my-version re-queues
// the local snapshot for push.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/outbox_types.dart';
import 'package:apexbooks/sync/sync_conflicts.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_transport.dart';

/// Minimal in-memory server with the same LWW contract as the engine test's
/// fake: per-row client-clock arbitration, pulls replay rows newer than the
/// cursor carrying the authoring stamp as `lwwAt`.
class ConflictFakeTransport implements SyncTransport {
  final Map<
          String,
          Map<String,
              Map<String, (Map<String, dynamic>, DateTime, DateTime, bool)>>>
      _data = {};
  DateTime _serverClock = DateTime.now().toUtc();

  void advanceClock(Duration d) => _serverClock = _serverClock.add(d);
  String get nowIso => _serverClock.toIso8601String();

  @override
  Future<bool> companyHasData(String companyId) async =>
      _data[companyId]?.isNotEmpty ?? false;

  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    final rows = _data[companyId]?[tableName] ?? {};
    final cursorTime = cursor.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.tryParse(cursor.split('|').first) ??
            DateTime.fromMillisecondsSinceEpoch(0);
    final ops = <SyncOp>[];
    var latest = cursorTime;
    final keys = rows.keys.toList()..sort();
    for (final pk in keys) {
      final (payload, updatedAt, clientLwwAt, deleted) = rows[pk]!;
      if (updatedAt.isAfter(cursorTime)) {
        ops.add(SyncOp(
          tableName: tableName,
          rowPk: pk,
          op: deleted ? SyncOpTypes.delete : SyncOpTypes.update,
          changedAt: updatedAt,
          lwwAt: clientLwwAt,
          payload: deleted ? null : payload,
        ));
        if (updatedAt.isAfter(latest)) latest = updatedAt;
      }
    }
    return SyncPullPage(
        ops: ops, nextCursor: latest.toIso8601String(), hasMore: false);
  }

  @override
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops) async {
    advanceClock(const Duration(milliseconds: 250));
    final tables = _data.putIfAbsent(companyId, () => {});
    for (final op in ops) {
      final rows = tables.putIfAbsent(op.tableName, () => {});
      final clientStamp = op.changedAt;
      if (op.op == SyncOpTypes.delete) {
        final existing = rows[op.rowPk];
        if (existing != null &&
            !clientStamp.isAfter(existing.$3) &&
            !existing.$4) {
          continue;
        }
        rows[op.rowPk] =
            (existing?.$1 ?? const {}, _serverClock, clientStamp, true);
      } else {
        final existing = rows[op.rowPk];
        if (existing != null &&
            !existing.$4 &&
            !clientStamp.isAfter(existing.$3)) {
          continue;
        }
        rows[op.rowPk] = (
          Map<String, dynamic>.from(op.payload ?? {}),
          _serverClock,
          clientStamp,
          false
        );
      }
    }
    return SyncPushReceipt(serverTime: nowIso);
  }
}

Future<Database> _createDevice() async {
  return openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
  );
}

Future<List<Map<String, dynamic>>> _conflicts(Database db) =>
    db.query('sync_conflicts', orderBy: 'id');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database deviceA;
  late Database deviceB;
  late ConflictFakeTransport server;
  late SyncEngine engineA;
  late SyncEngine engineB;
  const company = 'company-conflicts';
  const repo = SyncConflictsRepository();

  setUp(() async {
    deviceA = await _createDevice();
    deviceB = await _createDevice();
    server = ConflictFakeTransport();
    engineA = SyncEngine(dbAccessor: () => deviceA, transport: server);
    engineB = SyncEngine(dbAccessor: () => deviceB, transport: server);
    await engineA.linkCompany(deviceA, company);
    await engineB.linkCompany(deviceB, company);
    await engineA.syncNow();
    await engineB.syncNow();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  Future<void> convergeCustomer(String id, String name) async {
    await deviceA.insert('customers', {'id': id, 'name': name});
    await engineA.syncNow();
    await engineB.syncNow();
  }

  group('conflict logging', () {
    test('conflicting update logs both snapshots (remote wins)', () async {
      await convergeCustomer('c-x', 'Base');

      // Concurrent edits: B first, then A newer.
      await deviceB.update('customers', {'name': 'Mine'},
          where: 'id = ?', whereArgs: ['c-x']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-x']);
      await engineA.syncNow();
      await engineB.syncNow(); // pushes Mine (stale), pulls Theirs

      // LWW outcome unchanged: the newer remote edit wins.
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-x']);
      expect(onB.first['name'], 'Theirs');

      final rows = await _conflicts(deviceB);
      expect(rows, hasLength(1));
      final conflict = SyncConflict.fromRow(rows.first);
      expect(conflict.tableName, 'customers');
      expect(conflict.rowPk, 'c-x');
      expect(conflict.winner, 'remote');
      expect(conflict.reviewed, isFalse);
      expect(conflict.localSnapshot?['name'], 'Mine');
      expect(conflict.remoteSnapshot?['name'], 'Theirs');
    });

    test('tie keeps local and logs winner=local (echo stays quiet)', () async {
      const tie = '2026-03-01T10:00:00.000Z';
      // Explicit updated_at survives the INSERT trigger (it only stamps
      // NULLs) and travels as the LWW key, so both sides tie exactly.
      await deviceA.insert(
          'customers', {'id': 'c-tie', 'name': 'Local', 'updated_at': tie});
      await deviceB.insert(
          'customers', {'id': 'c-tie', 'name': 'Remote', 'updated_at': tie});
      await engineA.syncNow(); // server takes Local (first writer wins ties)
      await engineB.syncNow(); // push loses the tie, pull sees Local

      // LWW unchanged: B keeps its tied local row.
      final onB = await deviceB
          .query('customers', where: 'id = ?', whereArgs: ['c-tie']);
      expect(onB.first['name'], 'Remote');

      final bRows = await _conflicts(deviceB);
      expect(bRows, hasLength(1));
      final conflict = SyncConflict.fromRow(bRows.first);
      expect(conflict.winner, 'local');
      expect(conflict.localSnapshot?['name'], 'Remote');
      expect(conflict.remoteSnapshot?['name'], 'Local');

      // A only ever saw its own echo back — no conflict.
      expect(await _conflicts(deviceA), isEmpty);
    });

    test('update-over-delete logs with a null local snapshot', () async {
      await convergeCustomer('c-u', 'Base');

      await deviceB.delete('customers', where: 'id = ?', whereArgs: ['c-u']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-u']);
      await engineA.syncNow();
      await engineB.syncNow(); // delete loses, update resurrects

      // LWW unchanged: the remote update resurrects the row.
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-u']);
      expect(onB, hasLength(1));
      expect(onB.first['name'], 'Theirs');

      final rows = await _conflicts(deviceB);
      expect(rows, hasLength(1));
      final conflict = SyncConflict.fromRow(rows.first);
      expect(conflict.winner, 'remote');
      expect(conflict.localSnapshot, isNull);
      expect(conflict.remoteSnapshot?['name'], 'Theirs');
    });

    test('delete-over-update keeps a newer local edit and logs it', () async {
      await convergeCustomer('c-d', 'Base');

      await deviceA.delete('customers', where: 'id = ?', whereArgs: ['c-d']);
      await engineA.syncNow();

      // Silenced local edit newer than the tombstone: no re-stamp, no
      // outbox entry — pure LWW input for the pull.
      await deviceB
          .insert('_sync_state', {'key': 'applying_remote', 'value': '1'});
      try {
        await deviceB.update('customers',
            {'name': 'Mine', 'updated_at': '2030-01-01T00:00:00.000Z'},
            where: 'id = ?', whereArgs: ['c-d']);
      } finally {
        await deviceB.delete('_sync_state',
            where: 'key = ?', whereArgs: ['applying_remote']);
      }
      await engineB.syncNow();

      // LWW unchanged: the newer local edit survives the older tombstone.
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-d']);
      expect(onB, hasLength(1));
      expect(onB.first['name'], 'Mine');

      final rows = await _conflicts(deviceB);
      expect(rows, hasLength(1));
      final conflict = SyncConflict.fromRow(rows.first);
      expect(conflict.winner, 'local');
      expect(conflict.localSnapshot?['name'], 'Mine');
      expect(conflict.remoteSnapshot, isNull);
    });

    test('clean propagation (insert/update/delete) logs nothing', () async {
      await deviceA.insert('customers', {'id': 'c-c', 'name': 'Calm'});
      await engineA.syncNow();
      await engineB.syncNow();
      expect(await _conflicts(deviceB), isEmpty);

      await deviceA.update('customers', {'name': 'Calmer'},
          where: 'id = ?', whereArgs: ['c-c']);
      await engineA.syncNow();
      await engineB.syncNow();
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-c']);
      expect(onB.first['name'], 'Calmer');
      expect(await _conflicts(deviceB), isEmpty);

      await deviceA.delete('customers', where: 'id = ?', whereArgs: ['c-c']);
      await engineA.syncNow();
      await engineB.syncNow();
      expect(
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-c']),
          isEmpty);
      expect(await _conflicts(deviceB), isEmpty);
    });

    test('logging failure never blocks the pull', () async {
      await convergeCustomer('c-f', 'Base');
      // Simulate a database that predates the log table: the apply and the
      // cursor must still commit.
      await deviceB.execute('DROP TABLE sync_conflicts');

      await deviceB.update('customers', {'name': 'Mine'},
          where: 'id = ?', whereArgs: ['c-f']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-f']);
      await engineA.syncNow();
      final result = await engineB.syncNow();

      expect(result.status, SyncCycleStatus.ok);
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-f']);
      expect(onB.first['name'], 'Theirs');

      // Ordinary propagation works too, with nowhere to log to.
      await deviceA.insert('customers', {'id': 'c-f2', 'name': 'Fresh'});
      await engineA.syncNow();
      await engineB.syncNow();
      expect(
          await deviceB
              .query('customers', where: 'id = ?', whereArgs: ['c-f2']),
          hasLength(1));
    });
  });

  group('review actions', () {
    test('restore-my-version re-queues the row and marks reviewed', () async {
      await convergeCustomer('c-r', 'Base');
      await deviceB.update('customers', {'name': 'Mine'},
          where: 'id = ?', whereArgs: ['c-r']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-r']);
      await engineA.syncNow();
      await engineB.syncNow();

      var rows = await _conflicts(deviceB);
      expect(rows, hasLength(1));
      final conflict = SyncConflict.fromRow(rows.first);
      expect(conflict.winner, 'remote');

      // Restore re-applies our snapshot as a new local edit: the row is back
      // and the outbox holds it for the next push.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await repo.restoreMyVersion(deviceB, conflict);
      final restored =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-r']);
      expect(restored.first['name'], 'Mine');
      final pending = await deviceB.query('_sync_outbox',
          where: 'table_name = ? AND row_pk = ? AND pushed_at IS NULL',
          whereArgs: ['customers', 'c-r']);
      expect(pending, isNotEmpty);

      rows = await _conflicts(deviceB);
      expect(SyncConflict.fromRow(rows.first).reviewed, isTrue);

      // And it syncs back out: A adopts the restored values.
      await engineB.syncNow();
      await engineA.syncNow();
      final onA =
          await deviceA.query('customers', where: 'id = ?', whereArgs: ['c-r']);
      expect(onA.first['name'], 'Mine');
    });

    test('mark-reviewed clears the unreviewed count', () async {
      await convergeCustomer('c-m', 'Base');
      await deviceB.update('customers', {'name': 'Mine'},
          where: 'id = ?', whereArgs: ['c-m']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-m']);
      await engineA.syncNow();
      await engineB.syncNow();

      expect(await repo.unreviewedCount(deviceB), 1);
      final rows = await _conflicts(deviceB);
      await repo.markReviewed(deviceB, SyncConflict.fromRow(rows.first).id);
      expect(await repo.unreviewedCount(deviceB), 0);
      expect((await repo.list(deviceB, onlyUnreviewed: true)), isEmpty);
      // The row itself is untouched by a review.
      final onB =
          await deviceB.query('customers', where: 'id = ?', whereArgs: ['c-m']);
      expect(onB.first['name'], 'Theirs');
    });

    test('snapshots round-trip through JSON', () async {
      await convergeCustomer('c-j', 'Base');
      await deviceB.update('customers', {'name': 'Mine'},
          where: 'id = ?', whereArgs: ['c-j']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await deviceA.update('customers', {'name': 'Theirs'},
          where: 'id = ?', whereArgs: ['c-j']);
      await engineA.syncNow();
      await engineB.syncNow();

      final raw = (await _conflicts(deviceB)).first;
      expect(jsonDecode(raw['local_snapshot'] as String)['name'], 'Mine');
      expect(jsonDecode(raw['remote_snapshot'] as String)['name'], 'Theirs');
      final diffs = diffSnapshots(
        SyncConflict.fromRow(raw).localSnapshot,
        SyncConflict.fromRow(raw).remoteSnapshot,
      );
      expect(diffs.map((d) => d.column), contains('name'));
    });
  });
}
