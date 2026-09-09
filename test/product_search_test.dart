import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/models/product.dart';

/// Regression tests for typed product search: every search query must bind
/// one argument per SQL placeholder, otherwise the filter throws and the
/// type-ahead dropdown keeps showing the unfiltered page.
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

  Future<void> addProduct(String id, String name,
      {String type = 'product', String barcode = ''}) async {
    await ProductService.insertProduct(Product(
      id: id,
      name: name,
      description: '',
      price: 100,
      stock: 10,
      hsncode: '',
      tax_rate: 18,
      type: type,
      barcode: barcode,
    ));
  }

  test('searchProducts filters by the typed query', () async {
    await addProduct('p1', 'DLink Router');
    await addProduct('p2', 'Cisco Switch');
    await addProduct('p3', 'DLink Cable', type: 'service');

    final results = await ProductService.searchProducts('dlink');
    expect(results.map((p) => p.id).toSet(), {'p1', 'p3'});

    final typed = await ProductService.searchProducts('dlink', type: 'product');
    expect(typed.map((p) => p.id).toList(), ['p1']);
  });

  test('getProductsPaginated filters by the typed query', () async {
    await addProduct('p1', 'DLink Router', barcode: 'DLINK-001');
    await addProduct('p2', 'Cisco Switch');

    final byName = await ProductService.getProductsPaginated(
        offset: 0, limit: 30, query: 'dlink');
    expect(byName.map((p) => p.id).toList(), ['p1']);

    final byBarcode = await ProductService.getProductsPaginated(
        offset: 0, limit: 30, query: 'dlink-001');
    expect(byBarcode.map((p) => p.id).toList(), ['p1']);

    final typed = await ProductService.getProductsPaginated(
        offset: 0, limit: 30, query: 'dlink', type: 'service');
    expect(typed, isEmpty);
  });

  test('getProductCount honors the typed query', () async {
    await addProduct('p1', 'DLink Router');
    await addProduct('p2', 'Cisco Switch');

    expect(await ProductService.getProductCount('dlink'), 1);
    expect(await ProductService.getProductCount('dlink', 'product'), 1);
    expect(await ProductService.getProductCount('dlink', 'service'), 0);
    expect(await ProductService.getProductCount(''), 2);
  });
}
