// Piece-level jewellery stock lifecycle (retail.md P2): tagging CRUD and
// the in_stock ⇄ sold moves driven by invoice insert/edit/delete.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/jewellery_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/jewellery_piece.dart';
import 'package:apexbooks/models/product.dart';

void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath,
        version: DatabaseHelper().dbVersion,
        singleInstance: false,
        onCreate: (database, version) =>
            DatabaseHelper().createDbForTest(database, version));
    DatabaseHelper().useDatabaseForTest(db);
  });

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
    await db.close();
  });

  Future<Product> addProduct(String id, double stock) async {
    final p = Product(
      id: id,
      name: 'Necklace $id',
      description: '',
      price: 4580,
      stock: stock,
      hsncode: '7113',
      tax_rate: 3,
    );
    await ProductService.insertProduct(p);
    return (await ProductService.getProductById(id))!;
  }

  InvoiceItem weightLine(Product product, double net, {String? pieceId}) =>
      InvoiceItem(
        product: product,
        quantity: net,
        unitPrice: 4580,
        metalRateId: 'rate-1',
        netWeight: net,
        makingAmount: 500,
        wastageAmount: 100,
        jewelleryPieceId: pieceId,
      );

  Invoice salesInvoice(String id, List<InvoiceItem> items) {
    return Invoice(
      id: id,
      customer: Customer(
          id: 'c1',
          name: 'Buyer',
          email: '',
          phone: '',
          address: '',
          gstin: ''),
      items: items,
      date: DateTime(2026, 9, 9),
      type: 'Invoice',
    );
  }

  test('piece crud round-trips through sqlite', () async {
    final piece = JewelleryPiece.create(
      productId: 'p1',
      tagNo: 'A1',
      huid: 'ABC123',
      purity: '22K',
      grossWeight: 10,
      stoneWeight: 2,
    );
    await JewelleryService.upsertPiece(piece);
    final stored = await JewelleryService.getPiece(piece.id);
    expect(stored, isNotNull);
    expect(stored!.tagNo, 'A1');
    expect(stored.status, 'in_stock');
    expect(stored.netWeight, 8);
    expect(stored.isInStock, isTrue);

    final list = await JewelleryService.getPiecesForProduct('p1');
    expect(list, hasLength(1));

    final batch =
        await JewelleryService.getPiecesForProductIds(['p1', 'p2']);
    expect(batch['p1'], hasLength(1));
    expect(batch.containsKey('p2'), isFalse);

    await JewelleryService.deletePiece(piece.id);
    expect(await JewelleryService.getPiece(piece.id), isNull);
  });

  test('selling a piece via an invoice marks it sold with the invoice id',
      () async {
    final product = await addProduct('p1', 100);
    final piece = JewelleryPiece.create(
        productId: 'p1', tagNo: 'A1', grossWeight: 8, stoneWeight: 0);
    await JewelleryService.upsertPiece(piece);

    await InvoiceService.insertInvoice(
        salesInvoice('inv1', [weightLine(product, 8, pieceId: piece.id)]));

    final sold = (await JewelleryService.getPiece(piece.id))!;
    expect(sold.status, 'sold');
    expect(sold.soldInvoiceId, 'inv1');
    expect(sold.isInStock, isFalse);
  });

  test('editing the invoice off the piece returns it to stock', () async {
    final product = await addProduct('p1', 100);
    final piece = JewelleryPiece.create(
        productId: 'p1', tagNo: 'A1', grossWeight: 8, stoneWeight: 0);
    await JewelleryService.upsertPiece(piece);

    await InvoiceService.insertInvoice(
        salesInvoice('inv1', [weightLine(product, 8, pieceId: piece.id)]));
    expect((await JewelleryService.getPiece(piece.id))!.status, 'sold');

    // Same invoice, line no longer references the piece.
    final edited = salesInvoice('inv1', [weightLine(product, 8)]);
    await InvoiceService.updateInvoice(edited);
    final released = (await JewelleryService.getPiece(piece.id))!;
    expect(released.status, 'in_stock');
    expect(released.soldInvoiceId, isNull);

    // And back again.
    await InvoiceService.updateInvoice(
        salesInvoice('inv1', [weightLine(product, 8, pieceId: piece.id)]));
    expect((await JewelleryService.getPiece(piece.id))!.status, 'sold');
  });

  test('permanent delete releases pieces this invoice sold', () async {
    final product = await addProduct('p1', 100);
    final piece = JewelleryPiece.create(
        productId: 'p1', tagNo: 'A1', grossWeight: 8, stoneWeight: 0);
    await JewelleryService.upsertPiece(piece);

    await InvoiceService.insertInvoice(
        salesInvoice('inv1', [weightLine(product, 8, pieceId: piece.id)]));
    await InvoiceService.permanentDeleteInvoice('inv1');

    final released = (await JewelleryService.getPiece(piece.id))!;
    expect(released.status, 'in_stock');
    expect(released.soldInvoiceId, isNull);
  });
}
