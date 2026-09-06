import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:apexbooks/licensing/license_api.dart';

void main() {
  test('retrieveKey returns the key on 200', () async {
    const key = 'AB1.payload.sig';
    final client = MockClient((req) async {
      expect(req.url.path, '/licenses/retrieve');
      expect(req.url.queryParameters['email'], 'buyer@x.com');
      expect(req.url.queryParameters['payment_id'], 'pay_123');
      return http.Response(jsonEncode({'key': key}), 200);
    });
    final got = await LicenseApi.retrieveKey(
      email: 'Buyer@X.com',
      paymentId: 'pay_123',
      baseUrl: 'https://api.example.test',
      client: client,
    );
    expect(got, key);
  });

  test('retrieveKey throws a friendly message on 404', () async {
    final client = MockClient((_) async => http.Response('{}', 404));
    expect(
      () => LicenseApi.retrieveKey(
        email: 'buyer@x.com',
        paymentId: 'pay_missing',
        baseUrl: 'https://api.example.test',
        client: client,
      ),
      throwsA(
        isA<LicenseRetrieveException>().having(
          (e) => e.message,
          'message',
          contains('No key found'),
        ),
      ),
    );
  });

  test('retrieveKey validates inputs before any HTTP call', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    await expectLater(
      () => LicenseApi.retrieveKey(
        email: 'not-an-email',
        paymentId: 'pay_1',
        baseUrl: 'https://api.example.test',
        client: client,
      ),
      throwsA(isA<LicenseRetrieveException>()),
    );
    await expectLater(
      () => LicenseApi.retrieveKey(
        email: 'buyer@x.com',
        paymentId: '  ',
        baseUrl: 'https://api.example.test',
        client: client,
      ),
      throwsA(isA<LicenseRetrieveException>()),
    );
    expect(called, isFalse);
  });
}
