// Regression test for the bricked-startup crash:
// "no such column: cheque_status ... FROM purchase_bill_payments".
// Databases that crossed v48 before the purchase-side linking columns
// landed in `link_operational_payments` have the invoice-side columns but
// lack account_id/cheque_id/cheque_status/payment_group_id on
// purchase_bill_payments. v57 must heal them idempotently.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v57 heals purchase_bill_payments missing v48 link columns', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE _migration_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        version INTEGER,
        step TEXT,
        status TEXT,
        message TEXT,
        applied_at TEXT
      )
    ''');
    // Old shape: pre-v48 purchase-side columns missing, invoice side intact
    // (exactly the live-DB shape that crashed startup).
    await db.execute('''
      CREATE TABLE purchase_bill_payments (
        id TEXT PRIMARY KEY,
        purchase_bill_id TEXT NOT NULL,
        amount_paid REAL NOT NULL,
        previously_paid REAL NOT NULL DEFAULT 0,
        balance_after REAL NOT NULL DEFAULT 0,
        date_paid TEXT NOT NULL,
        payment_method TEXT,
        notes TEXT
      )
    ''');
    await db.execute(
        'CREATE TABLE invoice_payments (id TEXT PRIMARY KEY, cheque_status TEXT)');
    await db.execute('CREATE TABLE invoices (id TEXT PRIMARY KEY)');
    await db.execute('CREATE TABLE expenses (id TEXT PRIMARY KEY)');

    await DatabaseHelper().upgradeDbForTest(db, 56, 57);

    final cols = await db.rawQuery('PRAGMA table_info(purchase_bill_payments)');
    final names = cols.map((c) => c['name'] as String).toSet();
    expect(
        names,
        containsAll([
          'account_id',
          'cheque_id',
          'cheque_status',
          'payment_group_id',
        ]));

    // The exact query shape that crashed startup must now run.
    final rows = await db.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN COALESCE(cheque_status, 'none') NOT IN ('bounced', 'cancelled') THEN amount_paid ELSE 0 END), 0) AS v FROM purchase_bill_payments WHERE purchase_bill_id = ?",
        ['vy-purchase-bill-1']);
    expect(rows.first['v'], 0);

    // Idempotent: second run is a no-op success.
    await DatabaseHelper().upgradeDbForTest(db, 56, 57);
    await db.close();
  });
}
