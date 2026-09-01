import 'common.dart';

class SupportedCurrencies {
  static const List<CurrencyOption> all = [
    CurrencyOption(code: 'INR', symbol: '₹', name: 'Indian Rupee'),
  ];

  static CurrencyOption fromCode(String code) {
    return all.firstWhere(
      (c) => c.code == code,
      orElse: () => all.first,
    );
  }
}
