import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:apexbooks/sync/sync_account.dart';

void main() {
  test('purgeCompany posts owner confirmation to the linked company endpoint',
      () async {
    late http.Request request;
    final client = SyncAccountClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{}', 200);
      }),
    );
    const account = SyncAccount(
      email: 'owner@example.test',
      token: 'token-123',
      companyId: 'company-456',
      companyName: 'Example Co',
    );

    final error = await client.purgeCompany(
      account: account,
      companyName: 'Example Co',
      password: 'correct horse battery staple',
      retentionConfirmed: true,
    );

    expect(error, isNull);
    expect(request.method, 'POST');
    expect(request.url.path, '/privacy/purge/company/company-456');
    expect(request.headers['authorization'], 'Bearer token-123');
    expect(request.headers['content-type'], 'application/json');
    expect(jsonDecode(request.body), {
      'companyName': 'Example Co',
      'password': 'correct horse battery staple',
      'retentionConfirmed': true,
    });
  });

  test('purgeCompany returns the server rejection', () async {
    final client = SyncAccountClient(
      baseUrl: 'https://sync.example.test',
      client: MockClient(
          (_) async => http.Response('{"error":"Invalid password"}', 401)),
    );
    const account = SyncAccount(
      email: 'owner@example.test',
      token: 'token-123',
      companyId: 'company-456',
      companyName: 'Example Co',
    );

    final error = await client.purgeCompany(
      account: account,
      companyName: 'Example Co',
      password: 'wrong',
      retentionConfirmed: true,
    );

    expect(error, 'Invalid password');
  });
}
