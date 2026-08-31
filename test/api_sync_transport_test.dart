// Two-device convergence against the REAL sync server (dbplan Phase 2 item
// 6). Requires a reachable API; skipped otherwise:
//
//   $env:API_TEST_URL = "https://api.apexbooks.in"   # or http://localhost:8080
//   flutter test test/api_sync_transport_test.dart
//
// Spins up two SyncEngines over two in-memory SQLite DBs (device A/B) with
// ApiSyncTransport instances hitting the same cloud company — the same
// convergence contract test/sync_engine_test.dart proves with the fake, now
// through HTTP, the Go server, and Postgres.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/api_sync_transport.dart';
import 'package:apexbooks/sync/sync_account.dart';
import 'package:apexbooks/sync/sync_engine.dart';

const apiURL = String.fromEnvironment('API_TEST_URL');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final host = apiURL;
  if (host.isEmpty) {
    test('API integration skipped (set API_TEST_URL / --dart-define)', () {
      markTestSkipped(
          'API_TEST_URL not set; real-server convergence test skipped');
    });
    return;
  }

  late Database deviceA;
  late Database deviceB;
  late SyncEngine engineA;
  late SyncEngine engineB;
  late SyncAccount account;
  late String companyId;

  Future<Database> createDevice() => openDatabase(
        inMemoryDatabasePath,
        version: DatabaseHelper().dbVersion,
        singleInstance: false,
        onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
      );

  SyncEngine engineFor(Database db) => SyncEngine(
        dbAccessor: () => db,
        transport: ApiSyncTransport(
          baseUrl: host,
          tokenProvider: () async => account.token,
        ),
      );

  setUpAll(() async {
    // Unique account per run — the server assigns fresh UUIDs.
    final ts = DateTime.now().millisecondsSinceEpoch;
    final client = SyncAccountClient(baseUrl: host);
    final res = await client.register(
        'conv-$ts@test.local', 'convergence-123', 'Conv Co $ts');
    account = res.account!;
    companyId = account.companyId;
  });

  setUp(() async {
    deviceA = await createDevice();
    deviceB = await createDevice();
    engineA = engineFor(deviceA);
    engineB = engineFor(deviceB);
    await engineA.linkCompany(deviceA, companyId);
    await engineB.linkCompany(deviceB, companyId);
    await engineA.syncNow();
    await engineB.syncNow();
  });

  tearDown(() async {
    await deviceA.close();
    await deviceB.close();
  });

  test('A → server → B: customer created on A reaches B', () async {
    await deviceA.insert('customers', {'id': 'conv-c1', 'name': 'Alice'});
    await engineA.syncNow();
    await engineB.syncNow();

    final onB = await deviceB
        .query('customers', where: 'id = ?', whereArgs: ['conv-c1']);
    expect(onB, hasLength(1));
    expect(onB.first['name'], 'Alice');
  });

  test('B → server → A: delete on B removes row on A', () async {
    await deviceA.insert('customers', {'id': 'conv-c2', 'name': 'Bob'});
    await engineA.syncNow();
    await engineB.syncNow();

    await deviceB
        .delete('customers', where: 'id = ?', whereArgs: ['conv-c2']);
    await engineB.syncNow();
    await engineA.syncNow();

    final onA = await deviceA
        .query('customers', where: 'id = ?', whereArgs: ['conv-c2']);
    expect(onA, isEmpty);
  });

  test('LWW through the server: newer edit wins on both devices', () async {
    await deviceA.insert('customers', {'id': 'conv-c3', 'name': 'Old Name'});
    await engineA.syncNow();
    await engineB.syncNow();

    // Ensure a strictly later client timestamp than the baseline row.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await deviceA.update('customers', {'name': 'New Name'},
        where: 'id = ?', whereArgs: ['conv-c3']);
    await engineA.syncNow();
    await engineB.syncNow();

    final onB = await deviceB
        .query('customers', where: 'id = ?', whereArgs: ['conv-c3']);
    expect(onB.first['name'], 'New Name');
  });

  test('invoice numbers stay unique across devices after collision',
      () async {
    final t = DateTime.now().toUtc().toIso8601String();
    await deviceA.insert('invoices', {
      'id': 'conv-inv-1',
      'type': 'Invoice',
      'invoice_number': '90000001',
      'date': t,
      'customer_id': '',
      'updated_at': t,
    });
    await deviceB.insert('invoices', {
      'id': 'conv-inv-2',
      'type': 'Invoice',
      'invoice_number': '90000001',
      'date': t,
      'customer_id': '',
      'updated_at': t,
    });
    await engineA.syncNow();
    await engineB.syncNow();
    await engineA.syncNow(); // A receives B's corrected row

    final numbers = (await deviceA.query('invoices',
            where: "id LIKE 'conv-inv-%'",
            orderBy: 'id'))
        .map((r) => r['invoice_number'])
        .toSet();
    expect(numbers.length, 2, reason: 'collision must be reassigned');
  });
}
