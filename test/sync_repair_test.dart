// Regression test for the v46 -> v48 startup crash:
//   SqfliteFfiException: no such column: updated_at
//   Causing statement: UPDATE expense_categories SET updated_at = ...
//
// Databases migrated by older builds missed sync columns on tables that were
// registered for sync later (expense_categories, expenses, batch_info,
// custom_fields, purchase_orders, purchase_order_items). Later backfills
// assumed the columns present and crashed on startup, blocking the app.
//
// The test reproduces that legacy partial state (columns + triggers stripped
// from the late-registered tables) and runs the real upgrade chain to the
// current version, which must repair it without throwing.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/sync_schema.dart';

// Tables the legacy v45 migration covered (those carrying triggers on the
// database from the crash report). Everything else in syncTableOrder missed
// its sync columns.
const _legacySynced = {
  'company_info',
  'customers',
  'products',
  'invoices',
  'invoice_items',
  'invoice_payments',
  'purchase_bills',
  'purchase_bill_items',
};

Future<bool> _tableExists(Database db, String table) async {
  return Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
          [table])) ==
      1;
}

Future<Set<String>> _columnNames(Database db, String table) async {
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  return cols.map((r) => r['name'] as String).toSet();
}

/// Fresh database stripped down to the legacy partial-sync state.
Future<Database> _openLegacyPartial() async {
  final db = await openDatabase(
    inMemoryDatabasePath,
    version: DatabaseHelper().dbVersion,
    singleInstance: false,
    onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
  );
  for (final table in syncTableOrder) {
    if (_legacySynced.contains(table)) continue;
    if (!await _tableExists(db, table)) continue;
    // DROP COLUMN refuses while triggers reference the column.
    await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_ins');
    await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_upd');
    await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_del');
    final cols = await _columnNames(db, table);
    for (final col in ['updated_at', 'company_id', 'cloud_id']) {
      if (cols.contains(col)) {
        await db.execute('ALTER TABLE $table DROP COLUMN $col');
      }
    }
  }
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('backfill skips tables missing updated_at instead of crashing',
      () async {
    final db = await _openLegacyPartial();
    // Pre-fix this threw "no such column: updated_at" on expense_categories.
    await backfillSyncColumns(db);
    await db.close();
  });

  test('upgrade 50 to 51 adds price_includes_tax without data loss', () async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: DatabaseHelper().dbVersion,
      singleInstance: false,
      onCreate: (db, v) => DatabaseHelper().createDbForTest(db, v),
    );
    // Simulate a v50 database: strip the v51 columns, keep legacy rows.
    for (final table in [
      'purchase_bill_items',
      'purchase_bills',
      'sale_orders',
      'purchase_orders',
    ]) {
      await db.execute('ALTER TABLE $table DROP COLUMN price_includes_tax');
    }
    await db.insert('purchase_bills', {
      'id': 'bill-legacy',
      'supplier_name': 'Legacy Supplier',
      'date': DateTime.now().toIso8601String(),
    });
    await db.insert('purchase_bill_items', {
      'id': 'line-legacy',
      'purchase_bill_id': 'bill-legacy',
      'product_name': 'Legacy Item',
      'quantity': 2,
      'rate': 100,
      'tax_rate': 18,
      'taxable_value': 200,
      'amount': 236,
    });

    await DatabaseHelper().upgradeDbForTest(db, 50, DatabaseHelper().dbVersion);

    for (final table in [
      'purchase_bill_items',
      'purchase_bills',
      'sale_orders',
      'purchase_orders',
    ]) {
      expect(await _columnNames(db, table), contains('price_includes_tax'),
          reason: table);
    }
    // Legacy rows default to exclusive (0) with amounts untouched.
    final bill = (await db.query('purchase_bills',
            where: 'id = ?', whereArgs: ['bill-legacy']))
        .single;
    expect(bill['price_includes_tax'], 0);
    final line = (await db.query('purchase_bill_items',
            where: 'id = ?', whereArgs: ['line-legacy']))
        .single;
    expect(line['price_includes_tax'], 0);
    expect(line['amount'], 236);

    await db.close();
  });

  test('upgrade 46 to current repairs missing sync columns', () async {
    final db = await _openLegacyPartial();
    await DatabaseHelper().upgradeDbForTest(db, 46, DatabaseHelper().dbVersion);

    for (final table in syncTableOrder) {
      if (!await _tableExists(db, table)) continue;
      final names = await _columnNames(db, table);
      expect(names, contains('company_id'), reason: table);
      expect(names, contains('updated_at'), reason: table);
      final nulls = Sqflite.firstIntValue(await db
          .rawQuery('SELECT COUNT(*) FROM $table WHERE updated_at IS NULL'));
      expect(nulls, 0, reason: table);
    }

    final triggers = (await db
            .rawQuery("SELECT name FROM sqlite_master WHERE type='trigger'"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(triggers, contains('trg_expense_categories_sync_ins'));

    // A write to a repaired table works through its reinstalled triggers.
    await db.insert('expense_categories', {'id': 'cat-test', 'name': 'Test'});
    final outbox = Sqflite.firstIntValue(await db.rawQuery(
        "SELECT COUNT(*) FROM _sync_outbox WHERE table_name = 'expense_categories'"));
    expect(outbox, greaterThan(0));

    await db.close();
  });
}
