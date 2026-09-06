import 'dart:async';
import 'dart:convert';

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
  static const _keyCursorHealDone = 'cursor_keyset_v2';

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
      _cycleResult =
          SyncCycleResult(status: SyncCycleStatus.error, error: e.toString());
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

    // 1. PUSH collapsed outbox. The pushed (table, row) keys travel into the
    // pull phase so conflict logging can tell a concurrent local edit (just
    // pushed, still newer than the last pull) apart from a clean row that
    // simply adopts the remote state.
    final pushResult = await _pushOutbox(db, companyId);
    pushed = pushResult.pushed;

    // One-time cursor heal: cursors written against the pre-keyset server
    // were bare timestamps that could sit mid-batch (a whole push batch
    // shares one server timestamp), silently skipping every same-timestamp
    // row beyond the first pulled page. Reset them exactly once — the
    // re-pull is idempotent (LWW + pull-apply echo silencing).
    if (await _getState(db, _keyCursorHealDone) != '1') {
      await db.transaction((txn) async {
        final stale = await txn.query('_sync_state',
            where: 'key LIKE ?', whereArgs: ['$_keyLastPulledPrefix%']);
        for (final row in stale) {
          await txn.delete('_sync_state',
              where: 'key = ?', whereArgs: [row['key'] as String]);
        }
        await txn.insert(
            '_sync_state', {'key': _keyCursorHealDone, 'value': '1'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      });
    }

    // 2. PULL per table (only after baseline exists, see _ensureBaseline).
    final baselineDone = await _getState(db, _keyBaselineDone) == '1';
    if (baselineDone) {
      pulled = await _pullAll(db, companyId, pushResult.ops);
    }

    await _outbox(db).prunePushed();

    return SyncCycleResult(
        status: SyncCycleStatus.ok, pushed: pushed, pulled: pulled);
  }

  SyncOutbox _outbox(Database db) => SyncOutbox(db);

  /// Local PKs are strings everywhere except company_info's INTEGER
  /// AUTOINCREMENT id. The wire format is always a string.
  static String _pkToString(dynamic id) => id is String ? id : id.toString();

  /// Pushes the collapsed outbox and reports both the op count and, per
  /// row, the last op sent (`'$table|$rowPk' → op`). The map is the pull
  /// phase's "locally dirty" signal: anything pushed in this cycle was edited
  /// concurrently with whatever the pull is about to return.
  Future<({int pushed, Map<String, String> ops})> _pushOutbox(
      Database db, String companyId) async {
    final outbox = _outbox(db);
    final pushedOps = <String, String>{};
    var totalPushed = 0;

    while (true) {
      final entries = await outbox.pendingCoalesced();
      if (entries.isEmpty) break;

      final ops = <SyncOp>[];
      for (final e in entries) {
        pushedOps['${e.tableName}|${e.rowPk}'] = e.op;
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
        } else if (e.tableName == 'invoices' && payload['deleted_at'] != null) {
          // Soft-deleted invoice → tombstone on the wire. `deleted_at` is a
          // local-only column, so pushing the row as an 'update' would strip
          // it and silently resurrect the invoice on every other device.
          ops.add(SyncOp(
            tableName: e.tableName,
            rowPk: e.rowPk,
            op: SyncOpTypes.delete,
            changedAt: e.changedAt,
          ));
        } else {
          payload.remove('deleted_at'); // stays device-local (trash)
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
    return (pushed: totalPushed, ops: pushedOps);
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

  Future<int> _pullAll(Database db, String companyId,
      [Map<String, String> pushedOps = const {}]) async {
    var total = 0;
    for (final table in syncTableOrder) {
      total += await _pullTable(db, companyId, table, pushedOps);
    }
    return total;
  }

  Future<int> _pullTable(Database db, String companyId, String table,
      [Map<String, String> pushedOps = const {}]) async {
    var applied = 0;
    var cursor = await _getState(db, '$_keyLastPulledPrefix$table') ?? '';

    while (true) {
      final page = await transport.pull(companyId, table, cursor);

      // Apply in one transaction with the silencing flag set so the capture
      // triggers don't re-enqueue remote echoes (dbplan §3.4).
      await db.transaction((txn) async {
        await txn.insert(
            '_sync_state', {'key': _keyApplyingRemote, 'value': '1'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        try {
          for (final op in page.ops) {
            await _applyRemoteOp(txn, op, pushedOps);
          }
          // Cursor advances only inside the same transaction — a crash
          // mid-apply re-pulls the page (apply is idempotent via LWW).
          await txn.insert('_sync_state',
              {'key': '$_keyLastPulledPrefix$table', 'value': page.nextCursor},
              conflictAlgorithm: ConflictAlgorithm.replace);
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
  ///
  /// LWW outcomes here are the contract (tests pin them); conflict logging
  /// is purely additive. Whenever a remote op contends with a locally-
  /// modified row — update-over-update, update-over-delete, delete-over-
  /// update, in tie or local-newer cases as well as when a dirty local row
  /// loses — both snapshots are recorded to `sync_conflicts` BEFORE the
  /// overwrite, in this same pull transaction, with the kept side as winner.
  /// Logging is best-effort: any failure is swallowed so a broken log can
  /// never abort the pull (the cursor must keep advancing).
  Future<void> _applyRemoteOp(DatabaseExecutor txn, SyncOp op,
      [Map<String, String> pushedOps = const {}]) async {
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
      if (!localUpdated.isBefore(remoteStamp)) {
        // Local edit wins — the remote delete is silently dropped. Log the
        // contention (delete-over-update, tie or local-newer) before
        // returning; the row itself is untouched.
        await _tryLogConflict(txn,
            tableName: op.tableName,
            rowPk: op.rowPk,
            localSnapshot: Map<String, dynamic>.from(local.first),
            remoteSnapshot: null,
            winner: 'local');
        return;
      }
      // Remote delete wins. Log only when the deleted row carries local
      // modifications (pushed this cycle or still pending); a clean older
      // row adopting a tombstone is ordinary propagation, not a conflict.
      final dirty =
          await _isLocallyDirty(txn, op.tableName, op.rowPk, pushedOps);
      Map<String, dynamic>? localSnapshot;
      if (dirty) localSnapshot = Map<String, dynamic>.from(local.first);
      if (op.tableName == 'company_info') {
        await txn.delete(op.tableName,
            where: 'id = ?', whereArgs: [int.tryParse(op.rowPk) ?? -1]);
      } else {
        await txn.delete(op.tableName, where: 'id = ?', whereArgs: [op.rowPk]);
      }
      if (dirty) {
        await _tryLogConflict(txn,
            tableName: op.tableName,
            rowPk: op.rowPk,
            localSnapshot: localSnapshot,
            remoteSnapshot: null,
            winner: 'remote');
      }
      return;
    }

    final payload = Map<String, dynamic>.from(op.payload ?? {});
    if (payload.isEmpty) return;
    payload['id'] = op.rowPk;
    // Preserve our sync bookkeeping columns on insert; on update don't clobber.
    payload['company_id'] = 'local';
    payload.remove('cloud_id'); // server rows are keyed by our pk here

    // Forward-compat: strip keys unknown to this build's schema so a newer
    // app's column cannot abort the whole pull txn (cursor included).
    final stripped = await _stripUnknownPullColumns(txn, op.tableName, payload);

    if (local.isEmpty) {
      // No local row. A remote upsert only contends when the row is missing
      // because WE deleted it (update-over-delete): the apply below
      // resurrects it, discarding our delete.
      final localDelete =
          await _latestPendingOp(txn, op.tableName, op.rowPk) == 'delete' ||
              pushedOps['${op.tableName}|${op.rowPk}'] == 'delete';
      await txn.insert(op.tableName, stripped,
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (localDelete) {
        await _tryLogConflict(txn,
            tableName: op.tableName,
            rowPk: op.rowPk,
            localSnapshot: null,
            remoteSnapshot: stripped,
            winner: 'remote');
      }
      return;
    }

    final localUpdated =
        DateTime.tryParse(local.first['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
    if (!localUpdated.isBefore(remoteStamp)) {
      // Local row is same-or-newer → local wins and the remote payload is
      // silently dropped. Log the contention (update-over-update, tie or
      // local-newer) unless the payload is identical to what we hold (a
      // push echo of our own row coming back through the pull cursor).
      if (_remotePayloadDiffers(stripped, local.first)) {
        await _tryLogConflict(txn,
            tableName: op.tableName,
            rowPk: op.rowPk,
            localSnapshot: Map<String, dynamic>.from(local.first),
            remoteSnapshot: stripped,
            winner: 'local');
      }
      return; // local row is same-or-newer → local wins
    }

    // Remote is strictly newer and overwrites. Log only when the overwritten
    // row carries local modifications (pushed this cycle or still pending);
    // a clean older row adopting the newer state is ordinary propagation.
    // The echo check doubles as a guard: an identical payload is never a
    // conflict even if bookkeeping looks dirty.
    final dirty = _remotePayloadDiffers(stripped, local.first) &&
        await _isLocallyDirty(txn, op.tableName, op.rowPk, pushedOps);
    Map<String, dynamic>? localSnapshot;
    if (dirty) localSnapshot = Map<String, dynamic>.from(local.first);
    await txn
        .update(op.tableName, stripped, where: 'id = ?', whereArgs: [op.rowPk]);
    if (dirty) {
      await _tryLogConflict(txn,
          tableName: op.tableName,
          rowPk: op.rowPk,
          localSnapshot: localSnapshot,
          remoteSnapshot: stripped,
          winner: 'remote');
    }
  }

  /// True when the local row was modified concurrently with the incoming
  /// pull: pushed to the server earlier in this same cycle, or still sitting
  /// unpushed in the outbox (written during the push, or pulled before any
  /// push ran — e.g. first-link merge). Read-only; any failure degrades to
  /// "clean" so detection itself can never break the pull.
  Future<bool> _isLocallyDirty(DatabaseExecutor txn, String table, String rowPk,
      Map<String, String> pushedOps) async {
    try {
      if (pushedOps.containsKey('$table|$rowPk')) return true;
      return await _latestPendingOp(txn, table, rowPk) != null;
    } catch (_) {
      return false;
    }
  }

  /// Latest still-unpushed op for a row, or null when the row is clean.

  Future<String?> _latestPendingOp(
      DatabaseExecutor txn, String table, String rowPk) async {
    try {
      final rows = await txn.query('_sync_outbox',
          columns: ['op'],
          where: 'table_name = ? AND row_pk = ? AND pushed_at IS NULL',
          whereArgs: [table, rowPk],
          orderBy: 'seq DESC',
          limit: 1);
      return rows.isEmpty ? null : rows.first['op'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// True when the incoming payload actually differs from the held row on at
  /// least one business column. Sync bookkeeping (`company_id`, `cloud_id`,
  /// `updated_at`) and the key itself are excluded — they always differ on
  /// echoes of our own just-pushed rows.
  bool _remotePayloadDiffers(
      Map<String, dynamic> stripped, Map<String, dynamic> local) {
    for (final entry in stripped.entries) {
      if (entry.key == 'id' ||
          entry.key == 'company_id' ||
          entry.key == 'cloud_id' ||
          entry.key == 'updated_at' ||
          entry.key == 'rowid') {
        continue;
      }
      if (!_conflictValuesEqual(entry.value, local[entry.key])) return true;
    }
    return false;
  }

  bool _conflictValuesEqual(Object? a, Object? b) {
    if (a == b) return true;
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    return false;
  }

  /// Best-effort conflict insert inside the caller's pull transaction. NEVER
  /// throws: a logging failure is recorded to the app log and the pull
  /// (apply + cursor) commits without the conflict row.
  Future<void> _tryLogConflict(
    DatabaseExecutor txn, {
    required String tableName,
    required String rowPk,
    required Map<String, dynamic>? localSnapshot,
    required Map<String, dynamic>? remoteSnapshot,
    required String winner,
  }) async {
    try {
      await txn.insert('sync_conflicts', {
        'table_name': tableName,
        'row_pk': rowPk,
        'local_snapshot':
            localSnapshot == null ? null : jsonEncode(localSnapshot),
        'remote_snapshot':
            remoteSnapshot == null ? null : jsonEncode(remoteSnapshot),
        'winner': winner,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'reviewed': 0,
      });
    } catch (e) {
      AppLogger.w(_tag, 'sync_conflicts log failed (pull continues): $e');
    }
  }

  /// Drops payload keys that are not columns of [table] (PRAGMA table_info
  /// allowlist, same concept as the backup restore helper) + logs. Keeps a
  /// newer app's unknown column from aborting the pull transaction.
  Future<Map<String, dynamic>> _stripUnknownPullColumns(
      DatabaseExecutor txn, String table, Map<String, dynamic> payload) async {
    final cols = await txn.rawQuery('PRAGMA table_info($table)');
    final known = {for (final c in cols) (c['name'] as String).toLowerCase()};
    final stripped = <String, dynamic>{};
    for (final e in payload.entries) {
      if (known.contains(e.key.toLowerCase())) {
        stripped[e.key] = e.value;
      }
    }
    final dropped =
        payload.keys.where((k) => !known.contains(k.toLowerCase())).toList();
    if (dropped.isNotEmpty) {
      AppLogger.w(_tag, 'Pull stripped unknown columns for $table: $dropped');
    }
    // 'id' is always a real column; if the table itself is unknown the
    // payload degrades to just the key (insert still fails loudly, but a
    // single unknown column can no longer starve the cursor).
    return stripped;
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

    // Baseline: push every local row of every synced table. Soft-deleted
    // invoices are skipped (the trash is device-local; a baseline push of
    // the row would resurrect it on other devices). Chunked at 500 ops per
    // push — matches the outbox drain size and the server's 5000-op cap,
    // and keeps any single push's rows inside one page of pulls.
    final ops = <SyncOp>[];
    for (final table in syncTableOrder) {
      final rows = await db.query(table);
      for (final r in rows) {
        if (table == 'invoices' && r['deleted_at'] != null) continue;
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
      var lastServerTime = '';
      const chunkSize = 500;
      for (var i = 0; i < ops.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, ops.length);
        final receipt = await transport.push(companyId, ops.sublist(i, end));
        lastServerTime = receipt.serverTime;
      }
      await db.insert('_sync_state', {'key': _keyBaselineDone, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Baseline ops were never in the outbox; nothing to mark. Receipt time
      // becomes the pull floor by seeding cursors ('|' suffix = keyset token
      // with empty pk; the tiebreaker keeps same-timestamp rows ordered).
      for (final table in syncTableOrder) {
        await _setState(db, '$_keyLastPulledPrefix$table', '$lastServerTime|');
      }
    } else {
      await db.insert('_sync_state', {'key': _keyBaselineDone, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await setEnabled(db, true);
    return syncNow();
  }

  /// Post-restore hook (dbplan §3.7): after the DB file is replaced, cursors
  /// inside the restored file describe the *old* device's state, so they are
  /// cleared to force a full LWW merge on next sync. The outbox is
  /// intentionally kept — it is durable local truth and must still push.
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
      // The restored DB already holds a full dataset, so the baseline is
      // done: the next cycle must PULL deltas (with cleared cursors this is
      // a full re-pull, applied idempotently via LWW). This must be '1' —
      // _runCycle skips pulls entirely while baselineDone != '1' and nothing
      // else flips it back, so '0' here would silently disable pulls forever.
      await txn.insert('_sync_state', {'key': _keyBaselineDone, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await syncNow();
  }
}
