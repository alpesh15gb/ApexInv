import 'package:apexbooks/models/expense.dart';
import 'package:apexbooks/models/expense_category.dart';
import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';
import 'accounting_service.dart';

class ExpenseService {
  static final dbHelper = DatabaseHelper();

  // ── Categories ──────────────────────────────

  static Future<void> insertCategory(ExpenseCategory category) async {
    final db = await dbHelper.database;
    await db.insert('expense_categories', category.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<List<ExpenseCategory>> getAllCategories() async {
    final db = await dbHelper.database;
    final maps = await db.query('expense_categories', orderBy: 'name ASC');
    if (maps.isEmpty) {
      // Seed defaults on first access
      for (final cat in ExpenseCategory.defaults) {
        await insertCategory(cat);
      }
      final seeded = await db.query('expense_categories', orderBy: 'name ASC');
      return seeded.map((m) => ExpenseCategory.fromMap(m)).toList();
    }
    return maps.map((m) => ExpenseCategory.fromMap(m)).toList();
  }

  static Future<void> deleteCategory(String id) async {
    final db = await dbHelper.database;
    await db.delete('expense_categories', where: 'id = ?', whereArgs: [id]);
  }

  // ── Expenses ────────────────────────────────

  static Future<void> insertExpense(Expense expense) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final currency = await _currencyForAccount(txn, expense.accountId);
      final accountId = await AccountingService.resolveAccountId(txn,
          requestedAccountId: expense.accountId,
          paymentMethod: expense.paymentMethod,
          currencyCode: currency.$1,
          currencySymbol: currency.$2);
      await txn.insert('expenses', expense.toMap()..['account_id'] = accountId);
      await AccountingService.insertMovement(txn,
          accountId: accountId,
          kind: 'expense',
          amount: -expense.amount,
          date: expense.date,
          sourceType: 'expense',
          sourceId: expense.id,
          reference: expense.description,
          notes: expense.notes ?? '');
    });
  }

  static Future<void> updateExpense(Expense expense) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await _reverseInTransaction(txn, expense.id, 'Expense edited');
      final currency = await _currencyForAccount(txn, expense.accountId);
      final accountId = await AccountingService.resolveAccountId(txn,
          requestedAccountId: expense.accountId,
          paymentMethod: expense.paymentMethod,
          currencyCode: currency.$1,
          currencySymbol: currency.$2);
      final updateMap = expense.toMap()
        ..remove('category_name')
        ..['account_id'] = accountId;
      await txn.update('expenses', updateMap,
          where: 'id = ?', whereArgs: [expense.id]);
      await AccountingService.insertMovement(txn,
          accountId: accountId,
          kind: 'expense',
          amount: -expense.amount,
          date: expense.date,
          sourceType: 'expense',
          sourceId: expense.id,
          reference: expense.description,
          notes: expense.notes ?? '');
    });
  }

  static Future<(String, String)> _currencyForAccount(
      DatabaseExecutor txn, String? accountId) async {
    if (accountId == null || accountId.isEmpty) return ('INR', '₹');
    final rows = await txn.query('financial_accounts',
        columns: ['currency_code', 'currency_symbol'],
        where: 'id = ?', whereArgs: [accountId], limit: 1);
    if (rows.isEmpty) throw StateError('Selected account is unavailable');
    return (rows.first['currency_code'] as String? ?? 'INR',
        rows.first['currency_symbol'] as String? ?? '₹');
  }

  static Future<Expense?> getExpenseById(String id) async {
    final db = await dbHelper.database;
    final maps = await db.query('expenses', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return _hydrate(maps.first);
  }

  static Future<List<Expense>> getAllExpenses() async {
    final db = await dbHelper.database;
    final maps = await db.rawQuery('''
      SELECT e.*, c.name as category_name
      FROM expenses e
      LEFT JOIN expense_categories c ON e.category_id = c.id
      ORDER BY e.date DESC
    ''');
    return maps.map((m) => Expense.fromMap(m)).toList();
  }

  static Future<List<Expense>> getExpensesPaginated({
    required int offset,
    required int limit,
    String query = '',
    String? categoryId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await dbHelper.database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (query.isNotEmpty) {
      conditions.add('LOWER(e.description) LIKE ?');
      args.add('%${query.toLowerCase()}%');
    }
    if (categoryId != null && categoryId.isNotEmpty) {
      conditions.add('e.category_id = ?');
      args.add(categoryId);
    }
    if (fromDate != null) {
      conditions.add('e.date >= ?');
      args.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      conditions.add('e.date <= ?');
      args.add(toDate.toIso8601String());
    }

    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final maps = await db.rawQuery('''
      SELECT e.*, c.name as category_name
      FROM expenses e
      LEFT JOIN expense_categories c ON e.category_id = c.id
      ${where != null ? 'WHERE $where' : ''}
      ORDER BY e.date DESC
      LIMIT ? OFFSET ?
    ''', [...args, limit, offset]);

    return maps.map((m) => Expense.fromMap(m)).toList();
  }

  static Future<int> getExpenseCount(
      {String query = '', String? categoryId}) async {
    final db = await dbHelper.database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (query.isNotEmpty) {
      conditions.add('LOWER(description) LIKE ?');
      args.add('%${query.toLowerCase()}%');
    }
    if (categoryId != null && categoryId.isNotEmpty) {
      conditions.add('category_id = ?');
      args.add(categoryId);
    }

    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM expenses ${where != null ? 'WHERE $where' : ''}',
      args,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  static Future<void> deleteExpense(String id) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await _reverseInTransaction(txn, id, 'Expense deleted');
      await txn.delete('expenses', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> _reverseInTransaction(
      DatabaseExecutor txn, String expenseId, String reason) async {
    final rows = await txn.query('financial_transactions',
        where:
            "source_type = 'expense' AND source_id = ? AND reversal_of IS NULL AND voided_at IS NULL",
        whereArgs: [expenseId]);
    for (final row in rows) {
      final already = await txn.query('financial_transactions',
          columns: ['id'], where: 'reversal_of = ?',
          whereArgs: [row['id']], limit: 1);
      if (already.isNotEmpty) continue;
      await AccountingService.insertMovement(txn,
          accountId: row['account_id'] as String,
          kind: 'reversal',
          amount: -((row['amount'] as num).toDouble()),
          date: DateTime.now(),
          sourceType: 'expense',
          sourceId: expenseId,
          notes: reason,
          reversalOf: row['id'] as String);
    }
  }

  static Future<double> getTotalExpenses(
      {DateTime? fromDate, DateTime? toDate}) async {
    final db = await dbHelper.database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (fromDate != null) {
      conditions.add('date >= ?');
      args.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      conditions.add('date <= ?');
      args.add(toDate.toIso8601String());
    }

    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) FROM expenses ${where != null ? 'WHERE $where' : ''}',
      args,
    );
    return (Sqflite.firstIntValue(result) ?? 0).toDouble();
  }

  static Future<List<Map<String, dynamic>>> getExpensesByCategory({
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final db = await dbHelper.database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (fromDate != null) {
      conditions.add('e.date >= ?');
      args.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      conditions.add('e.date <= ?');
      args.add(toDate.toIso8601String());
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    return await db.rawQuery('''
      SELECT c.name as category_name, SUM(e.amount) as total
      FROM expenses e
      LEFT JOIN expense_categories c ON e.category_id = c.id
      $where
      GROUP BY e.category_id
      ORDER BY total DESC
    ''', args);
  }

  static Future<List<Map<String, dynamic>>> getMonthlyExpenses({
    int months = 12,
  }) async {
    final db = await dbHelper.database;
    final fromDate = DateTime.now().subtract(Duration(days: months * 30));
    return await db.rawQuery('''
      SELECT strftime('%Y-%m', date) as month, SUM(amount) as total
      FROM expenses
      WHERE date >= ?
      GROUP BY month
      ORDER BY month ASC
    ''', [fromDate.toIso8601String()]);
  }

  static Expense _hydrate(Map<String, dynamic> map) {
    return Expense.fromMap(map);
  }
}
