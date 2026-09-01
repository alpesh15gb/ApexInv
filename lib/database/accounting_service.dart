import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:apexbooks/models/accounting.dart';
import 'database_helper.dart';

/// Cash/bank, cheque and loan posting service.
///
/// All balance-changing operations are written as immutable signed movements.
/// Corrections insert a linked opposite movement; account balances are never
/// stored or edited directly, so they cannot drift from their registers.
class AccountingService {
  static final _dbHelper = DatabaseHelper();
  static const _uuid = Uuid();

  static Future<List<FinancialAccount>> getAccounts({
    String? type,
    bool activeOnly = true,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>[];
    final args = <Object?>[];
    if (type != null) {
      where.add('type = ?');
      args.add(type);
    }
    if (activeOnly) where.add('active = 1');
    final rows = await db.query('financial_accounts',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args,
        orderBy: "CASE type WHEN 'cash' THEN 0 ELSE 1 END, name");
    return rows.map(FinancialAccount.fromMap).toList();
  }

  static Future<FinancialAccount?> getAccount(String id) async {
    final db = await _dbHelper.database;
    final rows = await db.query('financial_accounts',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : FinancialAccount.fromMap(rows.first);
  }

  static Future<void> saveAccount(FinancialAccount account) async {
    if (account.name.trim().isEmpty) {
      throw ArgumentError('Account name is required');
    }
    if (account.type != 'cash' && account.type != 'bank') {
      throw ArgumentError('Account type must be cash or bank');
    }
    final db = await _dbHelper.database;
    await db.insert('financial_accounts', account.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> setAccountActive(String id, bool active) async {
    if (id == 'cash-default' && !active) {
      throw StateError('The default Cash In Hand account cannot be disabled');
    }
    final db = await _dbHelper.database;
    await db.update('financial_accounts', {'active': active ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<double> getBalance(String accountId,
      {DateTime? through}) async {
    final db = await _dbHelper.database;
    final accountRows = await db.query('financial_accounts',
        columns: ['opening_balance'],
        where: 'id = ?',
        whereArgs: [accountId],
        limit: 1);
    if (accountRows.isEmpty) throw StateError('Account not found');
    final opening =
        (accountRows.first['opening_balance'] as num?)?.toDouble() ?? 0;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS movement
      FROM financial_transactions
      WHERE account_id = ? AND voided_at IS NULL
      ${through == null ? '' : 'AND date <= ?'}
    ''', [accountId, if (through != null) through.toIso8601String()]);
    var legacyOpening = 0.0;
    if (accountId == 'cash-default') {
      final settings = await db.query('settings', columns: ['value'],
          where: 'key = ?', whereArgs: ['opening_capital'], limit: 1);
      legacyOpening = settings.isEmpty
          ? 0
          : double.tryParse(settings.first['value'] as String? ?? '') ?? 0;
    }
    return opening + legacyOpening +
        ((rows.first['movement'] as num?)?.toDouble() ?? 0);
  }

  static Future<Map<String, double>> getBalances(
      Iterable<FinancialAccount> accounts) async {
    final result = <String, double>{};
    for (final account in accounts) {
      result[account.id] = await getBalance(account.id);
    }
    return result;
  }

  static Future<List<FinancialTransaction>> getTransactions(String accountId,
      {int limit = 500}) async {
    final db = await _dbHelper.database;
    final rows = await db.query('financial_transactions',
        where: 'account_id = ?',
        whereArgs: [accountId],
        orderBy: 'date DESC, rowid DESC',
        limit: limit);
    return rows.map(FinancialTransaction.fromMap).toList();
  }

  /// Resolves legacy payment-method values to a real account. A default bank
  /// register is created only when a non-cash method is first used.
  static Future<String> resolveAccountId(
    DatabaseExecutor executor, {
    String? requestedAccountId,
    String? paymentMethod,
    String currencyCode = 'INR',
    String currencySymbol = '₹',
  }) async {
    if (requestedAccountId != null && requestedAccountId.isNotEmpty) {
      final rows = await executor.query('financial_accounts',
          where: 'id = ? AND active = 1',
          whereArgs: [requestedAccountId],
          limit: 1);
      if (rows.isEmpty) throw StateError('Selected account is unavailable');
      if ((rows.first['currency_code'] as String? ?? 'INR') != currencyCode) {
        throw StateError('Payment and account currencies must match');
      }
      return requestedAccountId;
    }

    final cash = paymentMethod == null || paymentMethod == 'Cash';
    final type = cash ? 'cash' : 'bank';
    final rows = await executor.query('financial_accounts',
        columns: ['id'],
        where: 'type = ? AND currency_code = ? AND active = 1',
        whereArgs: [type, currencyCode],
        orderBy: 'rowid ASC',
        limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as String;

    final id = cash ? 'cash-$currencyCode' : 'bank-general-$currencyCode';
    await executor.insert(
        'financial_accounts',
        {
          'id': id,
          'name': cash ? 'Cash In Hand ($currencyCode)' : 'General Bank',
          'type': type,
          'currency_code': currencyCode,
          'currency_symbol': currencySymbol,
          'opening_balance': 0,
          'opening_date': DateTime(2000).toIso8601String(),
          'active': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  static Future<FinancialTransaction> insertMovement(
    DatabaseExecutor executor, {
    String? id,
    required String accountId,
    required String kind,
    required double amount,
    required DateTime date,
    required String sourceType,
    required String sourceId,
    String? transferAccountId,
    String reference = '',
    String notes = '',
    String? reversalOf,
  }) async {
    if (amount.abs() < 0.000001) {
      throw ArgumentError('Movement amount cannot be zero');
    }
    final movement = FinancialTransaction(
      id: id ?? _uuid.v4(),
      accountId: accountId,
      transferAccountId: transferAccountId,
      kind: kind,
      amount: amount,
      date: date,
      sourceType: sourceType,
      sourceId: sourceId,
      reference: reference,
      notes: notes,
      reversalOf: reversalOf,
    );
    await executor.insert('financial_transactions', {
      'id': movement.id,
      'account_id': movement.accountId,
      'transfer_account_id': movement.transferAccountId,
      'kind': movement.kind,
      'amount': movement.amount,
      'date': movement.date.toIso8601String(),
      'source_type': movement.sourceType,
      'source_id': movement.sourceId,
      'reference': movement.reference,
      'notes': movement.notes,
      'reversal_of': movement.reversalOf,
      'voided_at': null,
    });
    return movement;
  }

  static Future<void> transfer({
    required String fromAccountId,
    required String toAccountId,
    required double amount,
    required DateTime date,
    String reference = '',
    String notes = '',
  }) async {
    if (fromAccountId == toAccountId) {
      throw ArgumentError('Transfer accounts must be different');
    }
    if (amount <= 0) throw ArgumentError('Transfer amount must be positive');
    final db = await _dbHelper.database;
    final groupId = _uuid.v4();
    await db.transaction((txn) async {
      final accounts = await txn.query('financial_accounts',
          where: 'id IN (?, ?) AND active = 1',
          whereArgs: [fromAccountId, toAccountId]);
      if (accounts.length != 2) throw StateError('Transfer account not found');
      final currencies =
          accounts.map((r) => r['currency_code'] as String).toSet();
      if (currencies.length != 1) {
        throw StateError('Cross-currency transfers require an FX workflow');
      }
      await insertMovement(txn,
          accountId: fromAccountId,
          transferAccountId: toAccountId,
          kind: 'transfer_out',
          amount: -amount,
          date: date,
          sourceType: 'transfer',
          sourceId: groupId,
          reference: reference,
          notes: notes);
      await insertMovement(txn,
          accountId: toAccountId,
          transferAccountId: fromAccountId,
          kind: 'transfer_in',
          amount: amount,
          date: date,
          sourceType: 'transfer',
          sourceId: groupId,
          reference: reference,
          notes: notes);
    });
  }

  static Future<void> adjustBalance({
    required String accountId,
    required double amount,
    required DateTime date,
    required String reason,
  }) async {
    if (reason.trim().isEmpty) {
      throw ArgumentError('An adjustment reason is required');
    }
    final db = await _dbHelper.database;
    await db.transaction((txn) => insertMovement(txn,
        accountId: accountId,
        kind: 'adjustment',
        amount: amount,
        date: date,
        sourceType: 'adjustment',
        sourceId: _uuid.v4(),
        notes: reason));
  }

  static Future<void> reverseSource({
    required String sourceType,
    required String sourceId,
    String reason = 'Reversal',
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final originals = await txn.query('financial_transactions',
          where:
              'source_type = ? AND source_id = ? AND reversal_of IS NULL AND voided_at IS NULL',
          whereArgs: [sourceType, sourceId]);
      for (final row in originals) {
        final existing = await txn.query('financial_transactions',
            columns: ['id'],
            where: 'reversal_of = ?',
            whereArgs: [row['id']],
            limit: 1);
        if (existing.isNotEmpty) continue;
        await insertMovement(txn,
            accountId: row['account_id'] as String,
            transferAccountId: row['transfer_account_id'] as String?,
            kind: 'reversal',
            amount: -((row['amount'] as num).toDouble()),
            date: DateTime.now(),
            sourceType: sourceType,
            sourceId: sourceId,
            notes: reason,
            reversalOf: row['id'] as String);
      }
    });
  }

  static Future<String> createCheque(
    DatabaseExecutor executor, {
    String? id,
    required String direction,
    required String partyName,
    required double amount,
    required String chequeNumber,
    required DateTime chequeDate,
    required String sourceType,
    required String sourceId,
    String currencyCode = 'INR',
    String currencySymbol = '₹',
    String notes = '',
  }) async {
    if (direction != 'received' && direction != 'issued') {
      throw ArgumentError('Invalid cheque direction');
    }
    if (amount <= 0 || chequeNumber.trim().isEmpty) {
      throw ArgumentError('Cheque number and positive amount are required');
    }
    final chequeId = id ?? _uuid.v4();
    await executor.insert('cheques', {
      'id': chequeId,
      'direction': direction,
      'party_name': partyName,
      'amount': amount,
      'currency_code': currencyCode,
      'currency_symbol': currencySymbol,
      'cheque_number': chequeNumber.trim(),
      'cheque_date': chequeDate.toIso8601String(),
      'status': 'pending',
      'source_type': sourceType,
      'source_id': sourceId,
      'notes': notes,
    });
    return chequeId;
  }

  static Future<List<ChequeRecord>> getCheques({String? status}) async {
    final db = await _dbHelper.database;
    final rows = await db.query('cheques',
        where: status == null ? null : 'status = ?',
        whereArgs: status == null ? null : [status],
        orderBy: 'cheque_date DESC, rowid DESC');
    return rows.map(ChequeRecord.fromMap).toList();
  }

  static Future<String> addManualCheque({
    required String direction,
    required String partyName,
    required double amount,
    required String chequeNumber,
    required DateTime chequeDate,
    String notes = '',
  }) async {
    final db = await _dbHelper.database;
    return db.transaction((txn) => createCheque(txn,
        direction: direction,
        partyName: partyName,
        amount: amount,
        chequeNumber: chequeNumber,
        chequeDate: chequeDate,
        sourceType: 'manual_cheque',
        sourceId: _uuid.v4(),
        notes: notes));
  }

  static const _chequeTransitions = <String, Set<String>>{
    'pending': {'deposited', 'cleared', 'bounced', 'cancelled'},
    'deposited': {'cleared', 'bounced', 'cancelled'},
    'cleared': {'bounced'},
    'bounced': {},
    'cancelled': {},
  };

  static Future<void> transitionCheque({
    required String chequeId,
    required String status,
    String? bankAccountId,
    String notes = '',
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query('cheques',
          where: 'id = ?', whereArgs: [chequeId], limit: 1);
      if (rows.isEmpty) throw StateError('Cheque not found');
      final cheque = ChequeRecord.fromMap(rows.first);
      if (!(_chequeTransitions[cheque.status]?.contains(status) ?? false)) {
        throw StateError('Cannot move cheque from ${cheque.status} to $status');
      }

      String? resolvedBank = bankAccountId ?? cheque.bankAccountId;
      if (status == 'deposited' || status == 'cleared') {
        if (resolvedBank == null || resolvedBank.isEmpty) {
          throw StateError('Select the bank account for this cheque');
        }
        final bankRows = await txn.query('financial_accounts',
            where: 'id = ? AND type = ? AND active = 1',
            whereArgs: [resolvedBank, 'bank'],
            limit: 1);
        if (bankRows.isEmpty) throw StateError('Bank account not found');
      }

      if (status == 'cleared') {
        await insertMovement(txn,
            accountId: resolvedBank!,
            kind: cheque.direction == 'received'
                ? 'cheque_receipt'
                : 'cheque_payment',
            amount: cheque.direction == 'received'
                ? cheque.amount
                : -cheque.amount,
            date: DateTime.now(),
            sourceType: 'cheque',
            sourceId: cheque.id,
            reference: cheque.chequeNumber,
            notes: notes);
      } else if (status == 'bounced' && cheque.status == 'cleared') {
        final clearRows = await txn.query('financial_transactions',
            where:
                'source_type = ? AND source_id = ? AND reversal_of IS NULL',
            whereArgs: ['cheque', cheque.id]);
        for (final movement in clearRows) {
          await insertMovement(txn,
              accountId: movement['account_id'] as String,
              kind: 'cheque_bounce',
              amount: -((movement['amount'] as num).toDouble()),
              date: DateTime.now(),
              sourceType: 'cheque',
              sourceId: cheque.id,
              reference: cheque.chequeNumber,
              notes: notes,
              reversalOf: movement['id'] as String);
        }
      }

      await txn.update(
          'cheques',
          {
            'status': status,
            'bank_account_id': resolvedBank,
            if (status == 'deposited')
              'deposited_at': DateTime.now().toIso8601String(),
            if (status == 'cleared')
              'cleared_at': DateTime.now().toIso8601String(),
            if (notes.trim().isNotEmpty) 'notes': notes.trim(),
          },
          where: 'id = ?',
          whereArgs: [cheque.id]);

      final paymentTable = cheque.sourceType == 'invoice_payment'
          ? 'invoice_payments'
          : cheque.sourceType == 'purchase_bill_payment'
              ? 'purchase_bill_payments'
              : null;
      if (paymentTable != null) {
        await txn.update(
            paymentTable,
            {
              'cheque_status': status,
              if (paymentTable == 'invoice_payments')
                'cheque_cleared': status == 'cleared' ? 1 : 0,
            },
            where: 'id = ?',
            whereArgs: [cheque.sourceId]);
        if (paymentTable == 'purchase_bill_payments') {
          final paymentRows = await txn.query('purchase_bill_payments',
              columns: ['purchase_bill_id'],
              where: 'id = ?',
              whereArgs: [cheque.sourceId],
              limit: 1);
          if (paymentRows.isNotEmpty) {
            final billId = paymentRows.first['purchase_bill_id'] as String;
            await txn.rawUpdate('''
              UPDATE purchase_bills SET amount_paid = COALESCE((
                SELECT SUM(amount_paid) FROM purchase_bill_payments
                WHERE purchase_bill_id = ?
                  AND cheque_status NOT IN ('bounced', 'cancelled')
              ), 0) WHERE id = ?
            ''', [billId, billId]);
          }
        }
      }
    });
  }

  static Future<List<LoanAccount>> getLoans() async {
    final db = await _dbHelper.database;
    final rows = await db.query('loan_accounts',
        orderBy: "CASE status WHEN 'active' THEN 0 ELSE 1 END, start_date DESC");
    return rows.map(LoanAccount.fromMap).toList();
  }

  static Future<List<LoanMovement>> getLoanMovements(String loanId) async {
    final db = await _dbHelper.database;
    final rows = await db.query('loan_movements',
        where: 'loan_id = ?',
        whereArgs: [loanId],
        orderBy: 'date DESC, rowid DESC');
    return rows.map(LoanMovement.fromMap).toList();
  }

  static Future<double> getLoanOutstanding(String loanId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(CASE
        WHEN type = 'drawdown' THEN principal_amount
        WHEN type = 'repayment' THEN -principal_amount
        ELSE principal_amount END), 0) AS outstanding
      FROM loan_movements WHERE loan_id = ? AND voided_at IS NULL
    ''', [loanId]);
    return ((rows.first['outstanding'] as num?)?.toDouble() ?? 0)
        .clamp(0, double.infinity)
        .toDouble();
  }

  static Future<void> createLoan(LoanAccount loan) async {
    if (loan.originalPrincipal <= 0) {
      throw ArgumentError('Loan principal must be positive');
    }
    if (loan.disbursementAccountId == null) {
      throw ArgumentError('A disbursement account is required');
    }
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.insert('loan_accounts', loan.toMap());
      final movementId = _uuid.v4();
      await txn.insert('loan_movements', {
        'id': movementId,
        'loan_id': loan.id,
        'date': loan.startDate.toIso8601String(),
        'type': 'drawdown',
        'principal_amount': loan.originalPrincipal,
        'interest_amount': 0,
        'fee_amount': 0,
        'account_id': loan.disbursementAccountId,
        'reference': 'Opening drawdown',
        'notes': loan.notes,
      });
      await insertMovement(txn,
          accountId: loan.disbursementAccountId!,
          kind: 'loan_drawdown',
          amount: loan.originalPrincipal,
          date: loan.startDate,
          sourceType: 'loan_movement',
          sourceId: movementId,
          reference: loan.name,
          notes: loan.notes);
    });
  }

  static Future<void> recordLoanRepayment({
    required String loanId,
    required String accountId,
    required double principal,
    required double interest,
    required double fees,
    required DateTime date,
    String reference = '',
    String notes = '',
  }) async {
    if (principal < 0 || interest < 0 || fees < 0) {
      throw ArgumentError('Repayment parts cannot be negative');
    }
    final total = principal + interest + fees;
    if (total <= 0) throw ArgumentError('Repayment amount is required');
    final outstanding = await getLoanOutstanding(loanId);
    if (principal > outstanding + 0.005) {
      throw StateError('Principal exceeds the outstanding loan balance');
    }
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final movementId = _uuid.v4();
      await txn.insert('loan_movements', {
        'id': movementId,
        'loan_id': loanId,
        'date': date.toIso8601String(),
        'type': 'repayment',
        'principal_amount': principal,
        'interest_amount': interest,
        'fee_amount': fees,
        'account_id': accountId,
        'reference': reference,
        'notes': notes,
      });
      await insertMovement(txn,
          accountId: accountId,
          kind: 'loan_repayment',
          amount: -total,
          date: date,
          sourceType: 'loan_movement',
          sourceId: movementId,
          reference: reference,
          notes: notes);
      if ((outstanding - principal).abs() <= 0.005) {
        await txn.update('loan_accounts', {'status': 'closed'},
            where: 'id = ?', whereArgs: [loanId]);
      }
    });
  }
}
