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
}
