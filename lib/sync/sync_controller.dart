import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/repositories/installation_repository.dart';
import 'package:apexbooks/repositories/settings_repository.dart';
import 'package:apexbooks/sync/api_sync_transport.dart';
import 'package:apexbooks/sync/sync_account.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_outbox.dart';
import 'package:apexbooks/utils/app_logger.dart';

const _tag = 'SyncController';

/// Default deployment base URL; overridable at build time for staging:
/// --dart-define=API_BASE_URL=https://api.apexbooks.in
const _kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api.apexbooks.in',
);

const _kSettingsKey = SettingKey.cloudSyncAccount;

/// Observable sync status for the Settings UI.
class SyncStatusState {
  final SyncCycleStatus cycle;
  final String? error;
  final int pendingOps;
  final DateTime? lastSyncAt;

  const SyncStatusState({
    this.cycle = SyncCycleStatus.idle,
    this.error,
    this.pendingOps = 0,
    this.lastSyncAt,
  });

  SyncStatusState copyWith({
    SyncCycleStatus? cycle,
    String? error,
    int? pendingOps,
    DateTime? lastSyncAt,
  }) =>
      SyncStatusState(
        cycle: cycle ?? this.cycle,
        error: error,
        pendingOps: pendingOps ?? this.pendingOps,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );
}

/// Owns the process-wide sync wiring: account persistence, transport, engine,
/// status stream. Constructed through [SyncControllerProvider]; call
/// [SyncController.init] once from main().
class SyncController {
  SyncController._({
    required this.settings,
    required this.installation,
  });

  static SyncController? _instance;

  static SyncController get instance =>
      _instance ?? (throw StateError('SyncController.init() was never called'));

  final SettingsRepository settings;
  final InstallationRepository installation;

  Database? _db;
  Future<Database>? _dbFuture;
  SyncEngine? _engine;
  SyncAccount? _account;

  /// Latest cycle result (null until first cycle); listened by the provider.
  final _status = StreamController<SyncStatusState>.broadcast();
  Stream<SyncStatusState> get statusStream => _status.stream;
  SyncStatusState status = const SyncStatusState();

  /// Api base the transport points at (exposed for the settings screen).
  static String get apiBaseUrl => _kApiBaseUrl;

  SyncEngine? get engineIfLinked => _engine;

  /// Creates the controller, restores any persisted account, and installs the
  /// singleton. Safe to call multiple times (subsequent calls are no-ops).
  static Future<void> init({
    required SettingsRepository settings,
    required InstallationRepository installation,
  }) async {
    if (_instance != null) return;
    final ctrl = SyncController._(
      settings: settings,
      installation: installation,
    );
    _instance = ctrl;
    await ctrl._restore();
  }

  Future<void> _restore() async {
    final raw = await settings.getSetting(_kSettingsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final account = SyncAccount.fromJson(json);
      if (account != null && account.companyId.isNotEmpty) {
        await _activate(account);
      }
    } catch (e) {
      AppLogger.e(_tag, 'Failed to restore sync account', e);
    }
  }

  Future<Database> _database() async => _db ??=
      await (_dbFuture ??= DatabaseHelper().database.then((db) => _db = db));

  Future<void> _activate(SyncAccount account) async {
    _account = account;
    ApiSyncTransport.deviceId = await _resolveDeviceId();
    final transport = ApiSyncTransport(
      baseUrl: _kApiBaseUrl,
      tokenProvider: () async => _account?.token,
    );
    // The engine wants a synchronous accessor; resolve the (single) open
    // future up front so every engine call lands on the same instance.
    final db = await _database();
    final engine = SyncEngine(dbAccessor: () => db, transport: transport);
    _engine = engine;
    engine.startPullTimer();
    engine.startOutboxWatcher();
    _watchConnectivity();
    _emit(status = status.copyWith(cycle: SyncCycleStatus.idle));
    // Sync-on-start (dbplan Phase 2 trigger #1): drain anything queued while
    // the app was closed and pick up remote changes immediately.
    unawaited(_syncInBackground());
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _wasOffline = false;

  /// Sync-on-connectivity-regain (dbplan Phase 2 trigger #3): the first
  /// transition from offline → any network fires one cycle. Desktop NICs
  /// flap rarely; the wasOffline latch keeps it to one cycle per outage.
  void _watchConnectivity() {
    _connectivitySub ??=
        Connectivity().onConnectivityChanged.listen((results) async {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _wasOffline) {
        _wasOffline = false;
        AppLogger.d(_tag, 'Connectivity regained — syncing');
        await _syncInBackground();
      } else if (!online) {
        _wasOffline = true;
      }
    });
  }

  /// Fire-and-forget cycle + status/pending refresh (no error propagation —
  /// background triggers surface through the status stream instead).
  Future<void> _syncInBackground() async {
    try {
      final engine = _engine;
      if (engine == null) return;
      final result = await engine.syncNow();
      final pending = await SyncOutbox(await _database()).pendingCount();
      _emit(SyncStatusState(
        cycle: result.status,
        error: result.error,
        pendingOps: pending,
        lastSyncAt: result.status == SyncCycleStatus.ok
            ? DateTime.now()
            : status.lastSyncAt,
      ));
    } catch (e) {
      AppLogger.e(_tag, 'Background sync failed', e);
    }
  }

  Future<String> _resolveDeviceId() async {
    try {
      final existing = await installation.getOrCreateInstallationId();
      if (existing.isNotEmpty && existing.length >= 12) {
        return 'dev-${existing.substring(0, 12)}';
      }
    } catch (_) {}
    return 'device-unknown';
  }

  void _emit(SyncStatusState s) {
    status = s;
    if (!_status.isClosed) _status.add(s);
  }

  // ── Account lifecycle (called from the Settings screen) ─────────────

  SyncAccount? get account => _account;

  bool get isLinked => _account != null && _account!.companyId.isNotEmpty;

  /// Register + create company + baseline. [companyName] is the cloud
  /// mirror of this device's books.
  Future<String?> registerAndLink(
      String email, String password, String companyName) async {
    final client = SyncAccountClient(baseUrl: _kApiBaseUrl);
    final res = await client.register(email, password, companyName);
    final account = res.account;
    if (account == null) return res.error ?? 'Registration failed';
    return _linkAndBaseline(account);
  }

  /// Login + link. When the account has no company yet the caller prompts
  /// for a name and follows up with [createCompanyAndLink].
  Future<String?> loginAndLink(String email, String password) async {
    final client = SyncAccountClient(baseUrl: _kApiBaseUrl);
    final res = await client.login(email, password);
    final account = res.account;
    if (account == null) return res.error ?? 'Login failed';
    if (account.companyId.isEmpty) {
      await _persist(account);
      _account = account;
      return null; // caller shows the company-name step
    }
    return _linkAndBaseline(account);
  }

  Future<String?> createCompanyAndLink(String companyName) async {
    final account = _account;
    if (account == null || account.companyId.isNotEmpty) {
      return 'Already linked';
    }
    final client = SyncAccountClient(baseUrl: _kApiBaseUrl);
    final res = await client.createCompany(account, companyName);
    final updated = res.account;
    if (updated == null) return res.error ?? 'Company creation failed';
    return _linkAndBaseline(updated);
  }

  Future<String?> _linkAndBaseline(SyncAccount account) async {
    try {
      await _persist(account);
      await _activate(account);
      final db = await _database();
      final engine = _engine!;
      await engine.linkCompany(db, account.companyId);
      _emit(status.copyWith(lastSyncAt: DateTime.now()));
      return null;
    } catch (e, stack) {
      AppLogger.e(_tag, 'Link failed', e, stack);
      return 'Link failed: $e';
    }
  }

  Future<void> _persist(SyncAccount account) async {
    await settings.setSetting(_kSettingsKey, jsonEncode(account.toJson()));
  }

  /// Unlinks and disables sync. Server data is kept (it is the cross-device
  /// source of truth); only this device stops syncing.
  Future<void> unlink() async {
    _engine?.stopTimers();
    _engine = null;
    _account = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _wasOffline = false;
    await settings.setSetting(_kSettingsKey, '');
    _emit(const SyncStatusState());
  }

  /// Manual "Sync now" — returns an error string or null on success.
  Future<String?> syncNow() async {
    final engine = _engine;
    if (engine == null) return 'Not linked';
    _emit(status.copyWith(cycle: SyncCycleStatus.syncing));
    final result = await engine.syncNow();
    final pending = await SyncOutbox(await _database()).pendingCount();
    _emit(SyncStatusState(
      cycle: result.status,
      error: result.error,
      pendingOps: pending,
      lastSyncAt: result.status == SyncCycleStatus.ok
          ? DateTime.now()
          : status.lastSyncAt,
    ));
    return result.status == SyncCycleStatus.error ? result.error : null;
  }

  /// Refresh pending-op count without running a cycle (e.g. after a write).
  Future<void> refreshPending() async {
    if (_engine == null) return;
    try {
      final pending = await SyncOutbox(await _database()).pendingCount();
      _emit(status.copyWith(pendingOps: pending));
    } catch (_) {}
  }
}

/// Riverpod façade over the singleton, for the Settings screen.
final syncStatusProvider = StreamProvider<SyncStatusState>((ref) {
  return SyncController.instance.statusStream;
});
