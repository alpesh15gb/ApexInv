import 'package:flutter/foundation.dart';

/// Analytics was removed during rebranding.
///
/// Keep this compatibility shim because older call sites/builds may still
/// reference the service, but deliberately perform no network work.
class CloudflareAnalyticsService {
  static Future<void> sendHeartbeat() async {
    if (kDebugMode) {
      debugPrint('Analytics heartbeat is disabled.');
    }
  }
}
