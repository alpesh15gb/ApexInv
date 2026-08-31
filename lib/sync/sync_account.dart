import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Cloud-account session for the self-hosted sync server: email + token +
/// linked company, persisted by the sync controller so the app relinks
/// silently on next launch.
class SyncAccount {
  final String email;
  final String token;
  final String companyId;
  final String companyName;

  const SyncAccount({
    required this.email,
    required this.token,
    required this.companyId,
    required this.companyName,
  });

  Map<String, dynamic> toJson() => {
        'email': email,
        'token': token,
        'companyId': companyId,
        'companyName': companyName,
      };

  static SyncAccount? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final email = json['email']?.toString();
    final token = json['token']?.toString();
    final companyId = json['companyId']?.toString();
    if (email == null || token == null || companyId == null) return null;
    return SyncAccount(
      email: email,
      token: token,
      companyId: companyId,
      companyName: json['companyName']?.toString() ?? '',
    );
  }
}

/// Result wrappers so the UI can show field-level errors without parsing.
class SyncAuthResult {
  final SyncAccount? account;
  final String? error;

  /// True when the failure was transport-level (offline / timeout) rather
  /// than a server rejection — the UI can suggest retrying.
  final bool isNetwork;

  const SyncAuthResult.ok(this.account)
      : error = null,
        isNetwork = false;
  const SyncAuthResult.fail(this.error)
      : account = null,
        isNetwork = false;
  const SyncAuthResult.network(this.error)
      : account = null,
        isNetwork = true;
}

/// Server-side rejection with a message worth surfacing (409 email taken,
/// 401 bad credentials, 400 weak password…).
class SyncAuthHttpException implements Exception {
  final String message;
  final int statusCode;
  const SyncAuthHttpException(this.message, this.statusCode);
  @override
  String toString() => message;
}

/// Registers / logs into the sync server and resolves the linked company.
/// Deliberately separate from `ApiSyncTransport`: this is one-shot account
/// plumbing, that is the long-lived data plane.
class SyncAccountClient {
  SyncAccountClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Creates the account and its first company in one go.
  Future<SyncAuthResult> register(
      String email, String password, String companyName) async {
    try {
      final created = await _post('/auth/register', null, {
        'email': email,
        'password': password,
      });
      final token = created['token']?.toString();
      if (token == null) {
        return const SyncAuthResult.fail('Registration failed');
      }
      final company = await _post('/companies', token, {'name': companyName});
      final companyId = company['id']?.toString();
      if (companyId == null) {
        return const SyncAuthResult.fail('Company creation failed');
      }
      return SyncAuthResult.ok(SyncAccount(
        email: email,
        token: token,
        companyId: companyId,
        companyName: company['name']?.toString() ?? companyName,
      ));
    } on SyncAuthHttpException catch (e) {
      return SyncAuthResult.fail(e.message);
    } on TimeoutException {
      return const SyncAuthResult.network('Server timed out');
    } catch (e) {
      return SyncAuthResult.network('Cannot reach sync server: $e');
    }
  }

  /// Logs in and picks the first company. When the account has none, the
  /// returned account carries companyId == '' and the caller prompts for a
  /// company name, then calls [createCompany].
  Future<SyncAuthResult> login(String email, String password) async {
    try {
      final res = await _post('/auth/login', null, {
        'email': email,
        'password': password,
      });
      final token = res['token']?.toString();
      final user = res['user'] as Map<String, dynamic>?;
      if (token == null || user == null) {
        return const SyncAuthResult.fail('Login failed');
      }
      final emailOut = user['email']?.toString() ?? email;
      final companies = await _getList('/companies', token);
      if (companies.isEmpty) {
        return SyncAuthResult.ok(SyncAccount(
          email: emailOut,
          token: token,
          companyId: '',
          companyName: '',
        ));
      }
      final first = companies.first as Map<String, dynamic>;
      return SyncAuthResult.ok(SyncAccount(
        email: emailOut,
        token: token,
        companyId: first['id']?.toString() ?? '',
        companyName: first['name']?.toString() ?? '',
      ));
    } on SyncAuthHttpException catch (e) {
      return SyncAuthResult.fail(e.message);
    } on TimeoutException {
      return const SyncAuthResult.network('Server timed out');
    } catch (e) {
      return SyncAuthResult.network('Cannot reach sync server: $e');
    }
  }

  /// Creates a company for an account that has none (login with companyId ==
  /// ''). Returns the updated account.
  Future<SyncAuthResult> createCompany(
      SyncAccount account, String companyName) async {
    try {
      final company =
          await _post('/companies', account.token, {'name': companyName});
      final companyId = company['id']?.toString();
      if (companyId == null) {
        return const SyncAuthResult.fail('Company creation failed');
      }
      return SyncAuthResult.ok(SyncAccount(
        email: account.email,
        token: account.token,
        companyId: companyId,
        companyName: company['name']?.toString() ?? companyName,
      ));
    } on SyncAuthHttpException catch (e) {
      return SyncAuthResult.fail(e.message);
    } on TimeoutException {
      return const SyncAuthResult.network('Server timed out');
    } catch (e) {
      return SyncAuthResult.network('Cannot reach sync server: $e');
    }
  }

  // ── plumbing ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(
      String path, String? token, Map<String, dynamic> body) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl$path'),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _decodeMap(res, path);
  }

  Future<List<dynamic>> _getList(String path, String token) async {
    final res = await _client.get(
      Uri.parse('$baseUrl$path'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) throw _httpError(res);
    final decoded = jsonDecode(res.body);
    if (decoded is List) return decoded;
    throw SyncAuthHttpException('Unexpected response from $path', 0);
  }

  Future<Map<String, dynamic>> _decodeMap(
      http.Response res, String path) async {
    if (res.statusCode >= 400) throw _httpError(res);
    final decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw SyncAuthHttpException('Unexpected response from $path', 0);
  }

  SyncAuthHttpException _httpError(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      if (j is Map && j['error'] != null) {
        return SyncAuthHttpException(j['error'].toString(), res.statusCode);
      }
    } catch (_) {}
    return SyncAuthHttpException(
        'Server error (HTTP ${res.statusCode})', res.statusCode);
  }
}
