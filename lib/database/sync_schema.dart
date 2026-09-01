import 'package:sqflite/sqflite.dart';

/// Schema pieces for the offline-first sync foundation (dbplan.md §3.2).
///
/// Shared by the fresh-create path (`DatabaseHelper._createDB`) and the
/// upgrade path (migration v45) so both produce identical trigger/DDL state.
/// Everything here is additive: no existing column or table is altered in a
/// breaking way, and the sync engine never runs unless the user links a cloud
/// account (kill switch default off), so pre-sync behavior is unchanged.
///
/// Design notes:
/// - Every synced business table gets `company_id` + `updated_at`.
///   `company_id` defaults to 'local' — the single-company placeholder that
///   Phase 2 maps to the user's cloud company at link time.
/// - `invoices` and `company_info` additionally get `cloud_id` because their
///   local PKs are NOT uuids (sequential string / AUTOINCREMENT).
/// - SQLite triggers capture every INSERT/UPDATE/DELETE into `_sync_outbox`,
///   transactionally with the write itself. Hand-instrumenting 84 call-sites
///   across 14 service files was rejected precisely because triggers cannot
///   miss a path (CSV import, backup restore, future features).
/// - The `applying_remote` flag in `_sync_state` silences the triggers while
///   the sync engine applies pulled changes, so remote echoes never re-enter
///   the outbox.
/// - The capture triggers double as the `updated_at` backstop: the INSERT
///   trigger stamps rows the write path left without a timestamp, and the
///   UPDATE trigger re-stamps on every edit (except during pull-apply — see
///   its body for why). The inner stamp UPDATE cannot re-fire the capture
///   (trigger-internal statements don't cascade on the same table with
///   SQLite's default settings — probed empirically).

/// Tables synced to the cloud, in dependency order (parents first) for
/// baseline upload and pull-apply. `invoice_items` syncs as part of its
/// parent invoice payload (dbplan §3.1) but still carries sync columns so
/// its trigger contributes to the parent's outbox coalescing.
const syncTableOrder = <String>[
  'company_info',
  'customers',
  'products',
  'purchase_bills',
  'purchase_bill_items',
  'purchase_bill_payments',
  'invoices',
  'invoice_items',
  'invoice_payments',
];

/// Tables whose PK is not a uuid and therefore need a `cloud_id` column.
const cloudIdTables = <String>['company_info', 'invoices'];

/// Columns that are local-only and must be stripped before pushing a row to
/// the cloud (per-table extras beyond the shared `_sync_localOnlyColumns`).
const syncPerTableLocalOnlyColumns = <String, List<String>>{
  'invoices': ['deleted_at'], // handled separately as tombstone semantics
};

/// Columns that are local-only and must be stripped before pushing a row to
/// the cloud. NOTE: `updated_at` is deliberately NOT here — it is the LWW
/// key and must travel with the payload (the server clamps future values);
/// only the server's own receipt stamp is cursor-local.
const syncLocalOnlyColumns = <String>{
  'company_id',
  'cloud_id',
  'rowid',
};

/// Adds the sync columns to [table] if the table exists and columns are
/// missing. Idempotent — safe to call from both create and upgrade paths.
/// Silently skips tables that don't exist yet (a later migration may create
/// them and register sync columns itself).
Future<void> addSyncColumns(Database db, String table,
    {bool withCloudId = false, bool withDeletedAt = false}) async {
  final exists = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
          [table])) ==
      1;
  if (!exists) return;
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  final names = cols.map((r) => r['name'] as String).toSet();

  if (!names.contains('company_id')) {
    await db.execute(
        "ALTER TABLE $table ADD COLUMN company_id TEXT NOT NULL DEFAULT 'local'");
  }
  if (!names.contains('updated_at')) {
    await db.execute('ALTER TABLE $table ADD COLUMN updated_at TEXT');
  }
  if (withCloudId && !names.contains('cloud_id')) {
    await db.execute('ALTER TABLE $table ADD COLUMN cloud_id TEXT');
  }
  if (withDeletedAt && !names.contains('deleted_at')) {
    await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
  }
}

/// Installs outbox + state tables and change-capture triggers. Idempotent.
/// Only installs capture triggers for tables that exist — a later migration
/// re-runs this to pick up newly created tables.
Future<void> installSyncCapture(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS _sync_outbox (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      table_name TEXT NOT NULL,
      row_pk     TEXT NOT NULL,
      op         TEXT NOT NULL,
      changed_at TEXT NOT NULL,
      pushed_at  TEXT
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_pending ON _sync_outbox(pushed_at) WHERE pushed_at IS NULL');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_outbox_table_row ON _sync_outbox(table_name, row_pk)');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS _sync_state (
      key   TEXT PRIMARY KEY,
      value TEXT
    )
  ''');

  for (final table in syncTableOrder) {
    final exists = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            [table])) ==
        1;
    if (!exists) continue;
    await _installTableTriggers(db, table);
  }
}

Future<void> _installTableTriggers(Database db, String table) async {
  // DROP-first makes re-runs idempotent and lets us evolve trigger bodies in
  // later migrations without needing SQLite's (absent) CREATE OR REPLACE.
  await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_ins');
  await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_upd');
  await db.execute('DROP TRIGGER IF EXISTS trg_${table}_sync_del');

  // Silencing predicates. `applying_remote` stops capture while the engine
  // applies pulled rows; `stamping` stops the UPDATE capture from echoing
  // while the INSERT trigger stamps updated_at in place (cross-trigger
  // recursion is NOT suppressed by SQLite — only self-recursion is — so the
  // stamp would otherwise enqueue a phantom 'update' op for every insert).
  const guard = '''
    IFNULL((SELECT value FROM _sync_state WHERE key = 'applying_remote'), '0') <> '1'
  ''';
  const guardWithStamping = '''
    $guard
    AND IFNULL((SELECT value FROM _sync_state WHERE key = 'stamping'), '0') <> '1'
  ''';

  await db.execute('''
    CREATE TRIGGER trg_${table}_sync_ins AFTER INSERT ON $table
    BEGIN
      INSERT INTO _sync_state(key, value) VALUES ('stamping', '1')
        ON CONFLICT(key) DO UPDATE SET value = '1';
      UPDATE $table
      SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE rowid = NEW.rowid AND NEW.updated_at IS NULL;
      DELETE FROM _sync_state WHERE key = 'stamping';
      INSERT INTO _sync_outbox(table_name, row_pk, op, changed_at)
      SELECT '$table', NEW.id, 'insert', COALESCE(NEW.updated_at, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
      WHERE $guard;
    END
  ''');

  // UPDATE capture RE-STAMPS updated_at unconditionally (outside pull-apply):
  // an edited row's LWW key must advance even when the row already carries an
  // inherited updated_at — e.g. a row pulled from the cloud whose payload
  // kept the authoring device's stamp. Without the re-stamp, an edit to a
  // pulled row reuses that stale stamp, the pushed changedAt ties with the
  // author's, and the edit silently loses arbitration everywhere. During
  // pull-apply (`applying_remote`), the stamp is skipped so the payload's
  // authoring timestamp lands untouched — pull-side LWW compares it against
  // the authoring device's lwwAt in the same client-clock domain.
  await db.execute('''
    CREATE TRIGGER trg_${table}_sync_upd AFTER UPDATE ON $table
    BEGIN
      UPDATE $table
      SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE rowid = NEW.rowid AND $guard;
      INSERT INTO _sync_outbox(table_name, row_pk, op, changed_at)
      SELECT '$table', NEW.id, 'update', strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE $guardWithStamping;
    END
  ''');

  await db.execute('''
    CREATE TRIGGER trg_${table}_sync_del AFTER DELETE ON $table
    BEGIN
      INSERT INTO _sync_outbox(table_name, row_pk, op, changed_at)
      SELECT '$table', OLD.id, 'delete', strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE $guard;
    END
  ''');

  // (updated_at stamping is handled inside the capture triggers themselves —
  // see the module doc comment for why there is no separate touch trigger.)
}

/// Backfills `updated_at` for pre-existing rows so all rows share a baseline
/// and LWW has no NULLs. Uses the rowid ordering as a cheap proxy for
/// creation order; every value is distinct-but-stable and in the past.
Future<void> backfillSyncColumns(Database db) async {
  for (final table in syncTableOrder) {
    final exists = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            [table])) ==
        1;
    if (!exists) continue;
    await db.execute('''
      UPDATE $table SET updated_at =
        strftime('%Y-%m-%dT%H:%M:%fZ', '2000-01-01 00:00:00', '+' || rowid || ' seconds')
      WHERE updated_at IS NULL
    ''');
  }

  // cloud_id backfill for invoices/company_info.
  for (final table in cloudIdTables) {
    await db.execute('''
      UPDATE $table SET cloud_id = lower(hex(randomblob(4)) || '-' || hex(randomblob(2))
        || '-4' || substr(lower(hex(randomblob(2))),2) || '-'
        || substr('89ab', abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(3))),2))
      WHERE cloud_id IS NULL
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_cloud_id ON $table(cloud_id) WHERE cloud_id IS NOT NULL');
  }
}
