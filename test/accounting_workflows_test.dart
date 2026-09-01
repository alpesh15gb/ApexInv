import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/models/accounting.dart';

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

  test('fresh accounting schema seeds one default cash account', () async {
    final accounts = await AccountingService.getAccounts(type: 'cash');
    expect(accounts, hasLength(1));
    expect(accounts.single.id, 'cash-default');
    expect(await AccountingService.getBalance('cash-default'), 0);
  });

  test('transfer is balanced and updates both derived balances', () async {
    await AccountingService.saveAccount(FinancialAccount(
      id: 'bank-1',
      name: 'Current Account',
      type: 'bank',
      openingBalance: 1000,
      openingDate: DateTime(2026, 1, 1),
    ));

    await AccountingService.transfer(
      fromAccountId: 'bank-1',
      toAccountId: 'cash-default',
      amount: 250,
      date: DateTime(2026, 1, 2),
    );

    expect(await AccountingService.getBalance('bank-1'), 750);
    expect(await AccountingService.getBalance('cash-default'), 250);
    final movements = await db.query('financial_transactions',
        where: "source_type = 'transfer'");
    expect(movements, hasLength(2));
    expect(movements.fold<double>(0,
        (sum, row) => sum + (row['amount'] as num).toDouble()), 0);
  });

  test('loan repayment separates principal and cash outflow', () async {
    await AccountingService.createLoan(LoanAccount(
      id: 'loan-1',
      name: 'Working capital loan',
      lender: 'Example Bank',
      originalPrincipal: 10000,
      startDate: DateTime(2026, 1, 1),
      disbursementAccountId: 'cash-default',
    ));
    expect(await AccountingService.getLoanOutstanding('loan-1'), 10000);
    expect(await AccountingService.getBalance('cash-default'), 10000);

    await AccountingService.recordLoanRepayment(
      loanId: 'loan-1',
      accountId: 'cash-default',
      principal: 2000,
      interest: 100,
      fees: 25,
      date: DateTime(2026, 2, 1),
    );
    expect(await AccountingService.getLoanOutstanding('loan-1'), 8000);
    expect(await AccountingService.getBalance('cash-default'), 7875);
  });

  test('received cheque only reaches bank when cleared', () async {
    await AccountingService.saveAccount(FinancialAccount(
      id: 'bank-1',
      name: 'Bank',
      type: 'bank',
      openingDate: DateTime(2026, 1, 1),
    ));
    final chequeId = await AccountingService.addManualCheque(
      direction: 'received',
      partyName: 'Customer',
      amount: 500,
      chequeNumber: '1234',
      chequeDate: DateTime(2026, 1, 5),
    );
    expect(await AccountingService.getBalance('bank-1'), 0);

    await AccountingService.transitionCheque(
      chequeId: chequeId,
      status: 'cleared',
      bankAccountId: 'bank-1',
    );
    expect(await AccountingService.getBalance('bank-1'), 500);
  });
}
