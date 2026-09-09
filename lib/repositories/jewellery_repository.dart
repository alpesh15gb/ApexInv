import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/jewellery_piece.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/verticals.dart';

/// Jewellery vertical storage: daily metal rates, per-product attributes,
/// and tagged pieces (retail.md P2).
abstract class JewelleryRepository {
  // ── Metal rates ──────────────────────────────────────────────
  Future<void> upsertMetalRate(MetalRate rate);
  Future<void> deleteMetalRate(String id);

  /// All rates for one day, newest metal/purity order not guaranteed.
  Future<List<MetalRate>> getRatesForDate(DateTime date);

  /// Latest rate on or before [date] for a metal+purity pair, or null when
  /// the shop never entered one (callers then prompt instead of guessing).
  Future<MetalRate?> getRateForDate({
    required String metal,
    required String purity,
    required DateTime date,
  });

  /// Most recent rate day on record, or null when no rates exist yet.
  Future<DateTime?> getLatestRateDate();

  // ── Product attributes ───────────────────────────────────────
  Future<JewelleryAttributes?> getAttributes(String productId);

  /// All stored attributes keyed by product id (label/screen hydration).
  Future<Map<String, JewelleryAttributes>> getAllAttributes();
  Future<void> upsertAttributes(JewelleryAttributes attributes);
  Future<void> deleteAttributes(String productId);

  // ── Tagged pieces (retail.md P2) ─────────────────────────────
  Future<void> upsertPiece(JewelleryPiece piece);
  Future<void> deletePiece(String id);
  Future<JewelleryPiece?> getPiece(String id);

  /// Pieces of one product, tag order.
  Future<List<JewelleryPiece>> getPiecesForProduct(String productId);

  /// Pieces for many products in one query, keyed by product id (list-page
  /// hydration must not N+1).
  Future<Map<String, List<JewelleryPiece>>> getPiecesForProductIds(
      List<String> productIds);

  /// Re-syncs piece statuses after an invoice is saved: every piece
  /// referenced by the invoice's lines becomes `sold` pointing at it, and
  /// pieces this invoice previously sold but no longer references go back
  /// to `in_stock`. Pass [txn] to join the caller's transaction.
  Future<void> syncPiecesForInvoice({
    required String invoiceId,
    required Set<String> pieceIds,
    DatabaseExecutor? txn,
  });

  // ── Old gold exchange (retail.md P3) ─────────────────────────
  Future<void> upsertOldGoldEntry(OldGoldEntry entry);
  Future<void> deleteOldGoldEntry(String id);
  Future<List<OldGoldEntry>> getOldGoldForInvoice(String invoiceId);

  /// Replaces an invoice's old-gold entries atomically (invoice save path).
  Future<List<OldGoldEntry>> replaceOldGoldForInvoice({
    required String invoiceId,
    required List<OldGoldEntry> entries,
    DatabaseExecutor? txn,
  });

  // ── Karigar job work (retail.md P3) ──────────────────────────
  Future<void> upsertJobWorkOrder(JobWorkOrder order);
  Future<void> deleteJobWorkOrder(String id);

  /// All job-work orders, newest issue first; filter by status when given.
  Future<List<JobWorkOrder>> getJobWorkOrders({String? status});
}
