import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_transport.dart';

/// Server refused the credentials (401). The UI maps this to
/// "session expired — sign in again" rather than a raw error.
class SyncAuthException implements Exception {
  const SyncAuthException();
  @override
  String toString() => 'Session expired';
}

/// Non-401 server failure (5xx, malformed response, network layer).
class SyncServerException implements Exception {
  final String message;
  const SyncServerException(this.message);
  @override
  String toString() => message;
}

/// Transport impl for the self-hosted Apex Books sync server (server/ in this
/// repo — Go + Postgres behind nginx on api.apexbooks.in).
///
/// Maps the engine's SyncOp stream onto the server's contract:
///   push  → POST /sync/push/{companyId} {deviceId, ops[]}
///           → {serverTime, rejectedPks, correctedFields}
///   pull  → POST /sync/pull/{companyId} {table, cursor}
///           → {ops[], nextCursor, hasMore}
///
/// Timestamps travel as RFC3339 strings on the wire; the server clamps future
/// client stamps (clock-skew guard) and stamps server_updated_at itself, so
/// local clock quality only affects local LWW ordering.
class ApiSyncTransport implements SyncTransport {
  ApiSyncTransport({
    required this.baseUrl,
    required this.tokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() tokenProvider;
  final http.Client _client;

  // ── SyncTransport ───────────────────────────────────────────────────

  @override
  Future<SyncPushReceipt> push(String companyId, List<SyncOp> ops) async {
    final out = <Map<String, dynamic>>[
      for (final op in ops)
        {
          'table': op.tableName,
          'rowPk': op.rowPk,
          'op': op.op,
          'changedAt': op.changedAt.toUtc().toIso8601String(),
          if (op.payload != null) 'payload': op.payload,
        },
    ];
    final json = await _send('POST', '/sync/push/$companyId', {
      'deviceId': deviceId,
      'ops': out,
    });
    return SyncPushReceipt(
      serverTime: (json['serverTime'] ?? '').toString(),
      rejectedPks: _stringSet(json['rejectedPks']),
      correctedFields: _stringMap(json['correctedFields']),
    );
  }

  @override
  Future<SyncPullPage> pull(
      String companyId, String tableName, String cursor) async {
    final json = await _send('POST', '/sync/pull/$companyId', {
      'table': tableName,
      'cursor': cursor,
    });
    final opsJson = (json['ops'] as List?) ?? const [];
    final ops = <SyncOp>[];
    for (final raw in opsJson) {
      final m = raw as Map<String, dynamic>;
      Map<String, dynamic>? payload;
      final rawPayload = m['payload'];
      if (rawPayload is Map) {
        // Server rows carry the wire payload only; the engine re-adds its
        // own bookkeeping columns on apply (sync_engine._applyRemoteOp).
        payload = Map<String, dynamic>.from(rawPayload);
      }
      ops.add(SyncOp(
        tableName: tableName,
        rowPk: (m['rowPk'] ?? '').toString(),
        op: (m['op'] ?? 'update').toString(),
        changedAt: DateTime.parse(m['changedAt'] as String),
        lwwAt: m['lwwAt'] == null
            ? null
            : DateTime.tryParse(m['lwwAt'] as String),
        payload: payload,
      ));
    }
    return SyncPullPage(
      ops: ops,
      nextCursor: (json['nextCursor'] ?? '').toString(),
      hasMore: json['hasMore'] == true,
    );
  }

  @override
  Future<bool> companyHasData(String companyId) async {
    final json = await _send('GET', '/sync/has-data/$companyId', null);
    return json['hasData'] == true;
  }

  // ── Low-level helpers ───────────────────────────────────────────────

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final token = await tokenProvider();
    final uri = Uri.parse('$baseUrl$path');
    final req = http.Request(method, uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${token ?? ''}'
      ..body = body == null ? '' : jsonEncode(body);

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } catch (e) {
      throw SyncServerException('Cannot reach sync server: $e');
    }
    final text = await res.stream.bytesToString();
    if (res.statusCode == 401) {
      throw const SyncAuthException();
    }
    if (res.statusCode >= 400) {
      throw SyncServerException(
          'HTTP ${res.statusCode} from $path: ${_truncate(text)}');
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw SyncServerException('Unexpected response from $path');
  }

  static String _truncate(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';

  static Set<String> _stringSet(dynamic v) => v is List
      ? {for (final e in v) e.toString()}
      : const {};

  static Map<String, String> _stringMap(dynamic v) => v is Map
      ? {for (final e in v.entries) e.key.toString(): e.value.toString()}
      : const {};

  /// Stable per-installation device id; used only for diagnostics
  /// (origin_device on the server). Assigned by the sync controller at init.
  static String deviceId = 'device-unknown';
}
