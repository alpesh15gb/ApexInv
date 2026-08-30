import 'package:apexbooks/models/payment_term.dart';
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

class PaymentTermService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertPaymentTerm(PaymentTerm term) async {
    final db = await dbHelper.database;
    await db.insert('payment_terms', term.toMap());
  }

  static Future<void> updatePaymentTerm(PaymentTerm term) async {
    final db = await dbHelper.database;
    final updateMap = term.toMap()..remove('id');
    await db.update('payment_terms', updateMap, where: 'id = ?', whereArgs: [term.id]);
  }

  static Future<PaymentTerm?> getPaymentTermById(String id) async {
    final db = await dbHelper.database;
    final maps = await db.query('payment_terms', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) return PaymentTerm.fromMap(maps.first);
    return null;
  }

  static Future<List<PaymentTerm>> getAllPaymentTerms() async {
    final db = await dbHelper.database;
    final maps = await db.query('payment_terms', orderBy: 'days ASC');
    return maps.map((m) => PaymentTerm.fromMap(m)).toList();
  }

  static Future<void> deletePaymentTerm(String id) async {
    final db = await dbHelper.database;
    await db.delete('payment_terms', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> insertDefaultTerms() async {
    final db = await dbHelper.database;
    final defaults = [
      PaymentTerm(id: 'term-0', name: 'Due on Receipt', days: 0, isDefault: true),
      PaymentTerm(id: 'term-15', name: 'Net 15', days: 15),
      PaymentTerm(id: 'term-30', name: 'Net 30', days: 30),
      PaymentTerm(id: 'term-45', name: 'Net 45', days: 45),
      PaymentTerm(id: 'term-60', name: 'Net 60', days: 60),
    ];
    for (final term in defaults) {
      await db.insert('payment_terms', term.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}
