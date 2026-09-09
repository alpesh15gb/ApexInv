import 'package:apexbooks/models/metal_rate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy rate maps to both buyback and retail sell values', () {
    final rate = MetalRate.fromMap({
      'id': 'legacy',
      'metal': 'gold',
      'purity': '22K',
      'rate_per_gram': 5000.0,
      'effective_date': '2026-09-09',
    });

    expect(rate.sellRatePerGram, 5000);
    expect(rate.buyRatePerGram, 5000);
  });

  test('legacy rate wins over zero defaults from an old restore', () {
    final rate = MetalRate.fromMap({
      'id': 'legacy-zero-defaults',
      'metal': 'gold',
      'purity': '22K',
      'rate_per_gram': 5000.0,
      'sell_rate_per_gram': 0.0,
      'buy_rate_per_gram': 0.0,
      'effective_date': '2026-09-09',
    });

    expect(rate.sellRatePerGram, 5000);
    expect(rate.buyRatePerGram, 5000);
  });

  test('new rate serializes explicit buyback and sell values', () {
    final rate = MetalRate.create(
      metal: 'gold',
      purity: '22K',
      sellRatePerGram: 5200,
      buyRatePerGram: 4800,
      effectiveDate: DateTime(2026, 9, 9),
    );

    final map = rate.toMap();
    expect(map['sell_rate_per_gram'], 5200);
    expect(map['buy_rate_per_gram'], 4800);
    expect(map['rate_per_gram'], 5200);
  });

  test('buyback rate cannot exceed the retail sell rate', () {
    expect(
      () => MetalRate.create(
        metal: 'gold',
        purity: '22K',
        sellRatePerGram: 4800,
        buyRatePerGram: 5200,
        effectiveDate: DateTime(2026, 9, 9),
      ),
      throwsArgumentError,
    );
  });
}
