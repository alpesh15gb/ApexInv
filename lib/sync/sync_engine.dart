import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../database/database_helper.dart';
import '../database/sync_schema.dart';
import '../utils/app_logger.dart';
import 'outbox_types.dart';
import 'sync_outbox.dart';
import 'sync_transport.dart';

const _tag = 'SyncEngine';

/// Result of one full sync cycle, surfaced to the status provider.
enum SyncCycleStatus { idle, syncing, ok, error }

class SyncCycleResult {
  final SyncCycleStatus status;
  final int pushed;
  final int pulled;
  final String? error;

  const SyncCycleResult({
    required this.status,
    this.pushed = 0,
    this.pulled = 0,
    this.error,
  });

  static const idle = SyncCycleResult(status: SyncCycleStatus.idle);
}

/// Offline-first sync engine (dbplan.md §3.3–§3.5, §3.8).
///
/// Single-flight: concurrent [syncNow] calls coalesce into the running cycle
/// (the UI can hammer "sync now" safely). Order is always PUSH → PULL:
/// pushing first means our own rows are on the server before the pull cursor
/// is computed, and the pull's serverTime receipt then covers anything that
/// raced us.
///
/// The engine is dormant unless [enabled] was set (kill switch, default off)
/// — a user who never links an account gets exactly today's behavior.
class SyncEngine {
  final Database Function() dbAccessor;
  final SyncTransport transport;

  Completer<void>? _inFlight;
  Timer? _debounce;
  Timer? _pullTimer;
  Timer? _outboxWatcher;

  SyncEngine({required this.dbAccessor, required this.transport});

  // ── Kill switch / state keys ──

  static const _keyEnabled = 'sync_enabled';
  static const _keyCompanyId = 'company_id';
  static const _keyBaselineDone = 'baseline_done';
  static const _keyApplyingRemote = 'applying_remote';
  static const _keyLastPulledPrefix = 'last_pulled_';

  Future<String?> _getState(Database db, String key) async {
    final rows = await db.query('_sync_state',
        where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setState(Database db, String key, String value) async {
    await db.insert('_sync_state', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> isEnabled() async {
    final v = await _getState(dbAccessor(), _keyEnabled);
    return v == '1';
  }

  Future<void> setEnabled(Database db, bool value) async {
    await _setState(db, _keyEnabled, value ? '1' : '0');
  }

  // ── Triggers ──

  /// Fire-and-forget nudge after a local write: schedules a cycle 2s out
  /// (debounced — rapid multi-field saves produce one cycle, not one per op).
  void nudgeAfterWrite() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      unawaited(syncNow());
    });
  }

  /// Periodic pull-only safety net for changes made on other devices while
  /// this one is idle (Realtime nudge is the primary channel in Phase 3).
  void startPullTimer() {
    _pullTimer ??= Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(syncNow());
    });
  }

  /// Outbox watcher (dbplan Phase 2 trigger #2): polls the pending-op count
  /// every 2s and nudges a cycle the moment a local write lands. The capture
  /// triggers make this authoritative for every write path — repos, CSV
  /// import, restore — without instrumenting any call site. A 2s poll of an
  /// indexed partial-count query is negligible next to the write it follows.
  void startOutboxWatcher() {
    _outboxWatcher ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_inFlight != null || _debounce?.isActive == true) return;
      try {
        final pending = await _outbox(dbAccessor()).pendingCount();
        if (pending > 0) nudgeAfterWrite();
      } catch (_) {
        // DB closed mid-poll (app teardown) — nothing to do this tick.
      }
    });
  }

  void stopTimers() {
    _debounce?.cancel();
    _debounce = null;
    _pullTimer?.cancel();
    _pullTimer = null;
    _outboxWatcher?.cancel();
    _outboxWatcher = null;
  }

  /// Runs a full cycle if one isn't already running; otherwise joins the
  /// running one. Returns the completed cycle's result.
  Future<SyncCycleResult> syncNow() async {
    final db = dbAccessor();
    if (!await isEnabled()) {
      return SyncCycleResult.idle;
    }
    final companyId = await _getState(db, _keyCompanyId);
    if (companyId == null) {
      return const SyncCycleResult(
          status: SyncCycleStatus.error, error: 'No cloud company linked');
    }

    if (_inFlight != null) return _cycleResult ?? SyncCycleResult.idle;
    final completer = Completer<void>();
    _inFlight = completer;
    try {
      _cycleResult = await _runCycle(db, companyId);
    } catch (e, stack) {
      AppLogger.e(_tag, 'Sync cycle failed', e, stack);
      _cycleResult = SyncCycleResult(
          status: SyncCycleStatus.error, error: e.toString());
    } finally {
      _inFlight = null;
      completer.complete();
    }
    return _cycleResult!;
  }

  SyncCycleResult? _cycleResult;

  // ── The cycle ──

  Future<SyncCycleResult> _runCycle(Database db, String companyId) async {
    var pushed = 0;
    var pulled = 0;

    // 1. PUSH collapsed outbox.
    pushed = await _pushOutbox(db, companyId);

    // 2. PULL per table (only after baseline exists, see _ensureBaseline).
    final baselineDone = await _getState(db, _keyBaselineDone) == '1';
    if (baselineDone) {
      pulled = await _pullAll(db, companyId);
    }

    await _outbox(db).prunePushed();

    return SyncCycleResult(
        status: SyncCycleStatus.ok, pushed: pushed, pulled: pulled);
  }

  SyncOutbox _outbox(Database db) => SyncOutbox(db);

  /// Local PKs are strings everywhere except company_info's INTEGER
  /// AUTOINCREMENT id. The wire format is always a string.
  static String _pkToString(dynamic id) => id is String ? id : id.toString();

  Future<int> _pushOutbox(Database db, String companyId) async {
    final outbox = _outbox(db);
    var totalPushed = 0;

    while (true) {
      final entries = await outbox.pendingCoalesced();
      if (entries.isEmpty) break;

      final ops = <SyncOp>[];
      for (final e in entries) {
        if (e.op == SyncOpTypes.delete) {
          ops.add(SyncOp(
            tableName: e.tableName,
            rowPk: e.rowPk,
            op: SyncOpTypes.delete,
            changedAt: e.changedAt,
          ));
          continue;
        }
        // insert/update: read the row's current state. If it vanished since
        // capture (hard-deleted in the same window), push a tombstone.
        final payload = await outbox.readRowPayload(e.tableName, e.rowPk);
        if (payload == null) {
          ops.add(SyncOp(
            tableName: e.tableName,
            rowPk: e.rowPk,
            op: SyncOpTypes.delete,
            changedAt: e.changedAt,
          ));
        } else {
          ops.add(SyncOp(
            tableName: e.tableName,
            rowPk: e.rowPk,
            op: SyncOpTypes.update, // server upserts; insert/update are same
            changedAt: e.changedAt,
            payload: payload,
          ));
        }
      }

      final receipt = await transport.push(companyId, ops);
      totalPushed += ops.length;

      // Mark + advance in one local transaction. If the app dies before this
      // commits, the batch re-pushes — harmless because server upserts are
      // idempotent per row.
      await db.transaction((txn) async {
        // Write back any server-corrected fields (e.g. reassigned invoice
        // numbers), then mark every entry pushed — rejected pks are
        // permanently resolved server-side, so they must not retry.
        for (final e in entries) {
          final corrected = receipt.correctedFields[e.rowPk];
          if (corrected != null) {
            await _applyCorrectedField(txn, e.tableName, e.rowPk, corrected);
          }
        }
        await SyncOutbox(txn).markPushed(txn, entries, receipt.serverTime);
      });

      if (ops.length < 500) break; // drained
    }
    return totalPushed;
  }

  /// Server-corrected business numbers (dbplan §3.1 invoice-number
  /// reassignment). Payload keys arrive prefixed with the table for clarity;
  /// today the only corrected field is invoices.invoice_number.
  Future<void> _applyCorrectedField(
      DatabaseExecutor txn, String table, String rowPk, String value) async {
    if (table == 'invoices') {
      await txn.update('invoices', {'invoice_number': value},
          where: 'id = ?', whereArgs: [rowPk]);
    }
  }

  Future<int> _pullAll(Database db, String companyId) async {
    var total = 0;
    for (final table in syncTableOrder) {
      total += await _pullTable(db, companyId, table);
    }
    return total;
  }

  Future<int> _pullTable(Database db, String companyId, String table) async {
    var applied = 0;
    var cursor = await _getState(db, '$_keyLastPulledPrefix$table') ?? '';

    while (true) {
      final page = await transport.pull(companyId, table, cursor);

      // Apply in one transaction with the silencing flag set so the capture
      // triggers don't re-enqueue remote echoes (dbplan §3.4).
      await db.transaction((txn) async {
        await txn.insert('_sync_state',
            {'key': _keyApplyingRemote, 'value': '1'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        try {
          for (final op in page.ops) {
            await _applyRemoteOp(txn, op);
          }
          // Cursor advances only inside the same transaction — a crash
          // mid-apply re-pulls the page (apply is idempotent via LWW).
          await txn.insert('_sync_state', {
            'key': '$_keyLastPulledPrefix$table',
            'value': page.nextCursor
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        } finally {
          await txn.delete('_sync_state',
              where: 'key = ?', whereArgs: [_keyApplyingRemote]);
        }
      });

      applied += page.ops.length;
      if (!page.hasMore) break;
      cursor = page.nextCursor;
    }
    if (applied > 0) DatabaseHelper().notifyPullApplied();
    return applied;
  }

  /// Last-write-wins apply (dbplan §2): a remote row only lands if the
  /// authoring device's stamp ([SyncOp.lwwAt] — the same client-clock domain
  /// as every local updated_at) is newer than the local row's updated_at.
  /// Arbitrating against op.changedAt (server receive clock) instead mixes
  /// clock domains: a device whose clock runs ahead of the server's then
  /// sees every remote delete as "older" and silently keeps deleted rows.
  /// Deletes compare the same way, so "both a remote delete and a local
  /// edit" keeps whichever happened later.
  Future<void> _applyRemoteOp(DatabaseExecutor txn, SyncOp op) async {
    // company_info's local pk is INTEGER; everything else is TEXT.
    final local = op.tableName == 'company_info'
        ? await txn.query(op.tableName,
            where: 'id = ?',
            whereArgs: [int.tryParse(op.rowPk) ?? -1],
            limit: 1)
        : await txn.query(op.tableName,
            where: 'id = ?', whereArgs: [op.rowPk], limit: 1);

    // Same-domain LWW key; falls back to the receive stamp for legacy
    // servers that don't send lwwAt yet.
    final remoteStamp = op.lwwAt ?? op.changedAt;

    if (op.op == SyncOpTypes.delete) {
      if (local.isEmpty) return;
      final localUpdated =
          DateTime.tryParse(local.first['updated_at'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
      if (!localUpdated.isBefore(remoteStamp)) return; // local edit wins
      if (op.tableName == 'company_info') {
        await txn.delete(op.tableName,
            where: 'id = ?', whereArgs: [int.tryParse(op.rowPk) ?? -1]);
      } else {
        await txn.delete(op.tableName, where: 'id = ?', whereArgs: [op.rowPk]);
      }
      return;
    }

    final payload = Map<String, dynamic>.from(op.payload ?? {});
    if (payload.isEmpty) return;
    payload['id'] = op.rowPk;
    // Preserve our sync bookkeeping columns on insert; on update don't clobber.
    payload['company_id'] = 'local';
    payload.remove('cloud_id'); // server rows are keyed by our pk here

    final localUpdated = local.isEmpty
        ? null
        : DateTime.tryParse(local.first['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
    if (localUpdated != null && !localUpdated.isBefore(remoteStamp)) {
      return; // local row is same-or-newer → local wins
    }

    if (local.isEmpty) {
      await txn.insert(op.tableName, payload,
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await txn.update(op.tableName, payload,
          where: 'id = ?', whereArgs: [op.rowPk]);
    }
  }

  // ── First link / baseline (dbplan §3.5) ──

  /// Links this device to a cloud company and runs the baseline. Called from
  /// the Settings cloud-sync screen in Phase 2.
  Future<SyncCycleResult> linkCompany(Database db, String companyId) async {
    await db.transaction((txn) async {
      await txn.insert(
          '_sync_state',
          {
            'key': _keyCompanyId,
            'value': companyId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Fresh link: reset cursors so the first pull sees everything.
      final stale = await txn.query('_sync_state',
          where: 'key LIKE ?', whereArgs: ['$_keyLastPulledPrefix%']);
      for (final row in stale) {
        await txn.delete('_sync_state',
            where: 'key = ?', whereArgs: [row['key'] as String]);
      }
      await txn.insert('_sync_state', {'key': _keyBaselineDone, 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });

    // Pull first if the server already has data (re-link / device replace):
    // merge server state via LWW, then push our deltas on top.
    if (await transport.companyHasData(companyId)) {
      await _pullAll(db, companyId);
    }

    // Baseline: push every local row of every synced table (chunked by the
    // transport's push loop; reads see a consistent snapshot per query).
    final ops = <SyncOp>[];
    for (final table in syncTableOrder) {
      final rows = await db.query(table);
      for (final r in rows) {
        final payload = Map<String, dynamic>.from(r);
        payload.removeWhere((k, _) =>
            syncLocalOnlyColumns.contains(k) ||
            (syncPerTableLocalOnlyColumns[table]?.contains(k) ?? false));
        ops.add(SyncOp(
          tableName: table,
          rowPk: _pkToString(r['id']),
          op: SyncOpTypes.insert,
          changedAt: DateTime.tryParse(r['updated_at'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
          payload: payload,
        ));
      }
    }
    if (ops.isNotEmpty) {
      final receipt = await transport.push(companyId, ops);
      await db.insert('_sync_state', {'key': _keyBaselineDone, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Baseline ops were never in the outbox; nothing to mark. Receipt time
      // becomes the pull floor by seeding cursors.
      for (final table in syncTableOrder) {
        await _setState(db, '$_keyLastPulledPrefix$table', receipt.serverTime);
      }
    } else {
      await db.insert('_sync_state', {'key': _keyBaselineDone, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await setEnabled(db, true);
    return syncNow();
  }

  /// Post-restore hook (dbplan §3.7): after the DB file is replaced, cursors
  /// and outbox inside the restored file describe the *old* device's state.
  /// Force a full LWW merge on next sync.
  Future<void> onDatabaseReplaced() async {
    final db = dbAccessor();
    if (!await isEnabled()) return;
    await db.transaction((txn) async {
      final stale = await txn.query('_sync_state',
          where: 'key LIKE ?', whereArgs: ['$_keyLastPulledPrefix%']);
      for (final row in stale) {
        await txn.delete('_sync_state',
            where: 'key = ?', whereArgs: [row['key'] as String]);
      }
      await txn.insert('_sync_state', {'key': _keyBaselineDone, 'value': '0'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await syncNow();
  }
}
