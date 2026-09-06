import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/accounting_service.dart';
import 'package:apexbooks/database/audit_log_service.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/database/expense_service.dart';
import 'package:apexbooks/database/invoice_service.dart';
import 'package:apexbooks/database/payment_service.dart';
import 'package:apexbooks/database/period_lock_service.dart';
import 'package:apexbooks/database/product_service.dart';
import 'package:apexbooks/database/purchase_bill_service.dart';
import 'package:apexbooks/database/purchase_order_service.dart';
import 'package:apexbooks/database/settings_service.dart';
import 'package:apexbooks/models/accounting.dart';
import 'package:apexbooks/models/customer.dart';
import 'package:apexbooks/models/expense.dart';
import 'package:apexbooks/models/invoice.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/models/product.dart';
import 'package:apexbooks/models/purchase_bill.dart';
import 'package:apexbooks/models/purchase_order.dart';
import 'package:apexbooks/screens/settings/financial_period_lock_section.dart';

/// Financial period locking: closed/filed periods cannot be rewritten.
///
/// Default (no lock date) changes zero behavior; once `locked_before_date`
/// is set, every service-layer write dated on or before it throws.
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
    // Start unlocked without audit noise (the audited setter is covered by
    // its own test below).
    await SettingsService.deleteSetting(SettingKey.lockedBeforeDate);
  });

  tearDown(() async {
    DatabaseHelper().clearDatabaseForTest();
    await db.close();
  });

  Future<void> lockTo(DateTime date, {String? username}) =>
      PeriodLockService.setLockedBeforeDate(date, username: username);

  DateTime lockDay() => DateTime(2026, 3, 31);

  Future<Product> addProduct(String id, {double stock = 100}) async {
    await ProductService.insertProduct(Product(
      id: id,
      name: 'Widget $id',
      description: '',
      price: 100,
      stock: stock,
      hsncode: '',
      tax_rate: 0,
    ));
    return (await ProductService.getProductById(id))!;
  }

  Customer buyer() => Customer(
      id: 'c-lock',
      name: 'Lock Buyer',
      email: '',
      phone: '',
      address: '',
      gstin: '');

  Invoice salesDoc(String id, Product product, DateTime date,
      {String type = 'Invoice', double qty = 1}) {
    return Invoice(
      id: id,
      customer: buyer(),
      items: [InvoiceItem(product: product, quantity: qty)],
      date: date,
      type: type,
    );
  }

  PurchaseBill bill(String id, DateTime date,
      {double total = 1000, List<PurchaseBillItem>? items}) {
    return PurchaseBill(
      id: id,
      billNumber: 'B-$id',
      supplierName: 'Acme',
      date: date,
      totalAmount: total,
      items: items ?? const [],
    );
  }

  PurchaseOrder po(String id, DateTime date, {String status = 'draft'}) {
    return PurchaseOrder(
      id: id,
      orderNumber: 'PO-$id',
      vendorName: 'Vendor',
      items: [
        PurchaseOrderItem(
          id: 'poi-$id',
          productId: 'p-po',
          productName: 'Widget',
          quantity: 2,
          pricePerUnit: 100,
        ),
      ],
      date: date,
      status: status,
      totalAmount: 200,
    );
  }

  Expense expense(String id, DateTime date) => Expense(
        id: id,
        description: 'Lock expense $id',
        amount: 50,
        date: date,
        categoryId: 'cat-rent',
      );

  group('lock state', () {
    test('default is unlocked (null), zero behavior change', () async {
      expect(await PeriodLockService.getLockedBeforeDate(), isNull);
      final product = await addProduct('p-default');
      // Even ancient dates save fine while unlocked.
      await InvoiceService.insertInvoice(
          salesDoc('inv-default', product, DateTime(2020, 5, 5)));
      expect(await InvoiceService.getInvoiceById('inv-default'), isNotNull);
    });

    test('boundary: locked on the cutoff day, open the day after', () {
      final lock = lockDay();
      expect(
          PeriodLockService.isDateLocked(DateTime(2026, 3, 30), lock), isTrue);
      expect(
          PeriodLockService.isDateLocked(DateTime(2026, 3, 31, 23, 59), lock),
          isTrue);
      expect(
          PeriodLockService.isDateLocked(DateTime(2026, 4, 1), lock), isFalse);
      expect(
          PeriodLockService.isDateLocked(DateTime(2026, 1, 1), null), isFalse);
    });

    test('backdated inserts into a locked period are refused', () async {
      await lockTo(lockDay());
      final product = await addProduct('p-back');
      for (final type in [
        'Invoice',
        'Quotation',
        'Credit Note',
        'Debit Note'
      ]) {
        await expectLater(
            () => InvoiceService.insertInvoice(salesDoc(
                'inv-back-$type', product, DateTime(2026, 2, 1), type: type)),
            throwsA(isA<StateError>()
                .having((e) => e.message, 'message', contains('locked'))),
            reason: type);
      }
      await expectLater(
          () => PurchaseBillService.insertBill(
              bill('bill-back', DateTime(2026, 2, 1))),
          throwsA(isA<StateError>()));
      await expectLater(
          () => PurchaseOrderService.insertPurchaseOrder(
              po('po-back', DateTime(2026, 2, 1)),
              po('po-back', DateTime(2026, 2, 1)).items),
          throwsA(isA<StateError>()));
      await expectLater(
          () => ExpenseService.insertExpense(
              expense('ex-back', DateTime(2026, 2, 1))),
          throwsA(isA<StateError>()));
      // Nothing persisted.
      expect(await InvoiceService.getInvoiceById('inv-back-Invoice'), isNull);
      expect(await PurchaseBillService.getBill('bill-back'), isNull);
      expect(
          await PurchaseOrderService.getPurchaseOrderById('po-back'), isNull);
      expect(await ExpenseService.getExpenseById('ex-back'), isNull);
    });
  });

  group('locked invoice edits are refused', () {
    test('update, trash, restore and permanent delete throw', () async {
      final product = await addProduct('p-inv');
      await InvoiceService.insertInvoice(
          salesDoc('inv-lock', product, DateTime(2026, 1, 10)));
      await lockTo(lockDay());

      await expectLater(
          () => InvoiceService.updateInvoice(
              salesDoc('inv-lock', product, DateTime(2026, 1, 10))),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('locked'))));
      await expectLater(() => InvoiceService.softDeleteInvoice('inv-lock'),
          throwsA(isA<StateError>()));
      await expectLater(() => InvoiceService.permanentDeleteInvoice('inv-lock'),
          throwsA(isA<StateError>()));
      // Document untouched by the refused writes.
      expect(await InvoiceService.getInvoiceById('inv-lock'), isNotNull);
      expect(await InvoiceService.getDeletedInvoices(), isEmpty);
    });

    test('restoring a trashed locked-period invoice is refused', () async {
      final product = await addProduct('p-restore');
      await InvoiceService.insertInvoice(
          salesDoc('inv-restore', product, DateTime(2026, 1, 10)));
      await InvoiceService.softDeleteInvoice('inv-restore');
      await lockTo(lockDay());
      await expectLater(() => InvoiceService.restoreInvoice('inv-restore'),
          throwsA(isA<StateError>()));
      expect(await InvoiceService.getInvoiceById('inv-restore'), isNull);
    });
  });

  group('locked payments are refused', () {
    test('sales receipt add with a locked date throws', () async {
      final product = await addProduct('p-pay');
      await InvoiceService.insertInvoice(
          salesDoc('inv-pay', product, DateTime(2026, 4, 10)));
      await lockTo(lockDay());
      final stored = (await InvoiceService.getInvoiceById('inv-pay'))!;
      await expectLater(
          () => PaymentService.addPayment(
              invoice: stored,
              amountPaid: 50,
              datePaid: DateTime(2026, 2, 1),
              paymentMethod: 'Cash'),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('locked'))));
      expect(await PaymentService.getTotalPaidForInvoice('inv-pay'), 0);
    });

    test('deleting a locked-period receipt is refused', () async {
      final product = await addProduct('p-paydel');
      await InvoiceService.insertInvoice(
          salesDoc('inv-paydel', product, DateTime(2026, 2, 1)));
      final stored = (await InvoiceService.getInvoiceById('inv-paydel'))!;
      final payment = await PaymentService.addPayment(
          invoice: stored,
          amountPaid: 50,
          datePaid: DateTime(2026, 2, 5),
          paymentMethod: 'Cash');
      await lockTo(lockDay());
      await expectLater(() => PaymentService.deletePayment(payment.id),
          throwsA(isA<StateError>()));
      expect(await PaymentService.getTotalPaidForInvoice('inv-paydel'), 50);
    });

    test('purchase payment add and delete in a locked period throw', () async {
      await PurchaseBillService.insertBill(
          bill('bill-pay', DateTime(2026, 4, 10)));
      await lockTo(lockDay());
      await expectLater(
          () => PurchaseBillService.recordPayment('bill-pay', 100,
              datePaid: DateTime(2026, 2, 1), paymentMethod: 'Cash'),
          throwsA(isA<StateError>()));

      // Legacy locked-dated payment: created before the lock, then locked.
      await SettingsService.deleteSetting(SettingKey.lockedBeforeDate);
      final paid = await PurchaseBillService.recordPayment('bill-pay', 100,
          datePaid: DateTime(2026, 2, 2), paymentMethod: 'Cash');
      await lockTo(lockDay());
      await expectLater(() => PurchaseBillService.deletePayment(paid),
          throwsA(isA<StateError>()));
      expect((await PurchaseBillService.getBill('bill-pay'))!.amountPaid, 100);
    });
  });

  group('locked purchase documents are refused', () {
    test('bill update and delete throw', () async {
      await PurchaseBillService.insertBill(
          bill('bill-lock', DateTime(2026, 1, 5)));
      await lockTo(lockDay());
      await expectLater(
          () => PurchaseBillService.updateBill(
              bill('bill-lock', DateTime(2026, 1, 5), total: 2000)),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('locked'))));
      await expectLater(() => PurchaseBillService.softDeleteBill('bill-lock'),
          throwsA(isA<StateError>()));
      expect(
          (await PurchaseBillService.getBill('bill-lock'))!.totalAmount, 1000);
    });

    test('order edit, receive, cancel and delete throw', () async {
      await PurchaseOrderService.insertPurchaseOrder(
          po('po-lock', DateTime(2026, 1, 5)),
          po('po-lock', DateTime(2026, 1, 5)).items);
      await lockTo(lockDay());
      await expectLater(
          () => PurchaseOrderService.updatePurchaseOrder(
              po('po-lock', DateTime(2026, 1, 5))),
          throwsA(isA<StateError>()));
      await expectLater(() => PurchaseOrderService.markAsReceived('po-lock'),
          throwsA(isA<StateError>()));
      await expectLater(
          () => PurchaseOrderService.updateStatus('po-lock', 'cancelled'),
          throwsA(isA<StateError>()));
      await expectLater(
          () => PurchaseOrderService.cancelPurchaseOrder('po-lock'),
          throwsA(isA<StateError>()));
      await expectLater(
          () => PurchaseOrderService.deletePurchaseOrder('po-lock'),
          throwsA(isA<StateError>()));
      expect(
          (await PurchaseOrderService.getPurchaseOrderById('po-lock'))!.status,
          'draft');
    });
  });

  group('locked expenses and ledger writes are refused', () {
    test('expense update and delete throw', () async {
      await ExpenseService.insertExpense(
          expense('ex-lock', DateTime(2026, 1, 5)));
      await lockTo(lockDay());
      await expectLater(
          () => ExpenseService.updateExpense(
              expense('ex-lock', DateTime(2026, 1, 5))
                  .copyWith(description: 'edited')),
          throwsA(isA<StateError>()));
      await expectLater(() => ExpenseService.deleteExpense('ex-lock'),
          throwsA(isA<StateError>()));
      expect((await ExpenseService.getExpenseById('ex-lock'))!.description,
          'Lock expense ex-lock');
    });

    test('transfer, adjustment, loan and cheque writes throw', () async {
      await AccountingService.saveAccount(FinancialAccount(
        id: 'bank-lock',
        name: 'Bank',
        type: 'bank',
        openingDate: DateTime(2026, 1, 1),
      ));
      await lockTo(lockDay());
      final locked = DateTime(2026, 2, 1);
      await expectLater(
          () => AccountingService.transfer(
              fromAccountId: 'bank-lock',
              toAccountId: 'cash-default',
              amount: 10,
              date: locked),
          throwsA(isA<StateError>()));
      await expectLater(
          () => AccountingService.adjustBalance(
              accountId: 'cash-default',
              amount: 10,
              date: locked,
              reason: 'test'),
          throwsA(isA<StateError>()));
      await expectLater(
          () => AccountingService.createLoan(LoanAccount(
                id: 'loan-lock',
                name: 'Loan',
                lender: 'Bank',
                originalPrincipal: 1000,
                startDate: locked,
                disbursementAccountId: 'cash-default',
              )),
          throwsA(isA<StateError>()));
      await expectLater(
          () => AccountingService.recordLoanRepayment(
              loanId: 'loan-lock',
              accountId: 'cash-default',
              principal: 10,
              interest: 0,
              fees: 0,
              date: locked),
          throwsA(isA<StateError>()));
      await expectLater(
          () => AccountingService.addManualCheque(
              direction: 'received',
              partyName: 'P',
              amount: 100,
              chequeNumber: 'L1',
              chequeDate: locked),
          throwsA(isA<StateError>()));
    });

    test('cheque transitions for locked-period cheques throw', () async {
      final chequeId = await AccountingService.addManualCheque(
          direction: 'received',
          partyName: 'P',
          amount: 100,
          chequeNumber: 'L2',
          chequeDate: DateTime(2026, 2, 1));
      await lockTo(lockDay());
      await expectLater(
          () => AccountingService.transitionCheque(
              chequeId: chequeId, status: 'cancelled'),
          throwsA(isA<StateError>()));
      expect(
          (await AccountingService.getCheques())
              .firstWhere((c) => c.id == chequeId)
              .status,
          'pending');
    });
  });

  group('unlocked dates keep working with a lock set', () {
    test('full write lifecycle after the cutoff succeeds', () async {
      await lockTo(lockDay());
      final after = DateTime(2026, 4, 10);
      final product = await addProduct('p-open');

      await InvoiceService.insertInvoice(salesDoc('inv-open', product, after));
      await InvoiceService.updateInvoice(salesDoc('inv-open', product, after));
      final stored = (await InvoiceService.getInvoiceById('inv-open'))!;
      final payment = await PaymentService.addPayment(
          invoice: stored,
          amountPaid: 50,
          datePaid: DateTime(2026, 4, 11),
          paymentMethod: 'Cash');
      expect(await PaymentService.getTotalPaidForInvoice('inv-open'), 50);
      await PaymentService.deletePayment(payment.id);
      expect(await PaymentService.getTotalPaidForInvoice('inv-open'), 0);
      await InvoiceService.softDeleteInvoice('inv-open');
      expect(await InvoiceService.getInvoiceById('inv-open'), isNull);
      await InvoiceService.restoreInvoice('inv-open');
      expect(await InvoiceService.getInvoiceById('inv-open'), isNotNull);
      await InvoiceService.permanentDeleteInvoice('inv-open');
      expect(await InvoiceService.getInvoiceById('inv-open'), isNull);

      await PurchaseBillService.insertBill(bill('bill-open', after));
      await PurchaseBillService.updateBill(bill('bill-open', after));
      final billPayment = await PurchaseBillService.recordPayment(
          'bill-open', 100,
          datePaid: DateTime(2026, 4, 12), paymentMethod: 'Cash');
      await PurchaseBillService.deletePayment(billPayment);
      await PurchaseBillService.softDeleteBill('bill-open');
      expect(await PurchaseBillService.getBill('bill-open'), isNull);

      final order = po('po-open', after);
      await PurchaseOrderService.insertPurchaseOrder(order, order.items);
      await PurchaseOrderService.updatePurchaseOrder(order);
      expect(await PurchaseOrderService.markAsReceived('po-open'), isTrue);
      await PurchaseOrderService.deletePurchaseOrder('po-open');
      expect(
          await PurchaseOrderService.getPurchaseOrderById('po-open'), isNull);

      await ExpenseService.insertExpense(expense('ex-open', after));
      await ExpenseService.updateExpense(
          expense('ex-open', after).copyWith(description: 'edited'));
      await ExpenseService.deleteExpense('ex-open');
      expect(await ExpenseService.getExpenseById('ex-open'), isNull);

      await AccountingService.saveAccount(FinancialAccount(
        id: 'bank-open',
        name: 'Bank',
        type: 'bank',
        openingDate: DateTime(2026, 1, 1),
      ));
      await AccountingService.transfer(
          fromAccountId: 'bank-open',
          toAccountId: 'cash-default',
          amount: 10,
          date: after);
      await AccountingService.adjustBalance(
          accountId: 'cash-default', amount: 5, date: after, reason: 'test');
      await AccountingService.createLoan(LoanAccount(
        id: 'loan-open',
        name: 'Loan',
        lender: 'Bank',
        originalPrincipal: 1000,
        startDate: after,
        disbursementAccountId: 'cash-default',
      ));
      await AccountingService.recordLoanRepayment(
          loanId: 'loan-open',
          accountId: 'cash-default',
          principal: 100,
          interest: 0,
          fees: 0,
          date: DateTime(2026, 4, 15));
      final chequeId = await AccountingService.addManualCheque(
          direction: 'received',
          partyName: 'P',
          amount: 100,
          chequeNumber: 'O1',
          chequeDate: after);
      await AccountingService.transitionCheque(
          chequeId: chequeId, status: 'cancelled');
      expect(
          (await AccountingService.getCheques())
              .firstWhere((c) => c.id == chequeId)
              .status,
          'cancelled');
    });

    test('read-only access to locked documents is unaffected', () async {
      final product = await addProduct('p-read');
      await InvoiceService.insertInvoice(
          salesDoc('inv-read', product, DateTime(2026, 1, 10)));
      await ExpenseService.insertExpense(
          expense('ex-read', DateTime(2026, 1, 12)));
      await lockTo(lockDay());
      // Viewing, exporting and ledger reads still work on locked rows.
      expect((await InvoiceService.getInvoiceById('inv-read'))!.id, 'inv-read');
      expect(await InvoiceService.getAllInvoices(), isNotEmpty);
      expect(
          await InvoiceService.getInvoicesForExport(
              fromDate: DateTime(2026, 1, 1), toDate: DateTime(2026, 12, 31)),
          isNotEmpty);
      expect((await ExpenseService.getExpenseById('ex-read'))!.id, 'ex-read');
      expect(await ExpenseService.getAllExpenses(), isNotEmpty);
    });
  });

  group('lock changes are audit-logged', () {
    test('lock and unlock write queryable audit rows', () async {
      await lockTo(lockDay(), username: 'test-admin');
      var rows = await AuditLogService.recent(limit: 50);
      final locked = rows.where((r) =>
          r['action'] == AuditActions.periodLock &&
          r['entity'] == 'settings' &&
          r['entity_id'] == SettingKey.lockedBeforeDate.key);
      expect(locked, hasLength(1));
      expect(locked.single['username'], 'test-admin');
      expect(locked.single['details'], contains('2026-03-31'));

      await PeriodLockService.setLockedBeforeDate(null, username: 'test-admin');
      rows = await AuditLogService.recent(limit: 50);
      final unlocked = rows.where((r) =>
          r['action'] == AuditActions.periodUnlock &&
          r['entity_id'] == SettingKey.lockedBeforeDate.key);
      expect(unlocked, hasLength(1));
      expect(await PeriodLockService.getLockedBeforeDate(), isNull);
    });
  });

  group('settings UI gate', () {
    // sqflite_ffi does real async I/O, which stays frozen under the
    // widget-test fake clock. Keep real async enabled until the section's
    // initial settings load has rendered, then settle normally.
    Future<void> pumpSection(WidgetTester tester, bool isAdmin) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: FinancialPeriodLockSection(
                isAdmin: isAdmin, username: 'test-admin'),
          ),
        ));
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (!isAdmin ||
              tester.any(find.text('Financial period lock'))) {
            break;
          }
        }
      });
      await tester.pumpAndSettle();
    }

    testWidgets('non-admin users see no lock controls', (tester) async {
      await pumpSection(tester, false);
      expect(find.text('Financial period lock'), findsNothing);
      expect(find.text('Lock period'), findsNothing);
    });

    testWidgets('admin users see the lock controls', (tester) async {
      await pumpSection(tester, true);
      expect(find.text('Financial period lock'), findsOneWidget);
      expect(find.text('Lock period'), findsOneWidget);
      expect(find.text('Unlock'), findsOneWidget);
    });
  });
}
