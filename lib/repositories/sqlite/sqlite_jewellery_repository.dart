import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import 'package:apexbooks/database/jewellery_service.dart';
import 'package:apexbooks/models/jewellery_attributes.dart';
import 'package:apexbooks/models/jewellery_piece.dart';
import 'package:apexbooks/models/metal_rate.dart';
import 'package:apexbooks/models/verticals.dart';
import 'package:apexbooks/repositories/jewellery_repository.dart';

class SqliteJewelleryRepository implements JewelleryRepository {
  @override
  Future<void> upsertMetalRate(MetalRate rate) =>
      JewelleryService.upsertMetalRate(rate);

  @override
  Future<void> deleteMetalRate(String id) =>
      JewelleryService.deleteMetalRate(id);

  @override
  Future<List<MetalRate>> getRatesForDate(DateTime date) =>
      JewelleryService.getRatesForDate(date);

  @override
  Future<MetalRate?> getRateForDate({
    required String metal,
    required String purity,
    required DateTime date,
  }) =>
      JewelleryService.getRateForDate(metal: metal, purity: purity, date: date);

  @override
  Future<DateTime?> getLatestRateDate() => JewelleryService.getLatestRateDate();

  @override
  Future<JewelleryAttributes?> getAttributes(String productId) =>
      JewelleryService.getAttributes(productId);

  @override
  Future<Map<String, JewelleryAttributes>> getAllAttributes() =>
      JewelleryService.getAllAttributes();

  @override
  Future<void> upsertPiece(JewelleryPiece piece) =>
      JewelleryService.upsertPiece(piece);

  @override
  Future<void> deletePiece(String id) => JewelleryService.deletePiece(id);

  @override
  Future<JewelleryPiece?> getPiece(String id) => JewelleryService.getPiece(id);

  @override
  Future<List<JewelleryPiece>> getPiecesForProduct(String productId) =>
      JewelleryService.getPiecesForProduct(productId);

  @override
  Future<Map<String, List<JewelleryPiece>>> getPiecesForProductIds(
          List<String> productIds) =>
      JewelleryService.getPiecesForProductIds(productIds);

  @override
  Future<void> syncPiecesForInvoice({
    required String invoiceId,
    required Set<String> pieceIds,
    DatabaseExecutor? txn,
  }) =>
      JewelleryService.syncPiecesForInvoice(
          invoiceId: invoiceId, pieceIds: pieceIds, txn: txn);

  @override
  Future<void> upsertAttributes(JewelleryAttributes attributes) =>
      JewelleryService.upsertAttributes(attributes);

  @override
  Future<void> deleteAttributes(String productId) =>
      JewelleryService.deleteAttributes(productId);

  @override
  Future<void> upsertOldGoldEntry(OldGoldEntry entry) =>
      JewelleryService.upsertOldGoldEntry(entry);

  @override
  Future<void> deleteOldGoldEntry(String id) =>
      JewelleryService.deleteOldGoldEntry(id);

  @override
  Future<List<OldGoldEntry>> getOldGoldForInvoice(String invoiceId) =>
      JewelleryService.getOldGoldForInvoice(invoiceId);

  @override
  Future<List<OldGoldEntry>> replaceOldGoldForInvoice({
    required String invoiceId,
    required List<OldGoldEntry> entries,
    DatabaseExecutor? txn,
  }) =>
      JewelleryService.replaceOldGoldForInvoice(
          invoiceId: invoiceId, entries: entries, txn: txn);

  @override
  Future<void> upsertJobWorkOrder(JobWorkOrder order) =>
      JewelleryService.upsertJobWorkOrder(order);

  @override
  Future<void> deleteJobWorkOrder(String id) =>
      JewelleryService.deleteJobWorkOrder(id);

  @override
  Future<List<JobWorkOrder>> getJobWorkOrders({String? status}) =>
      JewelleryService.getJobWorkOrders(status: status);
}
