// Regression test for the bricked-startup crash:
// v54 CREATE UNIQUE INDEX idx_invoices_number_unique failed with
// "UNIQUE constraint failed: invoices.invoice_number" on real user data,
// because the v54 dedup guessed MAX(text)+1 per row — which collides with an
// existing row whenever numbering schemes mix (padded, prefixed, bare).
// Retry re-ran the same flawed guess, so the app could never start.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:apexbooks/database/database_helper.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v53/v54 dedup survives mixed-format duplicate numbers', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    // Minimal tables the v53/v54 steps touch.
    await db.execute(
        'CREATE TABLE invoices (id TEXT PRIMARY KEY, invoice_number TEXT)');
    await db.execute(
        'CREATE TABLE invoice_payments (id TEXT PRIMARY KEY, receipt_number TEXT)');
    // Two exact dupes + formats whose TEXT-max digit-guess collides:
    // TEXT max is 'INV-1' -> digits 1 -> guess '00000002', already taken.
    await db.insert('invoices', {'id': 'a', 'invoice_number': '00000001'});
    await db.insert('invoices', {'id': 'b', 'invoice_number': '00000001'});
    await db.insert('invoices', {'id': 'c', 'invoice_number': '00000002'});
    await db.insert('invoices', {'id': 'd', 'invoice_number': 'INV-1'});
    await db.insert('invoices', {'id': 'e', 'invoice_number': 'INV-1'});
    await db.insert('invoices', {'id': 'f', 'invoice_number': '43'});
    await db.insert('invoice_payments', {'id': 'p1', 'receipt_number': 'R1'});
    await db.insert('invoice_payments', {'id': 'p2', 'receipt_number': 'R1'});

    // Must not throw (old code: UNIQUE constraint failed on index create).
    await DatabaseHelper()
        .upgradeDbForTest(db, 52, DatabaseHelper().dbVersion);

    final dupes = await db.rawQuery(
        'SELECT invoice_number FROM invoices WHERE invoice_number IS NOT NULL GROUP BY invoice_number HAVING COUNT(*) > 1');
    expect(dupes, isEmpty);
    // Earliest rows keep their numbers; every row still present.
    final rows = await db.query('invoices', orderBy: 'rowid ASC');
    expect(rows.length, 6);
    expect(rows[0]['invoice_number'], '00000001');
    expect(rows[2]['invoice_number'], '00000002');
    expect(rows[3]['invoice_number'], 'INV-1');
    expect(rows[5]['invoice_number'], '43');
    final receipts = await db.rawQuery(
        'SELECT receipt_number FROM invoice_payments GROUP BY receipt_number HAVING COUNT(*) > 1');
    expect(receipts, isEmpty);
    await db.close();
  });
}
