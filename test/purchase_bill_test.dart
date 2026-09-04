import 'package:flutter_test/flutter_test.dart';
import 'package:apexbooks/models/purchase_bill.dart';

void main() {
  test('computed purchase bill items retain the supplied bill ID', () {
    final item = PurchaseBillItem.compute(
      id: 'item-1',
      purchaseBillId: 'bill-1',
      productName: 'Service',
      quantity: 1.5,
      rate: 10,
      taxRate: 0,
      discount: 0,
      interState: false,
    );

    expect(item.purchaseBillId, 'bill-1');
    expect(item.quantity, 1.5);
  });

  test('inclusive rates back tax out so totals match the typed amount', () {
    final exclusive = PurchaseBillItem.compute(
      id: 'item-ex',
      purchaseBillId: 'bill-1',
      productName: 'Goods',
      quantity: 1,
      rate: 100,
      taxRate: 18,
      discount: 0,
      interState: false,
    );
    final inclusive = PurchaseBillItem.compute(
      id: 'item-in',
      purchaseBillId: 'bill-1',
      productName: 'Goods',
      quantity: 1,
      rate: 118,
      taxRate: 18,
      discount: 0,
      interState: false,
      priceIncludesTax: true,
    );

    expect(exclusive.taxableValue, 100);
    expect(exclusive.amount, 118);
    expect(inclusive.priceIncludesTax, isTrue);
    expect(inclusive.taxableValue, closeTo(100, 0.001));
    expect(
        inclusive.igst + inclusive.cgst + inclusive.sgst, closeTo(18, 0.001));
    expect(inclusive.amount, closeTo(118, 0.001));
  });
}
