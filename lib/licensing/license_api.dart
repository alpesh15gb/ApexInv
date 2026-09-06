import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:apexbooks/common/app_config.dart';

/// Client for the server-side license delivery endpoints
/// (same host as the sync API, see [AppConfig.licenseApiBaseUrl]).
///
/// - Buying happens in the external browser at [AppConfig.licenseBuyUrl]
///   (hosted Razorpay checkout / Payment Link).
/// - After payment, the buyer retrieves their key here with the purchase
///   email + Razorpay payment id; the key is then activated offline via
///   [LicenseService.verifyLicenseKey].
class LicenseApi {
  LicenseApi._();

  /// Fetches the issued key for ([email], [paymentId]).
  /// Returns the key string, or throws [LicenseRetrieveException] with a
  /// user-displayable message.
  static Future<String> retrieveKey({
    required String email,
    required String paymentId,
    String? baseUrl,
    String? installationId,
    http.Client? client,
  }) async {
    final e = email.trim().toLowerCase();
    final p = paymentId.trim();
    if (e.isEmpty || !e.contains('@')) {
      throw const LicenseRetrieveException('Enter the purchase email address');
    }
    if (p.isEmpty) {
      throw const LicenseRetrieveException('Enter the Razorpay payment id');
    }
    final base = (baseUrl ?? AppConfig.licenseApiBaseUrl).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final query = {
      'email': e,
      'payment_id': p,
      if ((installationId ?? '').trim().isNotEmpty)
        'installation_id': installationId!.trim(),
    };
    final uri = Uri.parse(
      '$base/licenses/retrieve',
    ).replace(queryParameters: query);
    final httpClient = client ?? http.Client();
    try {
      final res = await httpClient.get(uri, headers: {
        'Accept': 'application/json'
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final key = decoded is Map ? decoded['key']?.toString() : null;
        if (key != null && key.isNotEmpty) return key;
        throw const LicenseRetrieveException(
          'Server returned an empty key — contact support',
        );
      }
      if (res.statusCode == 404) {
        throw const LicenseRetrieveException(
          'No key found for that email + payment id yet. '
          'If you just paid, wait a minute and retry.',
        );
      }
      throw LicenseRetrieveException(
        'Key lookup failed (HTTP ${res.statusCode}) — retry or contact support',
      );
    } on LicenseRetrieveException {
      rethrow;
    } catch (e) {
      throw LicenseRetrieveException('Cannot reach license server: $e');
    } finally {
      if (client == null) httpClient.close();
    }
  }
}

/// User-displayable retrieval failure.
class LicenseRetrieveException implements Exception {
  final String message;
  const LicenseRetrieveException(this.message);
  @override
  String toString() => message;
}
