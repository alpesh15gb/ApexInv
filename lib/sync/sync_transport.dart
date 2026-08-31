/// One coalesced row-change heading to (or arriving from) the cloud.
///
/// See dbplan.md §3.3/§3.4. A pushed op is the *latest* state of a row
/// (insert+update collapse to one upsert; insert+delete becomes a tombstone).
/// A pulled op is the server's canonical row plus its server-side timestamp.
class SyncOp {
  final String tableName;
  final String rowPk;
  final String op; // 'insert' | 'update' | 'delete'
  final DateTime changedAt;

  /// Client-clock arbitration key for pulled ops (dbplan §2 LWW): the
  /// authoring device's updated_at for updates, the deleting device's
  /// changed_at for deletes. Null on push (clients stamp their own) and on
  /// server versions that predate the field — arbitration then falls back
  /// to [changedAt].
  final DateTime? lwwAt;

  /// Full row payload for upserts (null for deletes). Local-only columns are
  /// stripped by the engine before transport.
  final Map<String, dynamic>? payload;

  const SyncOp({
    required this.tableName,
    required this.rowPk,
    required this.op,
    required this.changedAt,
    this.lwwAt,
    this.payload,
  });
}

/// Result the server (or a fake in tests) returns for a completed pull of
/// one table: the changed rows and the cursor to resume from next time.
class SyncPullPage {
  final List<SyncOp> ops;

  /// Server timestamp to store as `last_pulled_<table>` — only ever advanced
  /// after the ops are durably applied locally.
  final String nextCursor;

  /// True when the server has more rows past this page; the engine loops.
  final bool hasMore;

  const SyncPullPage({
    required this.ops,
    required this.nextCursor,
    required this.hasMore,
  });
}

/// Push receipt from the server for one batch.
class SyncPushReceipt {
  /// Server clock at commit — used as the pull cursor floor so our own push
  /// doesn't race the next pull.
  final String serverTime;

  /// row_pks the server rejected (already-resolved conflicts); safe to drop.
  final Set<String> rejectedPks;

  /// Reassigned business numbers keyed by row pk (e.g. duplicate invoice
  /// numbers resolved server-side per dbplan §3.1); engine writes back.
  final Map<String, String> correctedFields;

  const SyncPushReceipt({
    required this.serverTime,
    this.rejectedPks = const {},
    this.correctedFields = const {},
  });
}

/// Transport seam between the local sync engine and the cloud.
///
/// Phase 1 ships [FakeSyncTransport] (a second in-memory device) so the whole
/// push/pull/LWW cycle is testable offline. Phase 2 adds the Supabase RPC
/// implementation; nothing else in the engine changes.
abstract class SyncTransport {
  /// Push a batch of local changes. Must be idempotent per row (re-pushing
  /// the same row state is a no-op server-side).
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops);

  /// Pull changes for [tableName] newer than [cursor]. Empty [cursor] means
  /// "everything the company has" (first pull).
  Future<SyncPullPage> pull(String companyId, String tableName, String cursor);

  /// True if the server already holds rows for this company — decides
  /// pull-before-baseline on first link (dbplan §3.5).
  Future<bool> companyHasData(String companyId);
}
