import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:apexbooks/widgets/app/app.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('AppMoney formats grouped amount with symbol', (tester) async {
    await tester.pumpWidget(_wrap(
      const AppMoney(1234567.5, currencySymbol: '₹'),
    ));
    expect(find.text('₹ 1,234,567.50'), findsOneWidget);
  });

  testWidgets('AppEmptyState renders icon, title, subtitle and action',
      (tester) async {
    await tester.pumpWidget(_wrap(
      AppEmptyState(
        icon: Icons.inbox_outlined,
        title: 'Nothing here',
        subtitle: 'Add your first record',
        action: TextButton(onPressed: () {}, child: const Text('Add')),
      ),
    ));
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Add your first record'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
  });

  testWidgets('AppPrimaryButton fires onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(
      AppPrimaryButton(
        onPressed: () => tapped = true,
        label: const Text('Save'),
      ),
    ));
    await tester.tap(find.text('Save'));
    expect(tapped, isTrue);
  });

  testWidgets('AppCard renders child content', (tester) async {
    await tester.pumpWidget(_wrap(
      const AppCard(child: Text('card body')),
    ));
    expect(find.text('card body'), findsOneWidget);
  });

  testWidgets('AppSearchField shows hint and clear action', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_wrap(
      AppSearchField(
        controller: controller,
        hintText: 'Search records',
        onClear: () {},
      ),
    ));
    expect(find.text('Search records'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    controller.dispose();
  });
}
