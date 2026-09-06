import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/sync_controller.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:crypto/crypto.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/models/backup_info.dart';
import 'package:apexbooks/models/backup_results.dart';
import 'package:apexbooks/utils/app_directories.dart';

class BackupManager {
  static const String _backupExtension = '.invoicedb';
  static const String _jsonExtension = '.json';

  /// Post-restore sync hook (dbplan §3.7): the restored DB's cursors and
  /// outbox describe the *old* device's state. If cloud sync is linked,
  /// force a full LWW merge on next cycle. Failure-safe: sync issues must
  /// never fail the restore itself.
  void _notifyDatabaseReplaced() {
    try {
      final engine = SyncController.instance.engineIfLinked;
      if (engine != null) unawaited(engine.onDatabaseReplaced());
    } catch (_) {
      // SyncController not initialized (tests / never linked) — nothing to do.
    }
  }

  // Tables excluded from JSON exports (contain sensitive data).
  static const Set<String> _excludedFromJsonExport = {'users'};

  /// Allowlist for JSON restore. Credentials, sync protocol state, audit
  /// history, and migration logs are never overwritten from a backup file —
  /// a crafted or foreign file must not be able to rotate roles, replay
  /// cursors/outbox rows, or forge audit entries.
  static const Set<String> _restorableTables = {
    'company_info',
    'customers',
    'products',
    'product_metadata',
    'batch_info',
    'custom_fields',
    'invoices',
    'invoice_items',
    'invoice_payments',
    'expense_categories',
    'expenses',
    'purchase_orders',
    'purchase_order_items',
    'purchase_bills',
    'purchase_bill_items',
    'purchase_bill_payments',
    'financial_accounts',
    'financial_transactions',
    'sale_orders',
    'sale_order_items',
    'cheques',
    'loan_accounts',
    'loan_movements',
    'settings',
  };

  // Restore order ensures parent tables are inserted before child tables,
  // preventing foreign-key constraint violations. Covers ALL restorable
  // tables; JSON restore clears in reverse order so a missing section in
  // the file deletes (replaces) rather than merges.
  static const List<String> _restoreTableOrder = [
    'company_info',
    'customers',
    'products',
    'product_metadata',
    'batch_info',
    'custom_fields',
    'expense_categories',
    'financial_accounts',
    'settings',
    'invoices',
    'sale_orders',
    'purchase_orders',
    'purchase_bills',
    'loan_accounts',
    'cheques',
    'expenses',
    'invoice_items',
    'invoice_payments',
    'purchase_order_items',
    'purchase_bill_items',
    'purchase_bill_payments',
    'sale_order_items',
    'financial_transactions',
    'loan_movements',
  ];

  // Create backup of the entire database
  Future<BackupResult> createBackup({
    String? customPath,
    BackupType type = BackupType.database,
  }) async {
    try {
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final backupName = 'invoice_backup_$timestamp';

      String backupPath;

      if (type == BackupType.database) {
        backupPath = await _createDatabaseBackup(backupName, customPath);
      } else {
        backupPath = await _createJsonBackup(backupName, customPath);
      }

      return BackupResult(
        success: true,
        message: 'Backup created successfully',
        filePath: backupPath,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      return BackupResult(
        success: false,
        message: 'Backup failed: ${e.toString()}',
      );
    }
  }

  // Create a transactionally consistent SQLite snapshot without closing the
  // live database (a raw file copy can miss WAL pages).
  Future<String> _createDatabaseBackup(
    String backupName,
    String? customPath,
  ) async {
    final backupDir = customPath ?? await _getBackupDirectory();
    await Directory(backupDir).create(recursive: true);
    final backupPath = join(backupDir, '$backupName$_backupExtension');
    final db = await DatabaseHelper().database;
    await db.execute("VACUUM INTO '${backupPath.replaceAll("'", "''")}'");
    // SHA-256 sidecar manifest: restore verifies before touching live.
    await writeManifest(backupPath);

    return backupPath;
  }

  /// Sidecar manifest path for a `.invoicedb` backup.
  static String manifestPathFor(String backupPath) => '$backupPath.sha256';

  /// Hex SHA-256 of [bytes] (unit-testable pure helper).
  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// Hex SHA-256 of the file at [path].
  static Future<String> computeFileSha256(String path) async {
    return sha256Hex(await File(path).readAsBytes());
  }

  /// Writes the SHA-256 sidecar for [backupPath].
  static Future<void> writeManifest(String backupPath) async {
    final hex = await computeFileSha256(backupPath);
    await File(manifestPathFor(backupPath)).writeAsString('$hex\n');
  }

  /// Verifies the SHA-256 sidecar when present. Missing sidecar (legacy
  /// backups) passes; present-but-mismatched fails.
  static Future<bool> verifyManifest(String backupPath) async {
    final manifest = File(manifestPathFor(backupPath));
    if (!await manifest.exists()) return true;
    final expected = (await manifest.readAsString()).trim().toLowerCase();
    if (expected.isEmpty) return true;
    final actual = (await computeFileSha256(backupPath)).toLowerCase();
    return expected == actual;
  }

  /// Known tables for `.invoicedb` schema gating (restorable + credentials,
  /// sync protocol, audit/migration logs). Anything else aborts the restore
  /// before the live file is touched.
  static const Set<String> _dbSchemaAllowlist = {
    'company_info',
    'customers',
    'products',
    'product_metadata',
    'batch_info',
    'custom_fields',
    'invoices',
    'invoice_items',
    'invoice_payments',
    'expense_categories',
    'expenses',
    'purchase_orders',
    'purchase_order_items',
    'purchase_bills',
    'purchase_bill_items',
    'purchase_bill_payments',
    'financial_accounts',
    'financial_transactions',
    'sale_orders',
    'sale_order_items',
    'cheques',
    'loan_accounts',
    'loan_movements',
    'settings',
    'users',
    'audit_log',
    'payment_terms',
    '_sync_outbox',
    '_sync_state',
    '_migration_log',
  };

  /// Integrity + schema gate for a staged temp database file. Throws on
  /// failure; unit-testable without touching the live database.
  static Future<void> verifyTempDatabase(String tempPath) async {
    final tempDb = await openDatabase(tempPath, readOnly: true);
    try {
      final integrity = await tempDb.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw StateError('Staged database failed integrity_check');
      }
      final tables = await tempDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
      final names = {for (final t in tables) t['name'] as String};
      if (!names.contains('invoices')) {
        throw StateError('Staged database missing core table: invoices');
      }
      final unknown = names.difference(_dbSchemaAllowlist);
      if (unknown.isNotEmpty) {
        throw StateError('Staged database has unknown tables: $unknown');
      }
    } finally {
      await tempDb.close();
    }
  }

  // Create JSON export backup (excludes sensitive tables such as 'users')
  Future<String> _createJsonBackup(
    String backupName,
    String? customPath,
  ) async {
    final backupDir = customPath ?? await _getBackupDirectory();
    final backupPath = join(backupDir, '$backupName$_jsonExtension');

    final backupData = await _exportDataToJson(await DatabaseHelper().database);

    await File(backupPath).writeAsString(jsonEncode(backupData));

    return backupPath;
  }

  // Export database data to JSON format (sensitive tables excluded)
  Future<Map<String, dynamic>> _exportDataToJson(Database database) async {
    final backupData = <String, dynamic>{};

    final tables = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");

    for (final table in tables) {
      final tableName = table['name'] as String;
      if (_excludedFromJsonExport.contains(tableName)) continue;
      var tableData = await database.query(tableName);
      if (tableName == 'settings') {
        // Never export the cloud sync bearer token; a shared backup file
        // must not carry credentials.
        tableData = tableData
            .where((row) => row['key'] != 'cloud_sync_account')
            .toList();
      }
      backupData[tableName] = tableData;
    }

    backupData['_metadata'] = {
      'created_at': DateTime.now().toIso8601String(),
      'version': '1.0',
      'app_name': AppConfig.name,
      'backup_type': 'json_export',
      'record_count': backupData.length - 1,
    };

    return backupData;
  }

  // Restore from backup
  Future<BackupResult> restoreBackup({
    required String backupPath,
  }) async {
    try {
      final backupFile = File(backupPath);
      if (!await backupFile.exists()) {
        return BackupResult(
          success: false,
          message: 'Backup file not found',
        );
      }

      // Verify integrity before touching the live database
      if (!await verifyBackup(backupPath)) {
        return BackupResult(
          success: false,
          message: 'Backup file is corrupted or invalid',
        );
      }

      final extension = backupPath.split('.').last;

      if (extension == _backupExtension.replaceAll('.', '')) {
        await _restoreFromDatabaseBackup(backupPath);
      } else if (extension == _jsonExtension.replaceAll('.', '')) {
        await _restoreFromJsonBackup(backupPath);
      } else {
        return BackupResult(
          success: false,
          message: 'Unsupported backup format',
        );
      }

      // Post-restore hook (dbplan §3.7): the restored file's sync cursors
      // describe the *old* device — force a full LWW merge on next sync.
      _notifyDatabaseReplaced();

      return BackupResult(
        success: true,
        message: 'Backup restored successfully',
        filePath: backupPath,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      return BackupResult(
        success: false,
        message: 'Restore failed: ${e.toString()}',
      );
    }
  }

  // Restore from database backup.
  // Crash-atomic staging: the backup is copied to a temp file beside the
  // live database, gated there by manifest + integrity_check + schema
  // allowlist, and only then atomically renamed over live. The live file is
  // never overwritten by an unverified copy, so a crash mid-restore cannot
  // leave a half-written database. The singleton is closed BEFORE any file
  // copy (WAL-mode safety); stale sidecars are deleted so they can never
  // replay onto the restored copy. The safety copy is restored on failure
  // and deleted only on success.
  Future<void> _restoreFromDatabaseBackup(String backupPath) async {
    final dbPath = DatabaseHelper.path!;
    final safetyPath = '$dbPath.pre_restore_backup';
    final tempPath = '$dbPath.restore_tmp';
    var restored = false;

    // Close singleton and null its reference first (see above).
    await DatabaseHelper().close();

    // Safety copy of current database (absent on a first-run device).
    if (await File(dbPath).exists()) {
      await File(dbPath).copy(safetyPath);
    }

    try {
      // Manifest gate before touching live (mismatch → abort).
      if (!await verifyManifest(backupPath)) {
        throw StateError('Backup manifest mismatch (file modified?)');
      }

      // Stage to temp beside live (same filesystem for atomic rename).
      if (await File(tempPath).exists()) await File(tempPath).delete();
      await _deleteDbSidecars(tempPath);
      await File(backupPath).copy(tempPath);

      // Gate the staged copy before it touches live.
      await verifyTempDatabase(tempPath);

      // Atomic-ish swap over live.
      await _deleteDbSidecars(dbPath);
      if (await File(dbPath).exists()) await File(dbPath).delete();
      await File(tempPath).rename(dbPath);

      await _deleteDbSidecars(dbPath);

      // Re-initialize through the singleton — runs migrations if needed
      final db = await DatabaseHelper().reinitialize();

      final integrity = await db.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw StateError('Restored database failed integrity_check');
      }
      restored = true;
    } catch (e) {
      // Drop a failed staging file; never leave it beside live.
      try {
        if (await File(tempPath).exists()) await File(tempPath).delete();
        await _deleteDbSidecars(tempPath);
      } catch (_) {}
      // Restore safety copy on failure
      try {
        await DatabaseHelper().close();
        if (await File(safetyPath).exists()) {
          await File(safetyPath).copy(dbPath);
          await _deleteDbSidecars(dbPath);
          await DatabaseHelper().reinitialize();
        }
      } catch (_) {}
      rethrow;
    } finally {
      // Clean up safety copy only on success.
      if (restored) {
        final safetyFile = File(safetyPath);
        if (await safetyFile.exists()) await safetyFile.delete();
      }
    }
  }

  /// Deletes the WAL/SHM/journal sidecars beside [dbPath], if any.
  Future<void> _deleteDbSidecars(String dbPath) async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final sidecar = File('$dbPath$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
  }

  /// Drops keys that are not columns of [table] so a foreign or newer
  /// backup file cannot crash the restore (or smuggle data) with unknown
  /// fields. Reads live schema once per table per restore.
  final Map<String, Set<String>> _restoreColumnCache = {};

  Future<Map<String, dynamic>> _stripUnknownColumns(
      Transaction txn, String table, Map<String, dynamic> row) async {
    var known = _restoreColumnCache[table];
    if (known == null) {
      final cols = await txn.rawQuery('PRAGMA table_info($table)');
      known = {for (final c in cols) (c['name'] as String).toLowerCase()};
      _restoreColumnCache[table] = known;
    }
    return {
      for (final e in row.entries)
        if (known.contains(e.key.toLowerCase())) e.key: e.value
    };
  }

  // Restore from JSON backup
  Future<void> _restoreFromJsonBackup(String backupPath) async {
    final jsonContent = await File(backupPath).readAsString();
    final backupData = jsonDecode(jsonContent) as Map<String, dynamic>;

    // Validate metadata version
    const supportedVersion = '1.0';
    final metadata = backupData['_metadata'] as Map<String, dynamic>?;
    if (metadata != null) {
      final backupVersion = metadata['version'] as String?;
      if (backupVersion != null && backupVersion != supportedVersion) {
        throw Exception(
          'Incompatible backup version: $backupVersion. '
          'This backup was created with a newer version of the app.',
        );
      }
    }

    final database = await DatabaseHelper().database;

    await database.transaction((txn) async {
      // Replace semantics: clear ALL restorable tables in reverse FK order
      // first, so a section missing from the file ends up empty (not merged
      // with pre-restore rows). Insert in FK-safe order below.
      for (final tableName in _restoreTableOrder.reversed) {
        await txn.delete(tableName);
      }

      // Restore in FK-safe order (parents before children)
      for (final tableName in _restoreTableOrder) {
        if (!backupData.containsKey(tableName)) continue;
        if (!_restorableTables.contains(tableName)) continue;
        final tableData = backupData[tableName] as List<dynamic>;
        for (final row in tableData) {
          await txn.insert(
            tableName,
            await _stripUnknownColumns(
                txn, tableName, row as Map<String, dynamic>),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      // Restore any allowlisted tables not in the ordered list.
      // Anything else in the file (users, _sync_*, audit_log,
      // _migration_log, unknown keys) is ignored, never written.
      for (final entry in backupData.entries) {
        if (entry.key.startsWith('_')) continue;
        if (_restoreTableOrder.contains(entry.key)) continue;
        if (!_restorableTables.contains(entry.key)) continue;
        final tableData = entry.value as List<dynamic>;
        for (final row in tableData) {
          await txn.insert(
            entry.key,
            await _stripUnknownColumns(
                txn, entry.key, row as Map<String, dynamic>),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
  }

  // Get list of available backups
  Future<List<BackupInfo>> getBackupList() async {
    final backupDir = await _getBackupDirectory();
    final directory = Directory(backupDir);

    if (!await directory.exists()) {
      return [];
    }

    final files = await directory.list().toList();
    final backups = <BackupInfo>[];

    for (final file in files) {
      if (file is File) {
        final fileName = basename(file.path);
        if (fileName.endsWith(_backupExtension) ||
            fileName.endsWith(_jsonExtension)) {
          final stat = await file.stat();
          final type = fileName.endsWith(_backupExtension)
              ? BackupType.database
              : BackupType.json;

          backups.add(BackupInfo(
            fileName: fileName,
            filePath: file.path,
            size: stat.size,
            createdAt: stat.modified,
            type: type,
          ));
        }
      }
    }

    backups.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return backups;
  }

  // Delete backup file
  Future<bool> deleteBackup(String backupPath) async {
    try {
      final file = File(backupPath);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Removes backups kept in this app's private backup directory only.
  /// Files downloaded, shared, or exported elsewhere are intentionally left
  /// untouched because the app no longer controls those copies.
  Future<void> deleteManagedBackups() async {
    final backupDir = Directory(await _getBackupDirectory());
    if (!await backupDir.exists()) return;

    await for (final entry in backupDir.list()) {
      if (entry is File &&
          (entry.path.endsWith(_backupExtension) ||
              entry.path.endsWith(_jsonExtension))) {
        await entry.delete();
      }
    }
  }

  // Share backup file
  Future<void> shareBackup(String backupPath) async {
    final file = File(backupPath);
    if (await file.exists()) {
      await SharePlus.instance.share(ShareParams(files: [XFile(backupPath)]));
    }
  }

  // Auto backup (scheduled)
  Future<void> performAutoBackup(Database database) async {
    final backups = await getBackupList();

    if (backups.isEmpty ||
        DateTime.now().difference(backups.first.createdAt).inDays >= 7) {
      await createBackup();
      await _cleanupOldBackups();
    }
  }

  // Clean up old backups
  Future<void> _cleanupOldBackups() async {
    final backups = await getBackupList();

    if (backups.length > 5) {
      final oldBackups = backups.skip(5);
      for (final backup in oldBackups) {
        await deleteBackup(backup.filePath);
      }
    }
  }

  // Import backup from external source
  Future<BackupResult> importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['invoicedb', 'json'],
      );

      if (result != null && result.files.isNotEmpty) {
        final filePath = result.files.first.path!;
        return await restoreBackup(backupPath: filePath);
      }

      return BackupResult(
        success: false,
        message: 'No file selected',
      );
    } catch (e) {
      return BackupResult(
        success: false,
        message: 'Import failed: ${e.toString()}',
      );
    }
  }

  // Download backup file to Downloads folder
  Future<BackupResult> downloadBackup(String backupPath) async {
    try {
      final file = File(backupPath);
      if (!await file.exists()) {
        return BackupResult(success: false, message: 'Backup file not found');
      }

      final downloadsDir = await _getDownloadsDirectory();
      final fileName = basename(backupPath);
      final newPath = join(downloadsDir.path, fileName);

      await file.copy(newPath);

      return BackupResult(
        success: true,
        message: 'Backup downloaded to Downloads folder',
        filePath: newPath,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      return BackupResult(
          success: false, message: 'Download failed: ${e.toString()}');
    }
  }

  // Verify backup integrity
  Future<bool> verifyBackup(String backupPath) async {
    try {
      final file = File(backupPath);
      if (!await file.exists()) return false;

      final extension = backupPath.split('.').last;

      if (extension == _backupExtension.replaceAll('.', '')) {
        // Manifest gate first (mismatch → invalid before touching live).
        if (!await verifyManifest(backupPath)) return false;
        await verifyTempDatabase(backupPath);
        return true;
      } else if (extension == _jsonExtension.replaceAll('.', '')) {
        final content = await file.readAsString();
        jsonDecode(content);
        return true;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  // Get backup directory
  Future<String> _getBackupDirectory() async {
    final appDir = await appDocumentsDirectorySafe();
    final backupDir = Directory(join(appDir.path, 'backups'));

    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }

    return backupDir.path;
  }

  Future<Directory> _getDownloadsDirectory() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) return dir;
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final path = (await getDownloadsDirectory())?.path ?? '';
      final dir = Directory(path);
      if (await dir.exists()) return dir;
    }

    return await appDocumentsDirectorySafe();
  }
}
