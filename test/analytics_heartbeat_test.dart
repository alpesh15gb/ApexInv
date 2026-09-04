import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:apexbooks/services/analytics/cloudflare_analytics_service.dart';

void main() {
  test('opted-out users produce zero network traffic', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });

    final result = await CloudflareAnalyticsService.maybeSendHeartbeat(
      consented: false,
      lastSentDay: null,
      client: client,
    );

    expect(result, isNull);
    expect(calls, 0);
  });

  test('already-sent-today produces zero network traffic', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);

    final result = await CloudflareAnalyticsService.maybeSendHeartbeat(
      consented: true,
      lastSentDay: today,
      client: client,
    );

    expect(result, today);
    expect(calls, 0);
  });

  test('failures are silent and report null', () async {
    final client = MockClient((_) async => http.Response('err', 500));

    // BackendServices is unconfigured in tests, so installation lookup
    // throws internally — must still resolve to null, never throw.
    final result = await CloudflareAnalyticsService.maybeSendHeartbeat(
      consented: true,
      lastSentDay: '2000-01-01',
      client: client,
    );

    expect(result, isNull);
  });
}
