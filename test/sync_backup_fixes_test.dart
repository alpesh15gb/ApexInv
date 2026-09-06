// Regression tests for VERIFIED sync/backup fixes F1–F6.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/backup/backup_manager.dart';
import 'package:apexbooks/database/batch_info_service.dart';
import 'package:apexbooks/database/custom_field_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/ledger_service.dart';
import 'package:apexbooks/database/purchase_order_service.dart';
import 'package:apexbooks/database/report_service.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_outbox.dart';
import 'package:apexbooks/sync/outbox_types.dart';
import 'package:apexbooks/sync/sync_transport.dart';

class _FakeTransport implements SyncTransport {
  final Map<
          String,
          Map<String,
              Map<String, (Map<String, dynamic>, DateTime, DateTime, bool)>>>
      _data = {};
  DateTime _clock = DateTime.now().toUtc();
  final List<SyncOp> pushedOps = [];

  @override
  Future<bool> companyHasData(String companyId) async =>
      _data[companyId]?.isNotEmpty ?? false;

  @override
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops) async {
    _clock = _clock.add(const Duration(milliseconds: 250));
    final tables = _data.putIfAbsent(companyId, () => {});
    for (final op in ops) {
      pushedOps.add(op);
      final rows = tables.putIfAbsent(op.tableName, () => {});
      final stamp = op.changedAt;
      if (op.op == SyncOpTypes.delete) {
        final existing = rows[op.rowPk];
        if (existing != null && !stamp.isAfter(existing.$3) && !existing.$4) {
          continue;
        }
        rows[op.rowPk] = (existing?.$1 ?? const {}, _clock, stamp, true);
      } else {
        final existing = rows[op.rowPk];
        if (existing != null && !existing.$4 && !stamp.isAfter(existing.$3)) {
          continue;
        }
        rows[op.rowPk] =
            (Map<String, dynamic>.from(op.payload ?? {}), _clock, stamp, false);
      }
    }
    return SyncPushReceipt(serverTime: _clock.toIso8601String());
  }

  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    final tables = _data[companyId] ?? {};
    final rows = tables[tableName] ?? {};
    final cursorTime = cursor.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.parse(cursor.split('|').first);
    final ops = <SyncOp>[];
    var latest = cursorTime;
    final keys = rows.keys.toList()..sort();
    for (final pk in keys) {
      final (payload, updatedAt, clientLww, deleted) = rows[pk]!;
      if (updatedAt.isAfter(cursorTime)) {
        ops.add(SyncOp(
          tableName: tableName,
          rowPk: pk,
          op: deleted ? SyncOpTypes.delete : SyncOpTypes.update,
          changedAt: updatedAt,
          lwwAt: clientLww,
          payload: deleted ? null : payload,
        ));
        if (updatedAt.isAfter(latest)) latest = updatedAt;
      }
    }
    return SyncPullPage(
        ops: ops, nextCursor: latest.toIso8601String(), hasMore: false);
  }
}

/// Transport that injects a bogus column into every pulled payload.
class _BogusColumnTransport extends _FakeTransport {
  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    final page = await super.pull(companyId, tableName, cursor);
    if (tableName != 'customers' || page.ops.isEmpty) return page;
    final withBogus = page.ops.map((op) {
      if (op.payload == null) return op;
      return SyncOp(
        tableName: op.tableName,
        rowPk: op.rowPk,
        op: op.op,
        changedAt: op.changedAt,
        lwwAt: op.lwwAt,
        payload: {...op.payload!, 'bogus_future_column_xyz': 'evil'},
      );
    }).toList();
    return SyncPullPage(
        ops: withBogus, nextCursor: page.nextCursor, hasMore: page.hasMore);
  }
}

Future<Database> _createDevice() {
  return openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
  );
}

final _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
  });

  group('F1 uuid PK mint', () {
    test('two invoice ids are distinct UUIDs', () async {
      final a = await InvoiceService.generateNextId();
      final b = await InvoiceService.generateNextId();
      expect(a, isNot(equals(b)));
      expect(_uuidRe.hasMatch(a.toLowerCase()), isTrue,
          reason: 'invoice id should be UUID v4, got $a');
      expect(_uuidRe.hasMatch(b.toLowerCase()), isTrue);
    });

    test('other sequential PKs now mint UUIDs', () async {
      final b1 = await BatchInfoService.generateNextId();
      final b2 = await BatchInfoService.generateNextId();
      expect(b1, isNot(equals(b2)));
      expect(_uuidRe.hasMatch(b1.toLowerCase()), isTrue);

      final c1 = await CustomFieldService.generateNextId();
      final c2 = await CustomFieldService.generateNextId();
      expect(c1, isNot(equals(c2)));
      expect(_uuidRe.hasMatch(c1.toLowerCase()), isTrue);

      final p1 = await PurchaseOrderService.generateNextId();
      final p2 = await PurchaseOrderService.generateNextId();
      expect(p1, isNot(equals(p2)));
      expect(_uuidRe.hasMatch(p1.toLowerCase()), isTrue);
    });

    test('display invoice_number still sequential after uuid PKs', () async {
      final db = await _createDevice();
      DatabaseHelper().useDatabaseForTest(db);
      try {
        // Legacy sequential row.
        await db.insert('invoices', {
          'id': '00000041',
          'invoice_number': '00000041',
          'customer_id': 'c-1',
          'customer_name': 'Legacy',
          'date': '2026-01-01',
          'type': 'Invoice',
        });
        final n1 = await InvoiceService.generateNextInvoiceNumber('Invoice');
        expect(n1, '00000042');
        // UUID row must not pollute the display sequence.
        final uuid = await InvoiceService.generateNextId();
        await db.insert('invoices', {
          'id': uuid,
          'invoice_number': n1,
          'customer_id': 'c-1',
          'customer_name': 'New',
          'date': '2026-01-02',
          'type': 'Invoice',
        });
        final n2 = await InvoiceService.generateNextInvoiceNumber('Invoice');
        expect(n2, '00000043');
      } finally {
        DatabaseHelper().clearDatabaseForTest();
        await db.close();
      }
    });

    test('sync push/pull round-trip with legacy + uuid ids', () async {
      final deviceA = await _createDevice();
      final deviceB = await _createDevice();
      final server = _FakeTransport();
      final engineA = SyncEngine(dbAccessor: () => deviceA, transport: server);
      final engineB = SyncEngine(dbAccessor: () => deviceB, transport: server);
      try {
        await engineA.linkCompany(deviceA, 'company-f1');
        await engineB.linkCompany(deviceB, 'company-f1');
        await engineA.syncNow();
        await engineB.syncNow();

        await deviceA.insert('invoices', {
          'id': '00000099',
          'invoice_number': '00000099',
          'customer_id': 'c-1',
          'customer_name': 'Legacy Inv',
          'date': '2026-08-31',
          'type': 'Invoice',
        });
        final uuid = const Uuid().v4();
        await deviceA.insert('invoices', {
          'id': uuid,
          'invoice_number': '00000100',
          'customer_id': 'c-1',
          'customer_name': 'Uuid Inv',
          'date': '2026-08-31',
          'type': 'Invoice',
        });
        await engineA.syncNow();
        await engineB.syncNow();

        final legacyOnB = await deviceB
            .query('invoices', where: 'id = ?', whereArgs: ['00000099']);
        final uuidOnB =
            await deviceB.query('invoices', where: 'id = ?', whereArgs: [uuid]);
        expect(legacyOnB, hasLength(1));
        expect(uuidOnB, hasLength(1));
        expect(uuidOnB.first['invoice_number'], '00000100');
      } finally {
        await deviceA.close();
        await deviceB.close();
      }
    });
  });

  group('F2 outbox over-mark', () {
    test('concurrent edit during push stays pending', () async {
      final db = await _createDevice();
      try {
        await db.insert('customers', {'id': 'c-f2', 'name': 'v1'});
        final outbox = SyncOutbox(db);
        final snapshot = await outbox.pendingCoalesced();
        expect(snapshot, isNotEmpty);
        // Concurrent edit lands during the (seconds-long) push.
        await db.update('customers', {'name': 'v2'},
            where: 'id = ?', whereArgs: ['c-f2']);
        // Push completes: mark only the snapshot.
        await db.transaction((txn) async {
          await SyncOutbox(txn).markPushed(
              txn, snapshot, DateTime.now().toUtc().toIso8601String());
        });
        final pending = await outbox.pendingCount();
        expect(pending, greaterThan(0),
            reason: 'concurrent edit must stay pending after markPushed');
        final rows = await db.query('_sync_outbox',
            where: 'table_name = ? AND row_pk = ? AND pushed_at IS NULL',
            whereArgs: ['customers', 'c-f2']);
        expect(rows, isNotEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('F3 json restore replaces', () {
    test('missing sections end up empty, not merged', () async {
      final db = await _createDevice();
      DatabaseHelper().useDatabaseForTest(db);
      Directory? tmp;
      try {
        await db.insert('expenses', {
          'id': 'exp-keep',
          'description': 'Keep me?',
          'amount': 10,
          'date': DateTime(2026, 1, 1).toIso8601String(),
          'category_id': 'cat-other',
        });
        await db.insert('loan_accounts', {
          'id': 'loan-keep',
          'name': 'Keep loan',
          'lender': 'Bank',
          'original_principal': 100,
          'start_date': DateTime(2026, 1, 1).toIso8601String(),
        });
        await db.insert('loan_movements', {
          'id': 'lm-keep',
          'loan_id': 'loan-keep',
          'date': DateTime(2026, 1, 2).toIso8601String(),
          'type': 'drawdown',
          'principal_amount': 100,
          'account_id': 'cash-default',
        });
        expect(await db.query('expenses'), isNotEmpty);
        expect(await db.query('loan_accounts'), isNotEmpty);

        tmp = await Directory.systemTemp.createTemp('apex_f3_');
        final jsonPath = '${tmp.path}/backup.json';
        final backupData = {
          'customers': [
            {'id': 'c-new', 'name': 'Fresh'}
          ],
          '_metadata': {'version': '1.0'},
        };
        await File(jsonPath).writeAsString(jsonEncode(backupData));
        final result =
            await BackupManager().restoreBackup(backupPath: jsonPath);
        expect(result.success, isTrue, reason: result.message);
        expect(await db.query('expenses'), isEmpty);
        expect(await db.query('loan_accounts'), isEmpty);
        expect(await db.query('loan_movements'), isEmpty);
        expect(
            await db.query('customers', where: 'id = ?', whereArgs: ['c-new']),
            hasLength(1));
      } finally {
        DatabaseHelper().clearDatabaseForTest();
        await db.close();
        try {
          await tmp?.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('F4 manifest + temp verify', () {
    test('manifest round-trip detects tampering', () async {
      final tmp = await Directory.systemTemp.createTemp('apex_f4_');
      try {
        final f = File('${tmp.path}/a.invoicedb');
        await f.writeAsBytes(utf8.encode('hello-db'));
        await BackupManager.writeManifest(f.path);
        expect(await BackupManager.verifyManifest(f.path), isTrue);
        await f.writeAsBytes(utf8.encode('hello-db-tampered'),
            mode: FileMode.write);
        expect(await BackupManager.verifyManifest(f.path), isFalse);
        // Legacy file without sidecar still verifies.
        final legacy = File('${tmp.path}/legacy.invoicedb');
        await legacy.writeAsBytes(utf8.encode('legacy'));
        expect(await BackupManager.verifyManifest(legacy.path), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('temp-verify gates integrity and unknown tables', () async {
      final tmp = await Directory.systemTemp.createTemp('apex_f4db_');
      try {
        final goodPath = '${tmp.path}/good.invoicedb';
        final db = await openDatabase(goodPath,
            version: DatabaseHelper().dbVersion,
            onCreate: (d, v) => DatabaseHelper().createDbForTest(d, v));
        await db.close();
        await BackupManager.verifyTempDatabase(goodPath);

        final evilPath = '${tmp.path}/evil.invoicedb';
        final evil = await openDatabase(evilPath,
            version: DatabaseHelper().dbVersion,
            onCreate: (d, v) => DatabaseHelper().createDbForTest(d, v));
        await evil.execute('CREATE TABLE evil_pwn (id TEXT PRIMARY KEY)');
        await evil.close();
        await expectLater(BackupManager.verifyTempDatabase(evilPath),
            throwsA(isA<StateError>()));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('F5 pull forward-compat', () {
    test('payload with bogus column applies cleanly', () async {
      final deviceA = await _createDevice();
      final deviceB = await _createDevice();
      final server = _BogusColumnTransport();
      final engineA = SyncEngine(dbAccessor: () => deviceA, transport: server);
      final engineB = SyncEngine(dbAccessor: () => deviceB, transport: server);
      try {
        await engineA.linkCompany(deviceA, 'company-f5');
        await engineB.linkCompany(deviceB, 'company-f5');
        await engineA.syncNow();
        await engineB.syncNow();

        await deviceA.insert('customers', {'id': 'c-f5', 'name': 'Future'});
        final pushRes = await engineA.syncNow();
        expect(pushRes.status, SyncCycleStatus.ok);
        // Pull injects the bogus column; must not throw and must advance.
        final pullRes = await engineB.syncNow();
        expect(pullRes.status, SyncCycleStatus.ok);
        final onB = await deviceB
            .query('customers', where: 'id = ?', whereArgs: ['c-f5']);
        expect(onB, hasLength(1));
        expect(onB.first['name'], 'Future');
      } finally {
        await deviceA.close();
        await deviceB.close();
      }
    });
  });

  group('F6 minor fixes', () {
    test('F6a ledger ignores bounced purchase payments in v47 decision',
        () async {
      final db = await _createDevice();
      DatabaseHelper().useDatabaseForTest(db);
      try {
        await db.insert('purchase_bills', {
          'id': 'bill-f6a',
          'supplier_name': 'Supplier F6a',
          'date': DateTime(2026, 1, 5).toIso8601String(),
          'total_amount': 1000,
          'total_tax': 0,
          'amount_paid': 200,
          'itc_eligible': 1,
          'reverse_charge': 0,
          'currency_code': 'INR',
          'currency_symbol': '₹',
        });
        await db.insert('purchase_bill_payments', {
          'id': 'pbp-bounced',
          'purchase_bill_id': 'bill-f6a',
          'amount_paid': 200,
          'previously_paid': 0,
          'balance_after': 800,
          'date_paid': DateTime(2026, 1, 6).toIso8601String(),
          'cheque_status': 'bounced',
        });
        final journal = await LedgerService.getJournal(
            from: DateTime(2026, 1, 1), to: DateTime(2026, 1, 31));
        final entry =
            journal.firstWhere((e) => e.description.contains('Supplier F6a'));
        double payableCredit = 0;
        for (final l in entry.lines) {
          if (l.account == LedgerService.accPayable) payableCredit += l.credit;
        }
        // Live-only SUM is 0, so the legacy 200 aggregate is preserved and
        // payables are 800. Including the bounced row would give 1000.
        expect(payableCredit, closeTo(800, 0.01));
      } finally {
        DatabaseHelper().clearDatabaseForTest();
        await db.close();
      }
    });

    test('F6b day-book keeps same-numbered invoices separate', () async {
      final db = await _createDevice();
      DatabaseHelper().useDatabaseForTest(db);
      try {
        // Legacy pre-v54 data could hold duplicate display numbers across
        // customers (v54 dedups + enforces UNIQUE). Drop the guard to seed
        // that shape, then verify the day-book no longer merges them.
        await db.execute('DROP INDEX IF EXISTS idx_invoices_number_unique');
        final day = DateTime(2026, 2, 10, 12).toIso8601String();
        await db.insert('invoices', {
          'id': 'inv-f6b-1',
          'invoice_number': '00000001',
          'customer_id': 'c-a',
          'customer_name': 'Alice',
          'date': '2026-02-10',
          'type': 'Invoice',
          'currency_code': 'INR',
        });
        await db.insert('invoices', {
          'id': 'inv-f6b-2',
          'invoice_number': '00000001',
          'customer_id': 'c-b',
          'customer_name': 'Bob',
          'date': '2026-02-10',
          'type': 'Invoice',
          'currency_code': 'INR',
        });
        for (final entry in [
          ('pay-a', 'inv-f6b-1'),
          ('pay-b', 'inv-f6b-2'),
        ]) {
          await db.insert('invoice_payments', {
            'id': entry.$1,
            'invoice_id': entry.$2,
            'invoice_number': '00000001',
            'receipt_number': 'r-${entry.$1}',
            'amount_paid': 100,
            'balance_after': 0,
            'date_paid': day,
            'cheque_status': 'none',
          });
        }
        final rows = await ReportService.getDayBook(
            DateTime(2026, 2, 1), DateTime(2026, 2, 28));
        final receipts =
            rows.where((r) => r.description.startsWith('Receipt —')).toList();
        expect(receipts.length, 2,
            reason: 'same number, different invoices must not merge');
      } finally {
        DatabaseHelper().clearDatabaseForTest();
        await db.close();
      }
    });

    test('F6c expense backfill uses account currency, not hardcoded INR',
        () async {
      final db = await _createDevice();
      DatabaseHelper().useDatabaseForTest(db);
      try {
        await db.insert('financial_accounts', {
          'id': 'bank-usd-f6c',
          'name': 'USD Bank',
          'type': 'bank',
          'currency_code': 'USD',
          'currency_symbol': '\$',
          'opening_balance': 0,
          'opening_date': DateTime(2000).toIso8601String(),
          'active': 1,
        });
        await db.insert('expenses', {
          'id': 'exp-f6c',
          'description': 'USD expense',
          'amount': 50,
          'date': DateTime(2026, 1, 10).toIso8601String(),
          'category_id': 'cat-other',
          'payment_method': 'Bank Transfer',
          'account_id': 'bank-usd-f6c',
        });
        // Re-run the v48 backfill step over the current schema (idempotent).
        await DatabaseHelper().upgradeDbForTest(db, 47, 48);
        final exp = (await db
                .query('expenses', where: 'id = ?', whereArgs: ['exp-f6c']))
            .first;
        final accId = exp['account_id'] as String?;
        expect(accId, isNotNull);
        final acc = (await db.query('financial_accounts',
                where: 'id = ?', whereArgs: [accId]))
            .first;
        expect(acc['currency_code'], 'USD',
            reason: 'expense with a USD account must not be forced to INR');
      } finally {
        DatabaseHelper().clearDatabaseForTest();
        await db.close();
      }
    });
  });
}
