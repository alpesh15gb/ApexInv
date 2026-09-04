import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apexbooks/utils/password_utils.dart';

String legacyHmac(String password, String salt) {
  final hmac = Hmac(sha256, utf8.encode(salt));
  return hmac.convert(utf8.encode(password)).toString();
}

void main() {
  group('PasswordUtils PBKDF2', () {
    test('new hash uses \$pbkdf2\$100000 format and verifies', () {
      const password = 'CorrectHorse123!';
      final salt = PasswordUtils.generateSalt();
      final stored = PasswordUtils.hashWithSalt(password, salt);

      expect(stored.startsWith(r'$pbkdf2$100000$'), isTrue);
      // 32-byte salt + 32-byte key as base64url.
      final parts = stored.split(r'$');
      expect(parts.length, 5);
      expect(parts[1], 'pbkdf2');
      expect(parts[2], '100000');

      expect(PasswordUtils.verify(password, stored, salt), isTrue);
      // Salt param ignored for new format.
      expect(PasswordUtils.verify(password, stored, null), isTrue);
      expect(PasswordUtils.verify(password, stored, 'other'), isTrue);
      expect(PasswordUtils.verify('wrong', stored, salt), isFalse);
    });

    test('different salts produce different hashes', () {
      const password = 'same-password';
      final a =
          PasswordUtils.hashWithSalt(password, PasswordUtils.generateSalt());
      final b =
          PasswordUtils.hashWithSalt(password, PasswordUtils.generateSalt());
      expect(a, isNot(equals(b)));
      // Each verifies with its own embedded salt.
      expect(PasswordUtils.verify(password, a, null), isTrue);
      expect(PasswordUtils.verify(password, b, null), isTrue);
    });

    test('legacy unsalted SHA-256 still verifies and needs upgrade', () {
      const password = 'legacy-pass';
      final stored = PasswordUtils.hash(password);
      expect(stored.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(stored), isTrue);
      expect(PasswordUtils.verify(password, stored, null), isTrue);
      expect(PasswordUtils.verify('wrong', stored, null), isFalse);
      expect(PasswordUtils.needsUpgrade(stored), isTrue);
    });

    test('legacy HMAC still verifies and needs upgrade', () {
      const password = 'hmac-pass';
      final salt = PasswordUtils.generateSalt();
      final stored = legacyHmac(password, salt);
      expect(stored.length, 64);
      expect(PasswordUtils.verify(password, stored, salt), isTrue);
      expect(PasswordUtils.verify('wrong', stored, salt), isFalse);
      expect(PasswordUtils.needsUpgrade(stored), isTrue);
    });

    test('needsUpgrade false for new format', () {
      final stored = PasswordUtils.hashWithSalt(
          'fresh-pass', PasswordUtils.generateSalt());
      expect(PasswordUtils.needsUpgrade(stored), isFalse);
      expect(PasswordUtils.needsUpgrade(null), isTrue);
      expect(PasswordUtils.needsUpgrade(''), isTrue);
      expect(PasswordUtils.needsUpgrade('not-a-hash'), isTrue);
    });

    test('malformed pbkdf2 string fails closed', () {
      expect(PasswordUtils.verify('anything', r'$pbkdf2$bad$payload', null),
          isFalse);
      expect(PasswordUtils.needsUpgrade(r'$pbkdf2$bad$payload'), isTrue);
    });
  });
}
