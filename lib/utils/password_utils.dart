import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class PasswordUtils {
  /// PBKDF2-HMAC-SHA256 parameters for new hashes.
  static const int pbkdf2Iterations = 100000;
  static const int saltByteLength = 32;
  static const int keyByteLength = 32;

  /// Returns a SHA-256 hex hash of the given plain-text password.
  /// Kept for backward compatibility during migration (unsalted legacy).
  static String hash(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Generates a cryptographically secure random salt (32 bytes, base64url encoded).
  static String generateSalt() {
    final random = Random.secure();
    final bytes =
        List<int>.generate(saltByteLength, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Returns a PBKDF2-HMAC-SHA256 hash for storage.
  ///
  /// Uses [salt] (base64url, see [generateSalt]) and [pbkdf2Iterations],
  /// deriving a 32-byte key. Encoded as `$pbkdf2$iter$salt$key`.
  /// This replaces the legacy single-round HMAC-SHA256 (hex-64) format.
  static String hashWithSalt(String password, String salt,
      {int iterations = pbkdf2Iterations}) {
    final saltBytes = _decodeSaltBytes(salt);
    final key = _pbkdf2HmacSha256(
      utf8.encode(password),
      saltBytes,
      iterations,
      keyByteLength,
    );
    final keyB64 = base64Url.encode(key);
    return '\$pbkdf2\$$iterations\$$salt\$$keyB64';
  }

  /// Convenience: generates a fresh salt and returns a PBKDF2 hash string.
  static String hashPassword(String password,
      {int iterations = pbkdf2Iterations}) {
    return hashWithSalt(password, generateSalt(), iterations: iterations);
  }

  /// True when [storedHash] is in the new `$pbkdf2$` format.
  static bool isPbkdf2Hash(String? storedHash) {
    if (storedHash == null || storedHash.isEmpty) return false;
    return storedHash.startsWith('\$pbkdf2\$');
  }

  /// True when [storedHash] uses a legacy format (unsalted SHA-256 hex-64
  /// or single-round HMAC-SHA256 hex-64) and should be transparently
  /// re-hashed with the new KDF on next successful login.
  static bool needsUpgrade(String? storedHash) {
    if (storedHash == null || storedHash.isEmpty) return true;
    if (!storedHash.startsWith('\$pbkdf2\$')) return true;
    try {
      final parts = storedHash.split('\$');
      // ['', 'pbkdf2', iter, salt, key]
      if (parts.length != 5 || parts[1] != 'pbkdf2') return true;
      final iter = int.tryParse(parts[2]);
      if (iter == null) return true;
      if (iter != pbkdf2Iterations) return true;
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Verifies a password against a stored hash.
  ///
  /// Supports:
  /// - new `$pbkdf2$iter$salt$key` format (salt embedded, [salt] ignored),
  /// - legacy HMAC-SHA256 hex-64 when [salt] is provided,
  /// - legacy unsalted SHA-256 hex-64 when [salt] is null.
  /// Shape detection: `$pbkdf2$` prefix selects the new KDF; otherwise
  /// the presence of [salt] selects HMAC vs plain SHA-256.
  static bool verify(String password, String storedHash, String? salt) {
    if (storedHash.startsWith('\$pbkdf2\$')) {
      return _verifyPbkdf2(password, storedHash);
    }
    if (salt == null) {
      return hash(password) == storedHash;
    }
    return _legacyHmac(password, salt) == storedHash;
  }

  /// Legacy single-round HMAC-SHA256 (kept for verification only).
  static String _legacyHmac(String password, String salt) {
    final key = utf8.encode(salt);
    final message = utf8.encode(password);
    final hmac = Hmac(sha256, key);
    return hmac.convert(message).toString();
  }

  static bool _verifyPbkdf2(String password, String storedHash) {
    try {
      final parts = storedHash.split('\$');
      if (parts.length != 5 || parts[1] != 'pbkdf2') return false;
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations <= 0) return false;
      final saltB64 = parts[3];
      final keyB64 = parts[4];
      final saltBytes = _decodeSaltBytes(saltB64);
      final expectedKey = _decodeKeyBytes(keyB64);
      if (expectedKey.isEmpty) return false;
      final derived = _pbkdf2HmacSha256(
        utf8.encode(password),
        saltBytes,
        iterations,
        expectedKey.length,
      );
      return _constantTimeEquals(derived, expectedKey);
    } catch (_) {
      return false;
    }
  }

  static List<int> _decodeSaltBytes(String salt) {
    try {
      return base64Url.decode(base64Url.normalize(salt));
    } catch (_) {
      try {
        return base64Url.decode(salt);
      } catch (_) {
        return utf8.encode(salt);
      }
    }
  }

  static List<int> _decodeKeyBytes(String keyB64) {
    try {
      return base64Url.decode(base64Url.normalize(keyB64));
    } catch (_) {
      try {
        return base64Url.decode(keyB64);
      } catch (_) {
        return const [];
      }
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// PBKDF2-HMAC-SHA256 using package:crypto's [Hmac]/[sha256].
  static Uint8List _pbkdf2HmacSha256(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    const hLen = 32; // SHA-256 output length
    final blockCount = (keyLength + hLen - 1) ~/ hLen;
    final out = BytesBuilder();
    for (var block = 1; block <= blockCount; block++) {
      final blockBytes = Uint8List(4)
        ..buffer.asByteData().setUint32(0, block, Endian.big);
      final hmac = Hmac(sha256, password);
      var u = hmac.convert([...salt, ...blockBytes]).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    final derived = out.toBytes();
    return Uint8List.fromList(derived.sublist(0, keyLength));
  }
}
