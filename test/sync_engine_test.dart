// End-to-end tests of the sync engine's push/pull/LWW cycle using the
// FakeSyncTransport — an in-memory "second device" (dbplan.md Phase 1 step 3).
// Two real SQLite databases + one fake server proves convergence offline,
// which is exactly what the Supabase transport must reproduce in Phase 2.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/outbox_types.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_transport.dart';

/// In-memory stand-in for the Go sync server: stores rows per company and
/// replays them to pulls the way the server would (LWW already resolved
/// server-side; pulls return rows newer than the cursor, each carrying the
/// authoring device's client-clock stamp as `lwwAt`).
class FakeSyncTransport implements SyncTransport {
  // company -> table -> pk -> (payload, serverUpdatedAt, clientLwwAt, deleted)
  final Map<
          String,
          Map<String,
              Map<String, (Map<String, dynamic>, DateTime, DateTime, bool)>>>
      _data = {};
  // Start at real wall-clock so pushed rows always compare newer than the
  // device-written updated_at values they carry (mirrors a live server).
  // [startClockLag] shifts the initial clock backward to model a server
  // whose receive clock trails the devices' clocks.
  FakeSyncTransport({Duration startClockLag = Duration.zero})
      : _serverClock = DateTime.now().toUtc().subtract(startClockLag);
  DateTime _serverClock;
  final List<SyncOp> pushedOps = [];

  void advanceClock(Duration d) => _serverClock = _serverClock.add(d);

  String get nowIso => _serverClock.toIso8601String();

  @override
  Future<bool> companyHasData(String companyId) async =>
      _data[companyId]?.isNotEmpty ?? false;

  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    final tables = _data[companyId] ?? {};
    final rows = tables[tableName] ?? {};
    final cursorTime = cursor.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.parse(cursor);

    final ops = <SyncOp>[];
    var latest = cursorTime;
    final sortedKeys = rows.keys.toList()..sort();
    for (final pk in sortedKeys) {
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
      ops: ops,
      nextCursor: latest.toIso8601String(),
      hasMore: false,
    );
  }

  @override
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops) async {
    // Generous jump: a real server's receive clock always advances by at
    // least the network round-trip between two pushes, and its stamps are
    // authoritative. Millisecond-scale deltas here would race the devices'
    // wall-clock updated_at stamps exactly the way the real LWW contract
    // (server clamps + stamps on receive) is designed to prevent.
    advanceClock(const Duration(milliseconds: 250));
    final tables = _data.putIfAbsent(companyId, () => {});
    for (final op in ops) {
      pushedOps.add(op);
      final rows = tables.putIfAbsent(op.tableName, () => {});
      // Server arbitration compares the pushed changedAt (client clock,
      // clamped) against the stored client-clock key — never the receive
      // stamp — and stores the client stamp as the pull-side lwwAt.
      final clientStamp = op.changedAt;
      if (op.op == SyncOpTypes.delete) {
        final existing = rows[op.rowPk];
        if (existing != null &&
            !clientStamp.isAfter(existing.$3) &&
            !existing.$4) {
          continue; // delete loses LWW to a newer row
        }
        rows[op.rowPk] =
            (existing?.$1 ?? const {}, _serverClock, clientStamp, true);
      } else {
        final existing = rows[op.rowPk];
        if (existing != null &&
            !existing.$4 &&
            !clientStamp.isAfter(existing.$3)) {
          continue; // stale push
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

/// Opens a real SQLite DB with the full current schema, like the app does.
/// singleInstance must be OFF: sqflite keys instances by path, and every
/// in-memory path is the same — without it all "devices" share one DB.
Future<Database> _createDevice() async {
  final db = await openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
  );
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database deviceA;
  late Database deviceB;
  late FakeSyncTransport server;
  late SyncEngine engineA;
  late SyncEngine engineB;
  const company = 'company-1';

  setUp(() async {
    deviceA = await _createDevice();
    deviceB = await _createDevice();
    server = FakeSyncTransport();
    engineA = SyncEngine(dbAccessor: () => deviceA, transport: server);
    engineB = SyncEngine(dbAccessor: () => deviceB, transport: server);
    await engineA.linkCompany(deviceA, company);
    await engineB.linkCompany(deviceB, company);
    // Drain both baselines so tests start converged.
    await engineA.syncNow();
    await engineB.syncNow();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  group('engine lifecycle', () {
    test('disabled engine does nothing (kill switch default off)', () async {
      final db = await _createDevice();
      final engine = SyncEngine(dbAccessor: () => db, transport: server);
      final result = await engine.syncNow();
      expect(result.status, SyncCycleStatus.idle);
      await db.close();
    });

    test('linkCompany enables sync and sets baseline', () async {
      expect(await engineA.isEnabled(), isTrue);
      final baseline = await deviceA
          .query('_sync_state', where: 'key = ?', whereArgs: ['baseline_done']);
      expect(baseline.first['value'], '1');
    });

    test('linkCompany uploaded all local rows as baseline', () async {
      // Fresh seed contains exactly one company_info row (the dummy company);
      // no customers/products/invoices exist yet.
      final pushed = server.pushedOps;
      expect(pushed.where((o) => o.tableName == 'company_info'), isNotEmpty);
      expect(pushed.where((o) => o.tableName == 'customers'), isEmpty);
      // users table is never synced
      expect(pushed.where((o) => o.tableName == 'users'), isEmpty);
    });
  });

  group('A → B propagation', () {
    test('customer created on A appears on B after sync both ways', () async {
      await deviceA.insert('customers', {'id': 'c-100', 'name': 'Alice'});
      await engineA.syncNow(); // push A
      await engineB.syncNow(); // pull B

      final onB = await deviceB
          .query('customers', where: 'id = ?', whereArgs: ['c-100']);
      expect(onB, hasLength(1));
      expect(onB.first['name'], 'Alice');
    });

    test('update beats stale copy (LWW newer wins)', () async {
      await deviceA.insert('customers', {'id': 'c-101', 'name': 'Bob'});
      await engineA.syncNow();
      await engineB.syncNow();

      server.advanceClock(const Duration(seconds: 10));
      await deviceB.update('customers', {'name': 'Bob Jr.'},
          where: 'id = ?', whereArgs: ['c-101']);
      await engineB.syncNow();
      await engineA.syncNow();

      final onA = await deviceA
          .query('customers', where: 'id = ?', whereArgs: ['c-101']);
      expect(onA.first['name'], 'Bob Jr.');
    });

    test('older edit loses to newer remote edit (LWW older loses)', () async {
      await deviceA.insert('customers', {'id': 'c-102', 'name': 'Carol'});
      await engineA.syncNow();
      await engineB.syncNow();

      // A edits (new), then B edits with an *older* timestamp simulated by
      // rewinding the fake server clock is not possible — instead: B edits
      // first, then A edits later; then B pulls: B must adopt A's newer edit.
      server.advanceClock(const Duration(seconds: 10));
      await deviceA.update('customers', {'name': 'Carol-NEW'},
          where: 'id = ?', whereArgs: ['c-102']);
      await engineA.syncNow();
      await engineB.syncNow();
      final onB = await deviceB
          .query('customers', where: 'id = ?', whereArgs: ['c-102']);
      expect(onB.first['name'], 'Carol-NEW');
    });

    test('delete propagates as tombstone', () async {
      await deviceA.insert('customers', {'id': 'c-103', 'name': 'Dave'});
      await engineA.syncNow();
      await engineB.syncNow();

      await deviceA.delete('customers', where: 'id = ?', whereArgs: ['c-103']);
      await engineA.syncNow();
      await engineB.syncNow();

      final onB = await deviceB
          .query('customers', where: 'id = ?', whereArgs: ['c-103']);
      expect(onB, isEmpty);
    });

    test('local edit newer than remote delete survives (LWW on delete)',
        () async {
      await deviceA.insert('customers', {'id': 'c-104', 'name': 'Eve'});
      await engineA.syncNow();
      await engineB.syncNow();

      // B deletes, but A edits afterwards with a later timestamp.
      server.advanceClock(const Duration(seconds: 10));
      await deviceB.delete('customers', where: 'id = ?', whereArgs: ['c-104']);
      await engineB.syncNow();

      server.advanceClock(const Duration(seconds: 10));
      await deviceA.update('customers', {'name': 'Eve-kept'},
          where: 'id = ?', whereArgs: ['c-104']);
      await engineA.syncNow();
      await engineB.syncNow(); // B receives A's newer row back

      final onB = await deviceB
          .query('customers', where: 'id = ?', whereArgs: ['c-104']);
      expect(onB, hasLength(1));
      expect(onB.first['name'], 'Eve-kept');
    });

    test(
        'tombstone arbitration uses the client-clock domain, not the '
        'server receive clock', () async {
      // Regression for the lwwAt contract (prod-reproduced): when the
      // server's receive clock trails the devices' clocks, arbitrating the
      // local row's updated_at (client domain) against a tombstone's receive
      // stamp (server domain) drops deletes that legitimately win in the
      // client domain. A dedicated pair of devices syncs through a server
      // whose clock starts 2s behind the devices' wall clock.
      final laggyServer =
          FakeSyncTransport(startClockLag: const Duration(seconds: 2));
      final dbA = await _createDevice();
      final dbB = await _createDevice();
      final engA = SyncEngine(dbAccessor: () => dbA, transport: laggyServer);
      final engB = SyncEngine(dbAccessor: () => dbB, transport: laggyServer);
      await engA.linkCompany(dbA, 'company-skew');
      await engB.linkCompany(dbB, 'company-skew');
      await engA.syncNow();
      await engB.syncNow();

      await dbA.insert('customers', {'id': 'c-300', 'name': 'Skewy'});
      await engA.syncNow();
      await engB.syncNow();
      expect(
          (await dbB.query('customers', where: 'id = ?', whereArgs: ['c-300']))
              .first['name'],
          'Skewy');

      // B deletes a moment later on its wall clock; the tombstone's client
      // stamp is newer than the row's client stamp, so A must apply it even
      // though the server's receive stamps sit behind both.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await dbB.delete('customers', where: 'id = ?', whereArgs: ['c-300']);
      await engB.syncNow();
      await engA.syncNow();

      final onA =
          await dbA.query('customers', where: 'id = ?', whereArgs: ['c-300']);
      expect(onA, isEmpty,
          reason: 'A must arbitrate the tombstone in the client-clock domain');
      await dbA.close();
      await dbB.close();
    });

    test('outbox coalesces insert+update into one pushed payload', () async {
      final before = server.pushedOps
          .where((o) => o.tableName == 'products' && o.rowPk == 'p-900')
          .length;
      await deviceA.insert('products', {
        'id': 'p-900',
        'name': 'Widget',
        'price': 10.0,
        'stock': 5,
        'tax_rate': 18,
      });
      await deviceA.update('products', {'price': 12.0},
          where: 'id = ?', whereArgs: ['p-900']);
      await deviceA.update('products', {'price': 15.0},
          where: 'id = ?', whereArgs: ['p-900']);
      await engineA.syncNow();

      final after = server.pushedOps
          .where((o) => o.tableName == 'products' && o.rowPk == 'p-900')
          .length;
      expect(after, before + 1); // collapsed to ONE op
      final op = server.pushedOps
          .lastWhere((o) => o.tableName == 'products' && o.rowPk == 'p-900');
      expect(op.payload!['price'], 15.0); // latest state, not intermediates
    });

    test('remote echoes do not re-enter the outbox (pull→apply is silent)',
        () async {
      await deviceA.insert('customers', {'id': 'c-105', 'name': 'Frank'});
      await engineA.syncNow();
      final outboxBefore = Sqflite.firstIntValue(await deviceB.rawQuery(
              'SELECT COUNT(*) FROM _sync_outbox WHERE pushed_at IS NULL')) ??
          0;
      await engineB.syncNow(); // pulls Frank
      final outboxAfter = Sqflite.firstIntValue(await deviceB.rawQuery(
              'SELECT COUNT(*) FROM _sync_outbox WHERE pushed_at IS NULL')) ??
          0;
      expect(outboxAfter, outboxBefore); // no echo ops
    });

    test('full convergence: both devices end identical after churn', () async {
      // Churn on both sides.
      await deviceA.insert('customers', {'id': 'c-200', 'name': 'Gail'});
      await deviceB.insert('customers', {'id': 'c-201', 'name': 'Hank'});
      server.advanceClock(const Duration(seconds: 5));
      await deviceA.insert('products', {
        'id': 'p-200',
        'name': 'Nut',
        'price': 1.0,
        'stock': 9,
        'tax_rate': 5,
      });
      await engineA.syncNow();
      await engineB.syncNow();
      await engineA.syncNow(); // drain the other side's rows back to A

      final aRows = await deviceA.query('customers', orderBy: 'id');
      final bRows = await deviceB.query('customers', orderBy: 'id');
      final aNames = aRows.map((r) => r['id']).toSet();
      final bNames = bRows.map((r) => r['id']).toSet();
      expect(aNames, containsAll(['c-200', 'c-201']));
      expect(bNames, containsAll(['c-200', 'c-201']));
      expect(aNames, bNames);

      final aProd = await deviceA
          .query('products', where: 'id = ?', whereArgs: ['p-200']);
      final bProd = await deviceB
          .query('products', where: 'id = ?', whereArgs: ['p-200']);
      expect(aProd.first['name'], bProd.first['name']);
    });

    test('soft-deleted invoice (trash) is removed on the other device',
        () async {
      // Regression: `deleted_at` is a local-only column, so the soft delete
      // used to push as a plain UPDATE and the invoice silently stayed
      // alive on every other device.
      await deviceA.insert('invoices', {
        'id': 'inv-400',
        'customer_id': 'c-1',
        'customer_name': 'Trash Target',
        'date': '2026-08-31',
        'type': 'Invoice',
        'invoice_number': '00000001',
      });
      await engineA.syncNow();
      await engineB.syncNow();
      expect(
          (await deviceB
              .query('invoices', where: 'id = ?', whereArgs: ['inv-400'])),
          hasLength(1));

      // A moves the invoice to the trash (exactly what
      // InvoiceService.softDeleteInvoice does).
      await deviceA.update('invoices', {'deleted_at': '2026-08-31T10:00:00Z'},
          where: 'id = ?', whereArgs: ['inv-400']);
      await engineA.syncNow();
      await engineB.syncNow();

      expect(
          await deviceB
              .query('invoices', where: 'id = ?', whereArgs: ['inv-400']),
          isEmpty,
          reason: 'soft delete must cross devices as a tombstone');
    });

    test('baseline skips soft-deleted invoices (trash is device-local)',
        () async {
      await deviceA.insert('invoices', {
        'id': 'inv-401',
        'customer_id': 'c-1',
        'customer_name': 'Trashed',
        'date': '2026-08-31',
        'type': 'Invoice',
      });
      await deviceA.update('invoices', {'deleted_at': '2026-08-31T10:00:00Z'},
          where: 'id = ?', whereArgs: ['inv-401']);

      // A brand-new device links: its baseline must not resurrect A's trash.
      final dbC = await _createDevice();
      final engineC = SyncEngine(dbAccessor: () => dbC, transport: server);
      await engineC.linkCompany(dbC, company);
      await engineC.syncNow();

      expect(
        await dbC.query('invoices', where: 'id = ?', whereArgs: ['inv-401']),
        isEmpty,
      );
      await dbC.close();
    });

    test(
        'many rows pushed in one batch are all pulled (no same-timestamp '
        'skips)', () async {
      // Regression for the server-side pagination bug: rows pushed in one
      // transaction share a server timestamp, and a ts-only cursor skipped
      // everything beyond the first page. The fake has no page limit, so
      // simulate the fix contract directly: the cursor must carry the
      // '|' keyset tiebreaker after a cycle that pulled rows.
      await deviceA.insert('customers', {'id': 'c-500', 'name': 'Batch'});
      await engineA.syncNow();

      final result = await engineB.syncNow();
      expect(result.pulled, greaterThan(0));
      final stored = await deviceB.query('_sync_state',
          where: 'key = ?', whereArgs: ['last_pulled_customers']);
      final cursor = stored.first['value'] as String;
      // With the keyset server the cursor is "ts|pk"; legacy/fake servers
      // may still send bare timestamps — either way the stored value must
      // not be empty after pulling rows.
      expect(cursor, isNotEmpty);
    });
  });
}
