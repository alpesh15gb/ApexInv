import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/services/backend_services.dart';

class CloudflareAnalyticsService {
  /// Anonymous usage heartbeat receiver. Points at the self-hosted sync API
  /// (same default as sync; overridable with --dart-define=ANALYTICS_BASE_URL).
  /// Previously pointed at app.apexbooks.in, which has no known receiver.
  static const _baseUrl = String.fromEnvironment(
    'ANALYTICS_BASE_URL',
    defaultValue: 'https://api.apexbooks.in',
  );
  static const _heartbeatUrl = '$_baseUrl/api/heartbeat';

  /// Sends one heartbeat. Fire-and-forget; never throws.
  static Future<void> sendHeartbeat({http.Client? client}) async {
    try {
      final installationId =
          await BackendServices.installation.getOrCreateInstallationId();

      final httpClient = client ?? http.Client();
      try {
        await httpClient
            .post(
              Uri.parse(_heartbeatUrl),
              headers: {
                "Content-Type": "application/json",
              },
              body: jsonEncode({
                "installationId": installationId,
                "platform": Platform.operatingSystem,
                "appVersion": AppConfig.version,
              }),
            )
            .timeout(const Duration(seconds: 5));
      } finally {
        if (client == null) httpClient.close();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("Analytics heartbeat failed: $e");
      }
    }
  }

  /// Consent + frequency gate. Returns the UTC day string (yyyy-MM-dd) the
  /// caller should persist when a ping went out, else null. Sends nothing
  /// unless [consented] is true and [lastSentDay] differs from today —
  /// opted-out (or never-asked) users produce zero network traffic.
  static Future<String?> maybeSendHeartbeat({
    required bool consented,
    required String? lastSentDay,
    http.Client? client,
    DateTime? now,
  }) async {
    if (!consented) return null;
    final day =
        (now ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10);
    if (lastSentDay == day) return day;
    try {
      final installationId =
          await BackendServices.installation.getOrCreateInstallationId();

      final httpClient = client ?? http.Client();
      try {
        final res = await httpClient
            .post(
              Uri.parse(_heartbeatUrl),
              headers: {
                "Content-Type": "application/json",
              },
              body: jsonEncode({
                "installationId": installationId,
                "platform": Platform.operatingSystem,
                "appVersion": AppConfig.version,
              }),
            )
            .timeout(const Duration(seconds: 5));
        if (res.statusCode >= 200 && res.statusCode < 300) return day;
        return null;
      } finally {
        if (client == null) httpClient.close();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint("Analytics heartbeat failed: $e");
      }
      return null;
    }
  }
}
