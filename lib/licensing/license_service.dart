import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Trial + license enforcement for the offline-first app.
///
/// Model (fixed-date founding trial):
/// - Free trial until [trialEndsAt] (5 May 2027 UTC), then a 15-day grace
///   period with full access, then read-only (view/print/export allowed,
///   creating new business documents blocked).
/// - A valid license key overrides the trial clock entirely.
/// - Clock rollback past the last-seen timestamp invalidates the *trial*
///   (a valid license key still unlocks); support can always issue a key.
///
/// Key format: `AB1.<base64url(payloadJson)>.<base64url(signature)>`,
/// signature = Ed25519(privateKey, utf8(payloadB64)). Payload:
/// `{"v":1,"plan":"pro","email":"…","seats":2,"iat":epoch,"exp":epoch|0}`
/// (`exp: 0` = perpetual). Verification is offline using the embedded
/// public key; issuance happens server-side (Razorpay webhook or the
/// authenticated /licenses/issue endpoint).
class LicenseService {
  LicenseService._();

  /// End of the free founding trial (UTC).
  static final DateTime trialEndsAt = DateTime.utc(2027, 5, 5);

  /// Full-access grace after trial/licence expiry before read-only.
  static const graceDays = 15;

  /// Tolerance for clock skew before the rollback guard trips.
  static const clockSkewTolerance = Duration(days: 1);

  /// Ed25519 public key for license verification. Verify-only: nothing
  /// secret here, and no key in the app can mint licenses.
  static const List<int> _publicKeyBytes = [
    190,
    174,
    21,
    45,
    106,
    154,
    8,
    62,
    68,
    191,
    146,
    194,
    193,
    146,
    204,
    51,
    38,
    51,
    201,
    184,
    96,
    12,
    42,
    158,
    180,
    81,
    124,
    85,
    88,
    63,
    94,
    170,
  ];

  /// Verifies [key] offline. Returns the license info on success, null on
  /// any failure (bad shape, bad signature, bad payload). Never throws.
  static Future<LicenseInfo?> verifyLicenseKey(String key) async {
    try {
      final parts = key.trim().split('.');
      if (parts.length != 3 || parts[0] != 'AB1') return null;
      final payloadB64 = parts[1];
      final payloadBytes = utf8.encode(payloadB64);
      final signatureBytes = base64Url.decode(_pad(parts[2]));
      final algorithm = Ed25519();
      final publicKey =
          SimplePublicKey(_publicKeyBytes, type: KeyPairType.ed25519);
      final valid = await algorithm.verify(
        payloadBytes,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
      if (!valid) return null;
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(_pad(payloadB64))))
              as Map<String, dynamic>;
      if (payload['v'] != 1) return null;
      return LicenseInfo(
        plan: payload['plan']?.toString() ?? 'pro',
        email: payload['email']?.toString() ?? '',
        seats: (payload['seats'] as num?)?.toInt() ?? 1,
        issuedAt: DateTime.fromMillisecondsSinceEpoch(
            ((payload['iat'] as num?)?.toInt() ?? 0) * 1000,
            isUtc: true),
        expiresAt: ((payload['exp'] as num?)?.toInt() ?? 0) == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (payload['exp'] as num).toInt() * 1000,
                isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }

  static String _pad(String s) {
    final rem = s.length % 4;
    return rem == 0 ? s : s + '=' * (4 - rem);
  }

  /// Computes the licensing state. Pure (testable): pass the current time,
  /// the stored key (or null), and the stored last-seen timestamp (or null).
  static Future<LicenseStatus> getStatus({
    required DateTime now,
    required String? licenseKey,
    required String? lastSeenIso,
  }) async {
    final utcNow = now.toUtc();
    DateTime? lastSeen =
        lastSeenIso == null ? null : DateTime.tryParse(lastSeenIso)?.toUtc();
    final clockRolledBack = lastSeen != null &&
        utcNow.isBefore(lastSeen.subtract(clockSkewTolerance));

    if (licenseKey != null && licenseKey.trim().isNotEmpty) {
      final info = await verifyLicenseKey(licenseKey);
      if (info != null) {
        if (info.expiresAt == null || utcNow.isBefore(info.expiresAt!)) {
          return LicenseStatus.licensed(info);
        }
        final graceEnd = info.expiresAt!.add(const Duration(days: graceDays));
        if (utcNow.isBefore(graceEnd)) {
          return LicenseStatus.grace(_daysLeft(utcNow, graceEnd), info);
        }
        return LicenseStatus.expiredReadOnly(info);
      }
      // Unverifiable key: fall through to trial rules (never hard-lock on
      // a corrupt stored value; the user can re-enter a key).
    }

    if (!clockRolledBack) {
      if (utcNow.isBefore(trialEndsAt)) {
        final daysLeft = _daysLeft(utcNow, trialEndsAt);
        return daysLeft <= 30
            ? LicenseStatus.trialExpiring(daysLeft)
            : LicenseStatus.trialActive(daysLeft);
      }
      final graceEnd = trialEndsAt.add(const Duration(days: graceDays));
      if (utcNow.isBefore(graceEnd)) {
        return LicenseStatus.grace(_daysLeft(utcNow, graceEnd), null);
      }
    }
    return const LicenseStatus.expiredReadOnly(null);
  }

  static int _daysLeft(DateTime from, DateTime to) =>
      to.difference(from).inDays.clamp(0, 100000);

  /// Whether new business documents may be created in [status].
  /// Read-only states still allow viewing, printing, exporting, and
  /// editing existing records — only *creation* is gated.
  static bool canCreateDocuments(LicenseStatus status) => !status.isReadOnly;

  /// UTC ISO timestamp the caller should persist after each check.
  static String stampNow(DateTime now) => now.toUtc().toIso8601String();
}

/// Verified license payload.
class LicenseInfo {
  final String plan;
  final String email;
  final int seats;
  final DateTime issuedAt;
  final DateTime? expiresAt; // null = perpetual

  const LicenseInfo({
    required this.plan,
    required this.email,
    required this.seats,
    required this.issuedAt,
    required this.expiresAt,
  });
}

/// Licensing state. Sealed by construction (private subtypes); inspect via
/// the public getters so callers and tests never depend on subtypes.
sealed class LicenseStatus {
  const LicenseStatus();
  const factory LicenseStatus.trialActive(int daysLeft) = _TrialActive;
  const factory LicenseStatus.trialExpiring(int daysLeft) = _TrialExpiring;
  const factory LicenseStatus.grace(int daysLeft, LicenseInfo? license) =
      _Grace;
  const factory LicenseStatus.licensed(LicenseInfo license) = _Licensed;
  const factory LicenseStatus.expiredReadOnly(LicenseInfo? license) =
      _ExpiredReadOnly;

  bool get isTrial => this is _TrialActive || this is _TrialExpiring;
  bool get isTrialExpiring => this is _TrialExpiring;
  bool get isGrace => this is _Grace;
  bool get isLicensed => this is _Licensed;
  bool get isReadOnly => this is _ExpiredReadOnly;

  /// Days remaining for trial/grace states, null for licensed/read-only.
  int? get daysLeft => switch (this) {
        _TrialActive(:var daysLeft) => daysLeft,
        _TrialExpiring(:var daysLeft) => daysLeft,
        _Grace(:var daysLeft) => daysLeft,
        _ => null,
      };

  LicenseInfo? get license => switch (this) {
        _Grace(:var license) => license,
        _Licensed(:var license) => license,
        _ExpiredReadOnly(:var license) => license,
        _ => null,
      };
}

class _TrialActive extends LicenseStatus {
  @override
  final int daysLeft;
  const _TrialActive(this.daysLeft);
}

class _TrialExpiring extends LicenseStatus {
  @override
  final int daysLeft;
  const _TrialExpiring(this.daysLeft);
}

class _Grace extends LicenseStatus {
  @override
  final int daysLeft;
  @override
  final LicenseInfo? license;
  const _Grace(this.daysLeft, this.license);
}

class _Licensed extends LicenseStatus {
  @override
  final LicenseInfo license;
  const _Licensed(this.license);
}

class _ExpiredReadOnly extends LicenseStatus {
  @override
  final LicenseInfo? license;
  const _ExpiredReadOnly(this.license);
}
