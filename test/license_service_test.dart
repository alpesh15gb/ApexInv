import 'package:flutter_test/flutter_test.dart';

import 'package:apexbooks/licensing/license_service.dart';

// Test vector minted with the real license private key (payload:
// {"email":"test@example.com","exp":0,"iat":1756684800,"plan":"pro",
//  "seats":2,"v":1}).
const _validKey =
    'AB1.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJleHAiOjAsImlhdCI6MTc1NjY4NDgwMCwicGxhbiI6InBybyIsInNlYXRzIjoyLCJ2IjoxfQ.a9muJ6mjuV3Z0DQHEbtAUoiP6ZiAcJ8CY0f0fYs3_XOcA3M71PGG-QfxAvcoERhX0nHi1BYYnzhrPChXAhtRAg';

void main() {
  test('accepts a genuinely signed perpetual key', () async {
    final info = await LicenseService.verifyLicenseKey(_validKey);
    expect(info, isNotNull);
    expect(info!.plan, 'pro');
    expect(info.email, 'test@example.com');
    expect(info.seats, 2);
    expect(info.expiresAt, isNull);
  });

  test('rejects tampered, malformed, and foreign keys', () async {
    // Tampered payload (last char of payload segment flipped).
    final parts = _validKey.split('.');
    final tampered =
        'AB1.${parts[1].substring(0, parts[1].length - 1)}A.${parts[2]}';
    expect(await LicenseService.verifyLicenseKey(tampered), isNull);
    expect(await LicenseService.verifyLicenseKey(''), isNull);
    expect(await LicenseService.verifyLicenseKey('AB1.only.two'), isNull);
    expect(await LicenseService.verifyLicenseKey('XX1.${parts[1]}.${parts[2]}'),
        isNull);
  });

  test('trial is active far from expiry, expiring near it', () async {
    final active = await LicenseService.getStatus(
      now: DateTime.utc(2026, 9, 5),
      licenseKey: null,
      lastSeenIso: null,
    );
    expect(active.isTrial, isTrue);
    expect(active.isTrialExpiring, isFalse);
    expect(LicenseService.canCreateDocuments(active), isTrue);

    final expiring = await LicenseService.getStatus(
      now: DateTime.utc(2027, 4, 20),
      licenseKey: null,
      lastSeenIso: null,
    );
    expect(expiring.isTrialExpiring, isTrue);
    expect(expiring.daysLeft, 15);
  });

  test('post-trial grace then read-only; license overrides', () async {
    final grace = await LicenseService.getStatus(
      now: DateTime.utc(2027, 5, 10),
      licenseKey: null,
      lastSeenIso: null,
    );
    expect(grace.isGrace, isTrue);
    expect(LicenseService.canCreateDocuments(grace), isTrue);

    final expired = await LicenseService.getStatus(
      now: DateTime.utc(2027, 6, 1),
      licenseKey: null,
      lastSeenIso: null,
    );
    expect(expired.isReadOnly, isTrue);
    expect(LicenseService.canCreateDocuments(expired), isFalse);

    final licensed = await LicenseService.getStatus(
      now: DateTime.utc(2028, 1, 1),
      licenseKey: _validKey,
      lastSeenIso: null,
    );
    expect(licensed.isLicensed, isTrue);
    expect(licensed.license?.email, 'test@example.com');
    expect(LicenseService.canCreateDocuments(licensed), isTrue);
  });

  test('clock rollback kills the trial but not a valid license', () async {
    final rolled = await LicenseService.getStatus(
      now: DateTime.utc(2026, 9, 5),
      licenseKey: null,
      lastSeenIso: DateTime.utc(2026, 10, 1).toIso8601String(),
    );
    expect(rolled.isReadOnly, isTrue);

    final licensed = await LicenseService.getStatus(
      now: DateTime.utc(2026, 9, 5),
      licenseKey: _validKey,
      lastSeenIso: DateTime.utc(2026, 10, 1).toIso8601String(),
    );
    expect(licensed.isLicensed, isTrue);
  });
}
