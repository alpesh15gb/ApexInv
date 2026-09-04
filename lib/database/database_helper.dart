import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/utils/app_logger.dart';
import 'package:apexbooks/utils/password_utils.dart';
import 'sync_schema.dart';

const _tag = 'DatabaseHelper';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();
  static String? _path;
  static String? get path => _path;
  static Database? _database;
  final dbVersion = 51;

  /// Emits when the sync engine finishes applying pulled remote rows, so the
  /// UI layer can refresh its lists. Write-side signaling needs no stream:
  /// the `_sync_outbox` capture triggers already record every write, and the
  /// engine's post-write nudge is driven by the outbox pending-count watcher
  /// in the sync controller.
  final _pullSignal = StreamController<void>.broadcast();
  Stream<void> get onPullApplied => _pullSignal.stream;

  /// Emits on the pull signal — used by the engine, not by write paths.
  void notifyPullApplied() {
    if (!_pullSignal.isClosed) _pullSignal.add(null);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbDir = await getApplicationSupportDirectory();
    _path = join(dbDir.path, 'apexbooks.db');
    return await openDatabase(
      _path!,
      version: dbVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  @visibleForTesting
  Future<void> createDbForTest(Database db, int version) =>
      _createDB(db, version);

  @visibleForTesting
  Future<void> upgradeDbForTest(Database db, int oldVersion, int newVersion) =>
      _upgradeDB(db, oldVersion, newVersion);

  @visibleForTesting
  void useDatabaseForTest(Database db) {
    _database = db;
  }

  @visibleForTesting
  void clearDatabaseForTest() {
    _database = null;
    _path = null;
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE customers (
        id TEXT PRIMARY KEY,
        name TEXT,
        email TEXT,
        phone TEXT,
        address TEXT,
        gstin TEXT,
        business_name TEXT DEFAULT '',
        credit_limit REAL DEFAULT 0,
        credit_limit_enabled INTEGER DEFAULT 0,
        payment_term_id TEXT DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT,
        description TEXT,
        price REAL,
        stock REAL,
        hsncode TEXT,
        tax_rate INTEGER,
        type TEXT DEFAULT 'product',
        default_discount REAL DEFAULT 0,
        purchase_price REAL DEFAULT 0.0,
        alias_name TEXT,
        unit TEXT DEFAULT '',
        unlimited_stock INTEGER DEFAULT 0,
        price_includes_tax INTEGER DEFAULT 0,
        reorder_level REAL DEFAULT 0,
        barcode TEXT DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE product_metadata (
        product_id TEXT PRIMARY KEY,
        storage_location TEXT,
        container_number TEXT,
        batch_number TEXT,
        expiry_date TEXT,
        manufacture_date TEXT,
        supplier_name TEXT,
        sku_code TEXT,
        notes TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE invoices (
        id TEXT PRIMARY KEY,
        customer_id TEXT,
        customer_name TEXT,
        customer_email TEXT,
        customer_phone TEXT,
        customer_address TEXT,
        customer_gstin TEXT,
        customer_business_name TEXT DEFAULT '',
        date TEXT,
        notes TEXT,
        tax_rate REAL,
        type TEXT,
        currency_code TEXT DEFAULT 'INR',
        currency_symbol TEXT DEFAULT '₹',
        tax_mode TEXT DEFAULT 'global',
        deleted_at TEXT,
        upi_id TEXT,
        bank_account_id TEXT,
        due_date TEXT,
        quantity_label TEXT,
        additional_costs TEXT,
        previous_balance REAL DEFAULT 0.0,
        invoice_number TEXT,
        invoice_discount_type TEXT DEFAULT 'percent',
        invoice_discount_value REAL DEFAULT 0.0,
        invoice_title TEXT,
        hide_invoice_number INTEGER DEFAULT 0,
        custom_invoice_number TEXT,
        is_interstate INTEGER DEFAULT 0,
        payment_term_id TEXT DEFAULT '',
        custom_fields TEXT DEFAULT '',
        reference_invoice_id TEXT,
        is_recurring INTEGER DEFAULT 0,
        recurring_frequency TEXT,
        recurring_next_date TEXT,
        sales_channel TEXT DEFAULT 'invoice',
        source_order_id TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE invoice_items (
        id TEXT PRIMARY KEY,
        invoice_id TEXT,
        product_id TEXT,
        product_name TEXT,
        product_description TEXT,
        product_price REAL,
        product_tax_rate INTEGER,
        product_hsn_code TEXT,
        quantity REAL,
        discount REAL,
        unit_price REAL,
        extra_cost REAL,
        discount_per_unit INTEGER DEFAULT 0,
        is_product_saved INTEGER DEFAULT 0,
        product_type TEXT DEFAULT 'product',
        product_purchase_price REAL DEFAULT 0.0,
        product_alias_name TEXT,
        product_unit TEXT DEFAULT '',
        unit TEXT,
        product_price_includes_tax INTEGER DEFAULT 0,
        description TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE,
        password TEXT,
        user_type TEXT,
        salt TEXT,
        password_changed INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE company_info (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        address TEXT,
        phone TEXT,
        email TEXT,
        website TEXT,
        gstin TEXT,
        pan_number TEXT DEFAULT '',
        fssai_code TEXT DEFAULT '',
        country TEXT DEFAULT 'India'
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE _migration_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        version INTEGER,
        step TEXT,
        status TEXT,
        message TEXT,
        applied_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE invoice_payments (
        id               TEXT PRIMARY KEY,
        invoice_id       TEXT NOT NULL,
        invoice_number   TEXT NOT NULL,
        receipt_number   TEXT NOT NULL,
        amount_paid      REAL NOT NULL,
        tax_amount_paid  REAL NOT NULL DEFAULT 0,
        previously_paid  REAL NOT NULL DEFAULT 0,
        balance_after    REAL NOT NULL,
        date_paid        TEXT NOT NULL,
        payment_method   TEXT,
        notes            TEXT,
        cheque_number    TEXT,
        cheque_date      TEXT,
        cheque_cleared   INTEGER DEFAULT 0,
        account_id       TEXT,
        cheque_id        TEXT,
        cheque_status    TEXT DEFAULT 'none'
      )
    ''');

    await db.execute('''
      CREATE TABLE audit_log (
        id TEXT PRIMARY KEY,
        username TEXT,
        action TEXT NOT NULL,
        entity TEXT,
        entity_id TEXT,
        details TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // Indexes
    await db.execute(
        'CREATE INDEX idx_invoices_customer ON invoices(customer_name)');
    await db.execute('CREATE INDEX idx_invoices_date ON invoices(date)');
    await db.execute('CREATE INDEX idx_invoices_type ON invoices(type)');
    await db.execute('CREATE INDEX idx_customers_name ON customers(name)');
    await db.execute('CREATE INDEX idx_products_name ON products(name)');
    await db.execute(
        'CREATE INDEX idx_invoice_items_invoice ON invoice_items(invoice_id)');
    await db.execute(
        'CREATE INDEX idx_payments_invoice ON invoice_payments(invoice_id)');
    await db.execute(
        'CREATE INDEX idx_payments_date ON invoice_payments(date_paid)');

    // Insert dummy company info
    await db.insert('company_info', {
      'name': 'Your Company Name',
      'address': '123 Street \nCity, State 12345',
      'phone': '9876543210',
      'email': 'info@yourcompany.com',
      'website': 'www.yourcompany.com',
      'gstin': ''
    });

    // No seeded credentials: the first launch creates the owner account
    // through the login setup flow. Existing databases keep their users;
    // legacy default accounts are still forced through a password change.

    // Insert default template
    await db
        .insert('settings', {'key': 'invoice_template', 'value': 'classic'});

    // Insert default currency
    await db.insert('settings', {'key': 'currency', 'value': 'INR'});

    // ── Phase 2: Payment Terms ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payment_terms (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        days INTEGER NOT NULL DEFAULT 0,
        is_default INTEGER DEFAULT 0
      )
    ''');
    final termDefaults = [
      {'id': 'term-0', 'name': 'Due on Receipt', 'days': 0, 'is_default': 1},
      {'id': 'term-15', 'name': 'Net 15', 'days': 15, 'is_default': 0},
      {'id': 'term-30', 'name': 'Net 30', 'days': 30, 'is_default': 0},
      {'id': 'term-45', 'name': 'Net 45', 'days': 45, 'is_default': 0},
      {'id': 'term-60', 'name': 'Net 60', 'days': 60, 'is_default': 0},
    ];
    for (final t in termDefaults) {
      await db.insert('payment_terms', t);
    }

    // ── Phase 3: Expenses ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS expense_categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY,
        description TEXT NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        date TEXT NOT NULL,
        category_id TEXT NOT NULL,
        payment_method TEXT,
        notes TEXT,
        account_id TEXT,
        cheque_id TEXT,
        cheque_status TEXT DEFAULT 'none',
        payment_group_id TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_category ON expenses(category_id)');
    final expenseCats = [
      {'id': 'cat-rent', 'name': 'Rent'},
      {'id': 'cat-salary', 'name': 'Salary'},
      {'id': 'cat-transport', 'name': 'Transport'},
      {'id': 'cat-utilities', 'name': 'Utilities'},
      {'id': 'cat-office', 'name': 'Office Supplies'},
      {'id': 'cat-marketing', 'name': 'Marketing'},
      {'id': 'cat-maintenance', 'name': 'Maintenance'},
      {'id': 'cat-other', 'name': 'Other'},
    ];
    for (final c in expenseCats) {
      await db.insert('expense_categories', c);
    }

    // ── Phase 4: Purchase Orders ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_orders (
        id TEXT PRIMARY KEY,
        order_number TEXT,
        vendor_name TEXT NOT NULL,
        vendor_phone TEXT,
        vendor_email TEXT,
        vendor_address TEXT,
        date TEXT NOT NULL,
        expected_date TEXT,
        status TEXT DEFAULT 'draft',
        total_amount REAL DEFAULT 0,
        amount_paid REAL DEFAULT 0,
        price_includes_tax INTEGER DEFAULT 0,
        notes TEXT,
        currency_code TEXT DEFAULT 'INR',
        currency_symbol TEXT DEFAULT '₹'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_order_items (
        id TEXT PRIMARY KEY,
        purchase_order_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL DEFAULT 0,
        price_per_unit REAL NOT NULL DEFAULT 0,
        tax_rate REAL DEFAULT 0,
        discount REAL DEFAULT 0,
        description TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_po_items_order ON purchase_order_items(purchase_order_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_po_date ON purchase_orders(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_po_status ON purchase_orders(status)');

    // ── Phase 5: Batch/Serial Tracking ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS batch_info (
        id TEXT PRIMARY KEY,
        product_id TEXT NOT NULL,
        batch_number TEXT NOT NULL,
        serial_number TEXT,
        quantity REAL DEFAULT 0,
        mrp REAL DEFAULT 0,
        expiry_date TEXT,
        manufacturing_date TEXT,
        size TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_batch_product ON batch_info(product_id)');

    // ── Phase 6: Custom Fields ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS custom_fields (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        type TEXT DEFAULT 'text',
        enabled INTEGER DEFAULT 1
      )
    ''');

    // ── Phase 6b: Purchase bills (inward supplies / GSTR-2) ──
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_bills (
        id TEXT PRIMARY KEY,
        bill_number TEXT,
        supplier_name TEXT NOT NULL,
        supplier_gstin TEXT,
        supplier_phone TEXT,
        supplier_email TEXT,
        supplier_address TEXT,
        date TEXT NOT NULL,
        due_date TEXT,
        total_amount REAL DEFAULT 0,
        total_tax REAL DEFAULT 0,
        amount_paid REAL DEFAULT 0,
        itc_eligible INTEGER DEFAULT 1,
        reverse_charge INTEGER DEFAULT 0,
        price_includes_tax INTEGER DEFAULT 0,
        notes TEXT,
        currency_code TEXT DEFAULT 'INR',
        currency_symbol TEXT DEFAULT '?'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_bill_items (
        id TEXT PRIMARY KEY,
        purchase_bill_id TEXT NOT NULL,
        product_id TEXT,
        product_name TEXT NOT NULL,
        hsn_code TEXT,
        quantity REAL DEFAULT 1,
        unit TEXT,
        rate REAL DEFAULT 0,
        tax_rate REAL DEFAULT 0,
        discount REAL DEFAULT 0,
        price_includes_tax INTEGER DEFAULT 0,
        taxable_value REAL DEFAULT 0,
        igst REAL DEFAULT 0,
        cgst REAL DEFAULT 0,
        sgst REAL DEFAULT 0,
        amount REAL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_bill_payments (
        id TEXT PRIMARY KEY,
        purchase_bill_id TEXT NOT NULL,
        amount_paid REAL NOT NULL,
        previously_paid REAL NOT NULL DEFAULT 0,
        balance_after REAL NOT NULL DEFAULT 0,
        date_paid TEXT NOT NULL,
        payment_method TEXT,
        notes TEXT,
        account_id TEXT,
        cheque_id TEXT,
        cheque_status TEXT DEFAULT 'none',
        payment_group_id TEXT
      )
    ''');
    // NOTE: the columns above mirror the v48 `link_operational_payments`
    // migration (and price_includes_tax on purchase_orders mirrors v51), so a
    // fresh install matches an upgraded database. Fresh-create only — no
    // version bump, existing databases are untouched.
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_purchase_bill_payments_bill ON purchase_bill_payments(purchase_bill_id)');

    await _createAccountingSchema(db);

    // ── Phase 7: Sync foundation (dbplan.md §3.2) ──
    // Columns + change-capture triggers so every write path (current and
    // future) lands in _sync_outbox transactionally. The sync engine itself
    // stays dormant until the user links a cloud account.
    for (final table in syncTableOrder) {
      await addSyncColumns(db, table,
          withCloudId: cloudIdTables.contains(table),
          withDeletedAt: table == 'customers' || table == 'products');
    }
    await installSyncCapture(db);
    await backfillSyncColumns(db);
  }

  Future<void> _createAccountingSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_accounts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('cash', 'bank')),
        institution TEXT DEFAULT '',
        account_number_masked TEXT DEFAULT '',
        ifsc TEXT DEFAULT '',
        currency_code TEXT NOT NULL DEFAULT 'INR',
        currency_symbol TEXT NOT NULL DEFAULT '₹',
        opening_balance REAL NOT NULL DEFAULT 0,
        opening_date TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        notes TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_transactions (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        transfer_account_id TEXT,
        kind TEXT NOT NULL,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        reference TEXT DEFAULT '',
        notes TEXT DEFAULT '',
        reversal_of TEXT,
        voided_at TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fin_tx_account_date ON financial_transactions(account_id, date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fin_tx_source ON financial_transactions(source_type, source_id)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_orders (
        id TEXT PRIMARY KEY,
        order_number TEXT NOT NULL,
        customer_id TEXT,
        customer_name TEXT NOT NULL,
        customer_email TEXT DEFAULT '',
        customer_phone TEXT DEFAULT '',
        customer_address TEXT DEFAULT '',
        customer_gstin TEXT DEFAULT '',
        date TEXT NOT NULL,
        expected_date TEXT,
        status TEXT NOT NULL DEFAULT 'draft',
        currency_code TEXT NOT NULL DEFAULT 'INR',
        currency_symbol TEXT NOT NULL DEFAULT '₹',
        price_includes_tax INTEGER DEFAULT 0,
        notes TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_order_items (
        id TEXT PRIMARY KEY,
        sale_order_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        description TEXT DEFAULT '',
        quantity REAL NOT NULL,
        fulfilled_quantity REAL NOT NULL DEFAULT 0,
        unit_price REAL NOT NULL,
        tax_rate REAL NOT NULL DEFAULT 0,
        discount REAL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_orders_status ON sale_orders(status)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sale_order_items_order ON sale_order_items(sale_order_id)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS cheques (
        id TEXT PRIMARY KEY,
        direction TEXT NOT NULL CHECK(direction IN ('received', 'issued')),
        party_name TEXT NOT NULL,
        amount REAL NOT NULL,
        currency_code TEXT NOT NULL DEFAULT 'INR',
        currency_symbol TEXT NOT NULL DEFAULT '₹',
        cheque_number TEXT NOT NULL,
        cheque_date TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        bank_account_id TEXT,
        deposited_at TEXT,
        cleared_at TEXT,
        notes TEXT DEFAULT ''
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_cheques_status_date ON cheques(status, cheque_date)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS loan_accounts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        lender TEXT NOT NULL,
        original_principal REAL NOT NULL,
        annual_interest_rate REAL NOT NULL DEFAULT 0,
        start_date TEXT NOT NULL,
        maturity_date TEXT,
        disbursement_account_id TEXT,
        currency_code TEXT NOT NULL DEFAULT 'INR',
        currency_symbol TEXT NOT NULL DEFAULT '₹',
        status TEXT NOT NULL DEFAULT 'active',
        notes TEXT DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS loan_movements (
        id TEXT PRIMARY KEY,
        loan_id TEXT NOT NULL,
        date TEXT NOT NULL,
        type TEXT NOT NULL,
        principal_amount REAL NOT NULL DEFAULT 0,
        interest_amount REAL NOT NULL DEFAULT 0,
        fee_amount REAL NOT NULL DEFAULT 0,
        account_id TEXT NOT NULL,
        reference TEXT DEFAULT '',
        notes TEXT DEFAULT '',
        voided_at TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loan_movements_loan_date ON loan_movements(loan_id, date)');

    await db.insert(
        'financial_accounts',
        {
          'id': 'cash-default',
          'name': 'Cash In Hand',
          'type': 'cash',
          'currency_code': 'INR',
          'currency_symbol': '₹',
          'opening_balance': 0,
          'opening_date': DateTime(2000).toIso8601String(),
          'active': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _backfillAccountingTransactions(Database db) async {
    Future<String> ensureAccount(
        String type, String code, String symbol) async {
      final id = type == 'cash' && code == 'INR'
          ? 'cash-default'
          : type == 'cash'
              ? 'cash-$code'
              : 'bank-general-$code';
      await db.insert(
          'financial_accounts',
          {
            'id': id,
            'name': type == 'cash'
                ? 'Cash In Hand${code == 'INR' ? '' : ' ($code)'}'
                : 'General Bank${code == 'INR' ? '' : ' ($code)'}',
            'type': type,
            'currency_code': code,
            'currency_symbol': symbol,
            'opening_balance': 0,
            'opening_date': DateTime(2000).toIso8601String(),
            'active': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      return id;
    }

    final incoming = await db.rawQuery('''
      SELECT p.*, i.customer_name, i.currency_code, i.currency_symbol
      FROM invoice_payments p JOIN invoices i ON i.id = p.invoice_id
    ''');
    for (final row in incoming) {
      final code = row['currency_code'] as String? ?? 'INR';
      final symbol = row['currency_symbol'] as String? ?? '₹';
      final method = row['payment_method'] as String? ?? 'Cash';
      final paymentId = row['id'] as String;
      if (method == 'Check' &&
          (row['cheque_number'] as String? ?? '').isNotEmpty) {
        final chequeId = 'legacy-cheque-in-$paymentId';
        await db.insert(
            'cheques',
            {
              'id': chequeId,
              'direction': 'received',
              'party_name': row['customer_name'] as String? ?? '',
              'amount': row['amount_paid'],
              'currency_code': code,
              'currency_symbol': symbol,
              'cheque_number': row['cheque_number'],
              'cheque_date': row['cheque_date'] ?? row['date_paid'],
              'status': (row['cheque_cleared'] as int? ?? 0) == 1
                  ? 'cleared'
                  : 'pending',
              'source_type': 'invoice_payment',
              'source_id': paymentId,
              if ((row['cheque_cleared'] as int? ?? 0) == 1)
                'cleared_at': row['date_paid'],
              'notes': row['notes'] as String? ?? '',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await db.update(
            'invoice_payments',
            {
              'cheque_id': chequeId,
              'cheque_status': (row['cheque_cleared'] as int? ?? 0) == 1
                  ? 'cleared'
                  : 'pending',
            },
            where: 'id = ?',
            whereArgs: [paymentId]);
        // A legacy cleared cheque had already been treated as Bank.
        if ((row['cheque_cleared'] as int? ?? 0) != 1) continue;
      }
      final accountId =
          await ensureAccount(method == 'Cash' ? 'cash' : 'bank', code, symbol);
      if (method == 'Check') {
        await db.update('cheques', {'bank_account_id': accountId},
            where: 'id = ?', whereArgs: ['legacy-cheque-in-$paymentId']);
      }
      await db.update('invoice_payments', {'account_id': accountId},
          where: 'id = ?', whereArgs: [paymentId]);
      await db.insert(
          'financial_transactions',
          {
            'id': 'legacy-in-$paymentId',
            'account_id': accountId,
            'kind': 'customer_receipt',
            'amount': row['amount_paid'],
            'date': row['date_paid'],
            'source_type': 'invoice_payment',
            'source_id': paymentId,
            'reference': row['receipt_number'] as String? ?? '',
            'notes': row['notes'] as String? ?? '',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final outgoing = await db.rawQuery('''
      SELECT p.*, b.currency_code, b.currency_symbol, b.bill_number
      FROM purchase_bill_payments p
      JOIN purchase_bills b ON b.id = p.purchase_bill_id
    ''');
    for (final row in outgoing) {
      final code = row['currency_code'] as String? ?? 'INR';
      final symbol = row['currency_symbol'] as String? ?? '₹';
      final method = row['payment_method'] as String? ?? 'Cash';
      final paymentId = row['id'] as String;
      final accountId =
          await ensureAccount(method == 'Cash' ? 'cash' : 'bank', code, symbol);
      await db.update('purchase_bill_payments', {'account_id': accountId},
          where: 'id = ?', whereArgs: [paymentId]);
      await db.insert(
          'financial_transactions',
          {
            'id': 'legacy-out-$paymentId',
            'account_id': accountId,
            'kind': 'supplier_payment',
            'amount': -((row['amount_paid'] as num).toDouble()),
            'date': row['date_paid'],
            'source_type': 'purchase_bill_payment',
            'source_id': paymentId,
            'reference': row['bill_number'] as String? ?? '',
            'notes': row['notes'] as String? ?? '',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    final expenses = await db.query('expenses');
    for (final row in expenses) {
      final method = row['payment_method'] as String? ?? 'Cash';
      final accountId =
          await ensureAccount(method == 'Cash' ? 'cash' : 'bank', 'INR', '₹');
      await db.update('expenses', {'account_id': accountId},
          where: 'id = ?', whereArgs: [row['id']]);
      await db.insert(
          'financial_transactions',
          {
            'id': 'legacy-expense-${row['id']}',
            'account_id': accountId,
            'kind': 'expense',
            'amount': -((row['amount'] as num).toDouble()),
            'date': row['date'],
            'source_type': 'expense',
            'source_id': row['id'],
            'reference': row['description'] as String? ?? '',
            'notes': row['notes'] as String? ?? '',
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    AppLogger.d(_tag, 'Upgrading database from $oldVersion to $newVersion');

    // Ensure migration log table exists before logging anything
    await db.execute('''
      CREATE TABLE IF NOT EXISTS _migration_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        version INTEGER,
        step TEXT,
        status TEXT,
        message TEXT,
        applied_at TEXT
      )
    ''');

    if (oldVersion < 5) {
      await _runMigrationStep(db, 5, 'add_currency_columns', () async {
        await db.execute(
          "ALTER TABLE invoices ADD COLUMN currency_code TEXT DEFAULT 'INR'",
        );
        await db.execute(
          "ALTER TABLE invoices ADD COLUMN currency_symbol TEXT DEFAULT '₹'",
        );
        await db.insert(
          'settings',
          {'key': 'currency', 'value': 'INR'},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      });
    }

    if (oldVersion < 6) {
      await _runMigrationStep(db, 6, 'add_tax_mode_column', () async {
        await db.execute(
          "ALTER TABLE invoices ADD COLUMN tax_mode TEXT DEFAULT 'global'",
        );
      });
    }

    if (oldVersion < 7) {
      await _runMigrationStep(db, 7, 'hash_plain_passwords', () async {
        final users = await db.query('users');
        for (final user in users) {
          final plainPw = user['password'] as String;
          if (plainPw.length != 64) {
            await db.update(
              'users',
              {'password': PasswordUtils.hash(plainPw)},
              where: 'id = ?',
              whereArgs: [user['id']],
            );
          }
        }
      });
    }

    if (oldVersion < 8) {
      await _runMigrationStep(db, 8, 'add_salt_and_password_changed', () async {
        await db.execute(
          'ALTER TABLE users ADD COLUMN salt TEXT',
        );
        await db.execute(
          'ALTER TABLE users ADD COLUMN password_changed INTEGER NOT NULL DEFAULT 1',
        );
        // Force admin to reset password on next login
        await db.execute(
          "UPDATE users SET password_changed = 0 WHERE username = 'admin'",
        );
      });

      await _runMigrationStep(db, 8, 'add_deleted_at_column', () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN deleted_at TEXT',
        );
      });

      await _runMigrationStep(db, 8, 'add_indexes', () async {
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_invoices_customer ON invoices(customer_name)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_invoices_date ON invoices(date)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_invoices_type ON invoices(type)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_customers_name ON customers(name)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_products_name ON products(name)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON invoice_items(invoice_id)',
        );
      });
    }

    if (oldVersion < 9) {
      await _runMigrationStep(db, 9, 'create_invoice_payments_table', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS invoice_payments (
            id               TEXT PRIMARY KEY,
            invoice_id       TEXT NOT NULL,
            invoice_number   TEXT NOT NULL,
            receipt_number   TEXT NOT NULL,
            amount_paid      REAL NOT NULL,
            tax_amount_paid  REAL NOT NULL DEFAULT 0,
            previously_paid  REAL NOT NULL DEFAULT 0,
            balance_after    REAL NOT NULL,
            date_paid        TEXT NOT NULL,
            payment_method   TEXT,
            notes            TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_payments_invoice ON invoice_payments(invoice_id)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_payments_date ON invoice_payments(date_paid)',
        );
      });
    }

    if (oldVersion < 10) {
      await _runMigrationStep(db, 10, 'add_upi_id_to_invoices', () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN upi_id TEXT',
        );
      });
    }

    if (oldVersion < 11) {
      await _runMigrationStep(db, 11, 'add_due_date_to_invoices', () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN due_date TEXT',
        );
      });
    }

    if (oldVersion < 12) {
      await _runMigrationStep(db, 12, 'add_unit_price_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN unit_price REAL',
        );
      });
    }

    if (oldVersion < 13) {
      await _runMigrationStep(db, 13, 'add_extra_cost_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN extra_cost REAL',
        );
      });
      await _runMigrationStep(db, 13, 'add_quantity_label_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN quantity_label TEXT',
        );
      });
    }

    if (oldVersion < 14) {
      await _runMigrationStep(db, 14, 'add_discount_per_unit_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN discount_per_unit INTEGER DEFAULT 0',
        );
      });
    }

    if (oldVersion < 15) {
      await _runMigrationStep(db, 15, 'add_additional_costs_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN additional_costs TEXT',
        );
      });
    }

    if (oldVersion < 16) {
      await _runMigrationStep(db, 16, 'add_business_name_to_customers',
          () async {
        await db.execute(
          "ALTER TABLE customers ADD COLUMN business_name TEXT DEFAULT ''",
        );
      });
      await _runMigrationStep(db, 16, 'add_customer_business_name_to_invoices',
          () async {
        await db.execute(
          "ALTER TABLE invoices ADD COLUMN customer_business_name TEXT DEFAULT ''",
        );
      });
      await _runMigrationStep(db, 16, 'add_country_to_company_info', () async {
        await db.execute(
          "ALTER TABLE company_info ADD COLUMN country TEXT DEFAULT 'India'",
        );
      });
    }

    if (oldVersion < 17) {
      await _runMigrationStep(db, 17, 'add_is_product_saved_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN is_product_saved INTEGER DEFAULT 0',
        );
      });
    }

    if (oldVersion < 18) {
      await _runMigrationStep(db, 18, 'add_type_to_products', () async {
        await db.execute(
          "ALTER TABLE products ADD COLUMN type TEXT DEFAULT 'product'",
        );
      });
      await _runMigrationStep(db, 18, 'add_product_type_to_invoice_items',
          () async {
        await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN product_type TEXT DEFAULT 'product'",
        );
      });
    }

    if (oldVersion < 19) {
      await _runMigrationStep(db, 19, 'add_default_discount_to_products',
          () async {
        await db.execute(
          'ALTER TABLE products ADD COLUMN default_discount REAL DEFAULT 0',
        );
      });
    }

    if (oldVersion < 20) {
      await _runMigrationStep(db, 20, 'add_bank_account_id_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN bank_account_id TEXT',
        );
      });
    }

    if (oldVersion < 21) {
      await _runMigrationStep(db, 21, 'add_previous_balance_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN previous_balance REAL DEFAULT 0.0',
        );
      });
    }

    if (oldVersion < 22) {
      await _runMigrationStep(db, 22, 'add_pan_number_to_company_info',
          () async {
        await db.execute(
          "ALTER TABLE company_info ADD COLUMN pan_number TEXT DEFAULT ''",
        );
      });
    }

    if (oldVersion < 23) {
      await _runMigrationStep(db, 23, 'add_invoice_number_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN invoice_number TEXT',
        );
      });
    }

    if (oldVersion < 25) {
      await _runMigrationStep(db, 24, 'add_purchase_price_to_products',
          () async {
        await db.execute(
          'ALTER TABLE products ADD COLUMN purchase_price REAL DEFAULT 0.0',
        );
      });
      await _runMigrationStep(
          db, 25, 'add_product_purchase_price_to_invoice_items', () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN product_purchase_price REAL DEFAULT 0.0',
        );
      });
    }

    if (oldVersion < 30) {
      await _runMigrationStep(db, 30, 'add_unit_to_products', () async {
        await db.execute(
          "ALTER TABLE products ADD COLUMN unit TEXT DEFAULT ''",
        );
      });
      await _runMigrationStep(db, 30, 'add_product_unit_to_invoice_items',
          () async {
        await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN product_unit TEXT DEFAULT ''",
        );
      });
      await _runMigrationStep(db, 30, 'add_unit_override_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN unit TEXT',
        );
      });
    }

    if (oldVersion < 32) {
      await _runMigrationStep(db, 32, 'add_alias_name_to_products', () async {
        await db.execute(
          'ALTER TABLE products ADD COLUMN alias_name TEXT',
        );
      });
      await _runMigrationStep(db, 32, 'add_product_alias_name_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN product_alias_name TEXT',
        );
      });
    }

    if (oldVersion < 34) {
      await _runMigrationStep(db, 34, 'add_invoice_title_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN invoice_title TEXT',
        );
      });
      await _runMigrationStep(db, 34, 'add_unlimited_stock_to_products',
          () async {
        await db.execute(
          'ALTER TABLE products ADD COLUMN unlimited_stock INTEGER DEFAULT 0',
        );
      });
    }

    if (oldVersion < 35) {
      await _runMigrationStep(db, 35, 'create_product_metadata_table',
          () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS product_metadata (
            product_id TEXT PRIMARY KEY,
            storage_location TEXT,
            container_number TEXT,
            batch_number TEXT,
            expiry_date TEXT,
            manufacture_date TEXT,
            supplier_name TEXT,
            sku_code TEXT,
            notes TEXT
          )
        ''');
      });
    }

    if (oldVersion < 37) {
      // invoice_items had PRIMARY KEY (invoice_id, product_id), which blocked
      // adding the same product twice to one invoice (allow_duplicate_invoice_items
      // setting). SQLite can't drop a PK via ALTER, so rebuild the table.
      await _runMigrationStep(db, 37, 'add_id_pk_to_invoice_items', () async {
        await db
            .execute('ALTER TABLE invoice_items RENAME TO invoice_items_old');
        await db.execute('''
          CREATE TABLE invoice_items (
            id TEXT PRIMARY KEY,
            invoice_id TEXT,
            product_id TEXT,
            product_name TEXT,
            product_description TEXT,
            product_price REAL,
            product_tax_rate INTEGER,
            product_hsn_code TEXT,
            quantity REAL,
            discount REAL,
            unit_price REAL,
            extra_cost REAL,
            discount_per_unit INTEGER DEFAULT 0,
            is_product_saved INTEGER DEFAULT 0,
            product_type TEXT DEFAULT 'product',
            product_purchase_price REAL DEFAULT 0.0,
            product_alias_name TEXT,
            product_unit TEXT DEFAULT '',
            unit TEXT
          )
        ''');
        await db.execute('''
          INSERT INTO invoice_items SELECT
            lower(hex(randomblob(16))),
            invoice_id, product_id, product_name, product_description, product_price,
            product_tax_rate, product_hsn_code, quantity, discount, unit_price, extra_cost,
            discount_per_unit, is_product_saved, product_type, product_purchase_price,
            product_alias_name, product_unit, unit
          FROM invoice_items_old
        ''');
        await db.execute('DROP TABLE invoice_items_old');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON invoice_items(invoice_id)');
      });
    }

    if (oldVersion < 38) {
      await _runMigrationStep(db, 38, 'add_fssai_code_to_company_info',
          () async {
        await db.execute(
          "ALTER TABLE company_info ADD COLUMN fssai_code TEXT DEFAULT ''",
        );
      });
    }

    if (oldVersion < 38) {
      await _runMigrationStep(db, 38, 'add_price_includes_tax_to_products',
          () async {
        await db.execute(
          "ALTER TABLE products ADD COLUMN price_includes_tax INTEGER DEFAULT 0",
        );
      });
      await _runMigrationStep(
          db, 38, 'add_product_price_includes_tax_to_invoice_items', () async {
        await db.execute(
          "ALTER TABLE invoice_items ADD COLUMN product_price_includes_tax INTEGER DEFAULT 0",
        );
      });
    }

    if (oldVersion < 39) {
      await _runMigrationStep(db, 39, 'add_invoice_discount_to_invoices',
          () async {
        await db.execute(
          "ALTER TABLE invoices ADD COLUMN invoice_discount_type TEXT DEFAULT 'percent'",
        );
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN invoice_discount_value REAL DEFAULT 0.0',
        );
      });
    }

    if (oldVersion < 40) {
      await _runMigrationStep(db, 40, 'add_custom_invoice_number_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN hide_invoice_number INTEGER DEFAULT 0',
        );
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN custom_invoice_number TEXT',
        );
      });
    }

    if (oldVersion < 41) {
      await _runMigrationStep(db, 41, 'backfill_onboarding_completed',
          () async {
        // The first-login onboarding wizard shipped without a backfill, so
        // every upgrading user would be forced through it. If no account is
        // still on a forced default password, the app was already set up the
        // long way before the wizard existed — mark onboarding done. An
        // install still carrying a default-password account (fresh seed, or
        // an upgrade where admin/admin was never changed) falls through and
        // gets the wizard. Username isn't checked — it's user-editable.
        final unchanged = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) FROM users WHERE password_changed = 0',
            )) ??
            0;
        if (unchanged == 0) {
          await db.insert(
            'settings',
            {'key': 'onboarding_completed', 'value': 'true'},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    }

    if (oldVersion < 42) {
      // Per-line description entered while building the invoice. Kept separate
      // from product_description (the product's own text, snapshotted at
      // invoice time) so editing a line never touches the product catalogue.
      // NULL on every pre-v42 row, which reads back as "no description" and
      // prints exactly as those invoices always did.
      await _runMigrationStep(db, 42, 'add_description_to_invoice_items',
          () async {
        await db.execute(
          'ALTER TABLE invoice_items ADD COLUMN description TEXT',
        );
      });
    }

    if (oldVersion < 43) {
      // India interstate-supply flag. Drives IGST vs CGST/SGST display only —
      // no effect on totals. NULL/0 on every pre-v43 row = intrastate, prints
      // exactly as before.
      await _runMigrationStep(db, 43, 'add_is_interstate_to_invoices',
          () async {
        await db.execute(
          'ALTER TABLE invoices ADD COLUMN is_interstate INTEGER DEFAULT 0',
        );
      });
    }

    if (oldVersion < 44) {
      // Phase 2: Payment Terms table
      await _runMigrationStep(db, 44, 'create_payment_terms_table', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS payment_terms (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            days INTEGER NOT NULL DEFAULT 0,
            is_default INTEGER DEFAULT 0
          )
        ''');
        // Seed default terms
        final defaults = [
          {
            'id': 'term-0',
            'name': 'Due on Receipt',
            'days': 0,
            'is_default': 1
          },
          {'id': 'term-15', 'name': 'Net 15', 'days': 15, 'is_default': 0},
          {'id': 'term-30', 'name': 'Net 30', 'days': 30, 'is_default': 0},
          {'id': 'term-45', 'name': 'Net 45', 'days': 45, 'is_default': 0},
          {'id': 'term-60', 'name': 'Net 60', 'days': 60, 'is_default': 0},
        ];
        for (final t in defaults) {
          await db.insert('payment_terms', t,
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });

      // Phase 2: Add credit limit + payment term to customers
      await _runMigrationStep(db, 44, 'add_credit_limit_to_customers',
          () async {
        await db.execute(
            "ALTER TABLE customers ADD COLUMN credit_limit REAL DEFAULT 0");
        await db.execute(
            "ALTER TABLE customers ADD COLUMN credit_limit_enabled INTEGER DEFAULT 0");
        await db.execute(
            "ALTER TABLE customers ADD COLUMN payment_term_id TEXT DEFAULT ''");
      });

      // Phase 2: Add payment_term_id to invoices
      await _runMigrationStep(db, 44, 'add_payment_term_to_invoices', () async {
        await db.execute(
            "ALTER TABLE invoices ADD COLUMN payment_term_id TEXT DEFAULT ''");
      });

      // Phase 3: Expenses tables
      await _runMigrationStep(db, 44, 'create_expenses_tables', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS expense_categories (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL
          )
        ''');
        await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY,
        description TEXT NOT NULL,
        amount REAL NOT NULL DEFAULT 0,
        date TEXT NOT NULL,
        category_id TEXT NOT NULL,
        payment_method TEXT,
        notes TEXT,
        account_id TEXT
      )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_expenses_category ON expenses(category_id)');
        // Seed default categories
        final cats = [
          {'id': 'cat-rent', 'name': 'Rent'},
          {'id': 'cat-salary', 'name': 'Salary'},
          {'id': 'cat-transport', 'name': 'Transport'},
          {'id': 'cat-utilities', 'name': 'Utilities'},
          {'id': 'cat-office', 'name': 'Office Supplies'},
          {'id': 'cat-marketing', 'name': 'Marketing'},
          {'id': 'cat-maintenance', 'name': 'Maintenance'},
          {'id': 'cat-other', 'name': 'Other'},
        ];
        for (final c in cats) {
          await db.insert('expense_categories', c,
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });

      // Phase 4: Purchase Orders tables
      await _runMigrationStep(db, 44, 'create_purchase_orders_tables',
          () async {
        await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_orders (
        id TEXT PRIMARY KEY,
        order_number TEXT,
        vendor_name TEXT NOT NULL,
        vendor_phone TEXT,
        vendor_email TEXT,
        vendor_address TEXT,
        date TEXT NOT NULL,
        expected_date TEXT,
        status TEXT DEFAULT 'draft',
        total_amount REAL DEFAULT 0,
        amount_paid REAL DEFAULT 0,
        price_includes_tax INTEGER DEFAULT 0,
        notes TEXT,
        currency_code TEXT DEFAULT 'INR',
        currency_symbol TEXT DEFAULT '₹'
      )
    ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS purchase_order_items (
            id TEXT PRIMARY KEY,
            purchase_order_id TEXT NOT NULL,
            product_id TEXT NOT NULL,
            product_name TEXT NOT NULL,
            quantity REAL NOT NULL DEFAULT 0,
            price_per_unit REAL NOT NULL DEFAULT 0,
            tax_rate REAL DEFAULT 0,
            discount REAL DEFAULT 0,
            description TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_po_items_order ON purchase_order_items(purchase_order_id)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_po_date ON purchase_orders(date)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_po_status ON purchase_orders(status)');
      });

      // Phase 5: Batch/Serial tracking table
      await _runMigrationStep(db, 44, 'create_batch_info_table', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS batch_info (
            id TEXT PRIMARY KEY,
            product_id TEXT NOT NULL,
            batch_number TEXT NOT NULL,
            serial_number TEXT,
            quantity REAL DEFAULT 0,
            mrp REAL DEFAULT 0,
            expiry_date TEXT,
            manufacturing_date TEXT,
            size TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_batch_product ON batch_info(product_id)');
      });

      // Phase 6: Custom fields table
      await _runMigrationStep(db, 44, 'create_custom_fields_table', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS custom_fields (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            type TEXT DEFAULT 'text',
            enabled INTEGER DEFAULT 1
          )
        ''');
        // Add custom_fields column to invoices
        await db.execute(
            "ALTER TABLE invoices ADD COLUMN custom_fields TEXT DEFAULT ''");
      });
    }

    if (oldVersion < 45) {
      // Sync foundation (dbplan.md §3.2): sync columns on business tables,
      // outbox + state tables, change-capture triggers, backfills. Purely
      // additive; the sync engine stays dormant until a cloud account is
      // linked, so nothing about pre-sync behavior changes.
      await _runMigrationStep(db, 45, 'add_sync_columns', () async {
        for (final table in syncTableOrder) {
          await addSyncColumns(db, table,
              withCloudId: cloudIdTables.contains(table),
              withDeletedAt: table == 'customers' || table == 'products');
        }
      });

      await _runMigrationStep(db, 45, 'install_sync_capture', () async {
        await installSyncCapture(db);
      });

      await _runMigrationStep(db, 45, 'backfill_sync_columns', () async {
        await backfillSyncColumns(db);
      });
    }

    if (oldVersion < 46) {
      await _runMigrationStep(db, 46, 'create_purchase_bills', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS purchase_bills (
            id TEXT PRIMARY KEY,
            bill_number TEXT,
            supplier_name TEXT NOT NULL,
            supplier_gstin TEXT,
            supplier_phone TEXT,
            supplier_email TEXT,
            supplier_address TEXT,
            date TEXT NOT NULL,
            due_date TEXT,
            total_amount REAL DEFAULT 0,
            total_tax REAL DEFAULT 0,
            amount_paid REAL DEFAULT 0,
            itc_eligible INTEGER DEFAULT 1,
            reverse_charge INTEGER DEFAULT 0,
            notes TEXT,
            currency_code TEXT DEFAULT 'INR',
            currency_symbol TEXT DEFAULT '?'
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS purchase_bill_items (
            id TEXT PRIMARY KEY,
            purchase_bill_id TEXT NOT NULL,
            product_id TEXT,
            product_name TEXT NOT NULL,
            hsn_code TEXT,
            quantity REAL DEFAULT 1,
            unit TEXT,
            rate REAL DEFAULT 0,
            tax_rate REAL DEFAULT 0,
            discount REAL DEFAULT 0,
            price_includes_tax INTEGER DEFAULT 0,
            taxable_value REAL DEFAULT 0,
            igst REAL DEFAULT 0,
            cgst REAL DEFAULT 0,
            sgst REAL DEFAULT 0,
            amount REAL DEFAULT 0
          )
        ''');
      });

      await _runMigrationStep(db, 46, 'invoicing_v46_columns', () async {
        for (final stmt in [
          "ALTER TABLE invoices ADD COLUMN reference_invoice_id TEXT",
          "ALTER TABLE invoices ADD COLUMN is_recurring INTEGER DEFAULT 0",
          "ALTER TABLE invoices ADD COLUMN recurring_frequency TEXT",
          "ALTER TABLE invoices ADD COLUMN recurring_next_date TEXT",
          "ALTER TABLE products ADD COLUMN reorder_level REAL DEFAULT 0",
          "ALTER TABLE products ADD COLUMN barcode TEXT DEFAULT ''",
          "ALTER TABLE invoice_payments ADD COLUMN cheque_number TEXT",
          "ALTER TABLE invoice_payments ADD COLUMN cheque_date TEXT",
          "ALTER TABLE invoice_payments ADD COLUMN cheque_cleared INTEGER DEFAULT 0",
        ]) {
          try {
            await db.execute(stmt);
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('duplicate column name')) rethrow;
          }
        }
      });

      await _runMigrationStep(db, 46, 'audit_log_table', () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS audit_log (
            id TEXT PRIMARY KEY,
            username TEXT,
            action TEXT NOT NULL,
            entity TEXT,
            entity_id TEXT,
            details TEXT,
            created_at TEXT NOT NULL
          )
        ''');
      });

      await _runMigrationStep(db, 46, 'sync_register_purchase_bills', () async {
        for (final table in ['purchase_bills', 'purchase_bill_items']) {
          await addSyncColumns(db, table);
        }
        await installSyncCapture(db);
      });
    }

    if (oldVersion < 47) {
      await _runMigrationStep(db, 47, 'create_purchase_bill_payments',
          () async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS purchase_bill_payments (
            id TEXT PRIMARY KEY,
            purchase_bill_id TEXT NOT NULL,
            amount_paid REAL NOT NULL,
            previously_paid REAL NOT NULL DEFAULT 0,
            balance_after REAL NOT NULL DEFAULT 0,
            date_paid TEXT NOT NULL,
            payment_method TEXT,
            notes TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_purchase_bill_payments_bill ON purchase_bill_payments(purchase_bill_id)');
      });
      await _runMigrationStep(db, 47, 'sync_register_purchase_bill_payments',
          () async {
        await addSyncColumns(db, 'purchase_bill_payments');
        await installSyncCapture(db);
      });
    }

    if (oldVersion < 48) {
      await _runMigrationStep(db, 48, 'create_accounting_foundation', () async {
        await _createAccountingSchema(db);
      });
      await _runMigrationStep(db, 48, 'link_operational_payments', () async {
        for (final stmt in [
          "ALTER TABLE invoices ADD COLUMN sales_channel TEXT DEFAULT 'invoice'",
          'ALTER TABLE invoices ADD COLUMN source_order_id TEXT',
          'ALTER TABLE invoice_payments ADD COLUMN account_id TEXT',
          'ALTER TABLE invoice_payments ADD COLUMN cheque_id TEXT',
          "ALTER TABLE invoice_payments ADD COLUMN cheque_status TEXT DEFAULT 'none'",
          'ALTER TABLE purchase_bill_payments ADD COLUMN account_id TEXT',
          'ALTER TABLE purchase_bill_payments ADD COLUMN cheque_id TEXT',
          "ALTER TABLE purchase_bill_payments ADD COLUMN cheque_status TEXT DEFAULT 'none'",
          'ALTER TABLE purchase_bill_payments ADD COLUMN payment_group_id TEXT',
          'ALTER TABLE expenses ADD COLUMN account_id TEXT',
        ]) {
          try {
            await db.execute(stmt);
          } catch (e) {
            if (!e.toString().toLowerCase().contains('duplicate column name')) {
              rethrow;
            }
          }
        }
      });
      await _runMigrationStep(db, 48, 'backfill_account_registers', () async {
        await _backfillAccountingTransactions(db);
      });
      await _runMigrationStep(db, 48, 'sync_register_accounting', () async {
        for (final table in [
          'financial_accounts',
          'financial_transactions',
          'sale_orders',
          'sale_order_items',
          'cheques',
          'loan_accounts',
          'loan_movements',
        ]) {
          await addSyncColumns(db, table);
        }
        await installSyncCapture(db);
        await backfillSyncColumns(db);
      });
    }
    if (oldVersion < 49) {
      await _runMigrationStep(db, 49, 'normalize_tax_mode', () async {
        await db.execute(
            "UPDATE invoices SET tax_mode = 'per_item' WHERE tax_mode = 'item'");
        final saleOrderColumns =
            await db.rawQuery('PRAGMA table_info(sale_orders)');
        if (saleOrderColumns.any((column) => column['name'] == 'tax_mode')) {
          await db.execute(
              "UPDATE sale_orders SET tax_mode = 'per_item' WHERE tax_mode = 'item'");
        }
      });
      await _runMigrationStep(db, 49, 'register_extended_sync_tables',
          () async {
        for (final table in syncTableOrder) {
          await addSyncColumns(db, table,
              withCloudId: cloudIdTables.contains(table));
        }
        await installSyncCapture(db);
        await backfillSyncColumns(db);
      });
    }
    if (oldVersion < 50) {
      // Repair: databases upgraded by builds predating a table's sync
      // registration (notably expense_categories, expenses, batch_info,
      // custom_fields, purchase_orders, purchase_order_items) missed its
      // sync columns, while later backfills assumed them present — startup
      // crash "no such column: updated_at". Idempotent; safe on healthy DBs.
      await _runMigrationStep(db, 50, 'repair_sync_columns', () async {
        for (final table in syncTableOrder) {
          await addSyncColumns(db, table,
              withCloudId: cloudIdTables.contains(table),
              withDeletedAt: table == 'customers' || table == 'products');
        }
        await installSyncCapture(db);
        await backfillSyncColumns(db);
      });
    }
    if (oldVersion < 51) {
      // Document-level GST toggle state plus the purchase-bill per-line flag.
      // Existing rows keep exclusive semantics (0), matching previous paths.
      await _runMigrationStep(db, 51, 'add_price_includes_tax_columns',
          () async {
        for (final table in [
          'purchase_bill_items',
          'purchase_bills',
          'sale_orders',
          'purchase_orders',
        ]) {
          final exists = Sqflite.firstIntValue(await db.rawQuery(
                  "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                  [table])) ==
              1;
          if (!exists) continue;
          final cols = await db.rawQuery('PRAGMA table_info($table)');
          if (cols.any((c) => c['name'] == 'price_includes_tax')) continue;
          await db.execute(
            'ALTER TABLE $table ADD COLUMN price_includes_tax INTEGER DEFAULT 0',
          );
        }
      });
    }
  }

  Future<void> _runMigrationStep(
    Database db,
    int version,
    String step,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      await db.insert('_migration_log', {
        'version': version,
        'step': step,
        'status': 'success',
        'message': null,
        'applied_at': DateTime.now().toIso8601String(),
      });
      AppLogger.d(_tag, 'Migration v$version/$step: success');
    } catch (e, stack) {
      // Treat already-applied schema changes as success so a partial prior run
      // doesn't block startup (e.g. column added but version not yet bumped).
      final msg = e.toString().toLowerCase();
      if (msg.contains('duplicate column name') ||
          msg.contains('already exists')) {
        AppLogger.d(
            _tag, 'Migration v$version/$step: already applied, skipping');
        await db.insert('_migration_log', {
          'version': version,
          'step': step,
          'status': 'skipped',
          'message': e.toString(),
          'applied_at': DateTime.now().toIso8601String(),
        });
        return;
      }
      AppLogger.e(_tag, 'Migration v$version/$step failed', e, stack);
      await db.insert('_migration_log', {
        'version': version,
        'step': step,
        'status': 'failure',
        'message': e.toString(),
        'applied_at': DateTime.now().toIso8601String(),
      });
      rethrow;
    }
  }

  // ─────────────────────────────────────────────
  // Optional: Clear All Tables (For Debug)
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('invoice_items');
    await db.delete('invoices');
    await db.delete('customers');
    await db.delete('products');
    await db.delete('users');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// Permanently removes this app's database file and opens a fresh database.
  /// This deliberately does not use [clearAllData], which is debug-only and
  /// does not cover every table or replace the on-disk database.
  Future<Database> wipeDatabase() async {
    await database; // Resolve the app-owned path before closing the handle.
    final dbPath = _path!;
    await close();
    await deleteDatabase(dbPath);
    return reinitialize();
  }

  /// Closes the current connection, clears the singleton reference, and
  /// re-opens a fresh connection. Call this after the DB file is replaced
  /// (e.g. after a backup restore).
  Future<Database> reinitialize() async {
    await close();
    _database = await _initDB();
    return _database!;
  }
}
