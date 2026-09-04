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
  // Hosted Razorpay checkout for license purchase/renewal. Override per
  // build/flavor when the live payment link exists.
  static const licenseBuyUrl = "https://apexbooks.in/buy";
  static const license = "MIT";
  static const description =
      "ApexBooks is a modern invoice and billing management app for freelancers and small businesses.";
}
