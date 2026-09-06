// app_config.dart
class AppConfig {
  static const kIsCloud = false;
  static const name = "Apex Books";
  static const version = "v1.0.0";
  static const developer = "ApexBooks";
  static const supportEmail = "support@apexbooks.in";
  static const supportForm = "https://apexbooks.in/support";
  static const website = "https://apexbooks.in";
  static const appUrl = "https://app.apexbooks.in";
  // Hosted Razorpay checkout for license purchase/renewal.
  //
  // TODO(live-payments): replace the fallback below with the LIVE Razorpay
  // Payment Link URL (Dashboard → Payment Links → Create), or override at
  // build time without editing code:
  //   --dart-define=LICENSE_BUY_URL=https://rzp.io/l/<live-link-id>
  // The License screen opens this URL in the external browser; after payment
  // the buyer returns to the app and uses "I already paid — retrieve key"
  // (GET /licenses/retrieve on the sync server) to fetch their key.
  // See server/README.md "License payments (Razorpay)" for the exact
  // dashboard steps and required server env vars.
  static const licenseBuyUrl = String.fromEnvironment(
    'LICENSE_BUY_URL',
    defaultValue: 'https://apexbooks.in/buy',
  );
  // Base URL of the sync server that also serves /licenses/*.
  // Override per build/flavor for staging:
  //   --dart-define=API_BASE_URL=https://api.apexbooks.in
  static const licenseApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.apexbooks.in',
  );
  static const license = "MIT";
  static const description =
      "ApexBooks is a modern invoice and billing management app for freelancers and small businesses.";
}
