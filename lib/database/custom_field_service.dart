import 'dart:convert';
import 'package:apexbooks/models/custom_field.dart';
import 'package:uuid/uuid.dart';
import 'database_helper.dart';

class CustomFieldService {
  static final dbHelper = DatabaseHelper();

  static Future<void> insertCustomField(CustomField field) async {
    final db = await dbHelper.database;
    await db.insert('custom_fields', field.toMap());
  }

  static Future<void> updateCustomField(CustomField field) async {
    final db = await dbHelper.database;
    final updateMap = field.toMap()..remove('id');
    await db.update('custom_fields', updateMap,
        where: 'id = ?', whereArgs: [field.id]);
  }

  static Future<CustomField?> getCustomFieldById(String id) async {
    final db = await dbHelper.database;
    final maps =
        await db.query('custom_fields', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CustomField.fromMap(maps.first);
  }

  static Future<List<CustomField>> getAllCustomFields() async {
    final db = await dbHelper.database;
    final maps = await db.query('custom_fields', orderBy: 'rowid ASC');
    return maps.map((m) => CustomField.fromMap(m)).toList();
  }

  static Future<void> deleteCustomField(String id) async {
    final db = await dbHelper.database;
    await db.delete('custom_fields', where: 'id = ?', whereArgs: [id]);
  }

  /// UUID mint (was MAX+1 'cf-N'): cross-device creation cannot collide
  /// on the sync wire. Legacy 'cf-N' ids remain readable.
  static Future<String> generateNextId() async {
    return const Uuid().v4();
  }

  // ── Invoice custom field values (stored as JSON in invoice row) ───

  /// Parse custom field values stored as a JSON string in the invoice's
  /// `custom_fields` column.
  static List<CustomFieldValue> parseInvoiceCustomFields(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => CustomFieldValue.fromMap(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Serialize a list of custom field values to a JSON string for storage.
  static String serializeInvoiceCustomFields(List<CustomFieldValue> values) {
    return jsonEncode(values.map((v) => v.toMap()).toList());
  }
}
