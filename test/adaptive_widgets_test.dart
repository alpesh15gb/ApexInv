import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/screens/more_menu_screen.dart';
import 'package:apexbooks/widgets/adaptive/adaptive_table.dart';
import 'package:apexbooks/widgets/adaptive/app_dialog.dart';
import 'package:apexbooks/widgets/adaptive/entity_card.dart';
import 'package:apexbooks/widgets/adaptive/status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Row {
  final String name;
  final double total;
  _Row(this.name, this.total);
}

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

/// Sizes the test view so both MediaQuery and LayoutBuilder see [size].
/// (setSurfaceSize alone does not update MediaQuery.fromView.)
void _setSurface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  test('Breakpoints tier mapping', () {
    expect(Breakpoints.of(399), WindowSize.compact);
    expect(Breakpoints.of(700), WindowSize.medium);
    expect(Breakpoints.of(1023), WindowSize.medium);
    expect(Breakpoints.of(1024), WindowSize.expanded);
    expect(Breakpoints.isCompact(699), isTrue);
    expect(Breakpoints.isExpanded(1024), isTrue);
  });

  testWidgets('StatusChip renders its label', (tester) async {
    await tester.pumpWidget(_wrap(
      const Center(child: StatusChip(label: 'Paid', tone: StatusTone.success)),
    ));
    expect(find.text('Paid'), findsOneWidget);
  });

  testWidgets('EntityCard renders child and accent bar', (tester) async {
    await tester.pumpWidget(_wrap(
      Center(
        child: EntityCard(
          accentColor: Colors.red,
          onTap: () {},
          child: const Text('card body'),
        ),
      ),
    ));
    expect(find.text('card body'), findsOneWidget);
    final accentContainers = tester.widgetList<Container>(
      find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 4,
      ),
    );
    expect(accentContainers.length, 1);
  });

  testWidgets('AppDialog shows AlertDialog on medium/expanded windows',
      (tester) async {
    await tester.pumpWidget(_wrap(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AppDialog.show(
            context: context,
            title: 'Dialog title',
            content: const Text('Dialog body'),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    // Default test surface is 800x600 (medium tier).
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Dialog title'), findsOneWidget);
  });

  testWidgets('AppDialog becomes a bottom sheet on compact windows',
      (tester) async {
    // setSurfaceSize only sticks after an initial pump.
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(_wrap(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AppDialog.show(
            context: context,
            title: 'Dialog title',
            content: const Text('Dialog body'),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Dialog title'), findsOneWidget);
    expect(find.text('Dialog body'), findsOneWidget);
  });

  testWidgets('AdaptiveTable renders a table on expanded windows',
      (tester) async {
    _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(
        child: AdaptiveTable<_Row>(
          items: const [],
          columns: [],
          titleOf: (_) => '',
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AdaptiveTable: table header on medium, card list on compact',
      (tester) async {
    final rows = [_Row('Item A', 100), _Row('Item B', 250)];
    Widget table() => AdaptiveTable<_Row>(
          items: rows,
          columns: [
            AdaptiveColumn<_Row>(
              label: 'Name',
              build: (_, r) => Text(r.name),
              includeInCard: false,
            ),
            AdaptiveColumn<_Row>(
              label: 'Total',
              width: 100,
              build: (_, r) => Text(r.total.toStringAsFixed(0)),
              includeInCard: true,
            ),
          ],
          titleOf: (r) => r.name,
          subtitleOf: (_) => 'subtitle',
        );

    _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_wrap(SingleChildScrollView(child: table())));
    // Table mode: header labels visible, no EntityCard.
    expect(find.text('Name'), findsOneWidget);
    expect(find.byType(EntityCard), findsNothing);
    expect(find.text('Item A'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(_wrap(SingleChildScrollView(child: table())));
    await tester.pump();
    // Card mode: no header labels, EntityCard per row, meta line kept.
    expect(find.text('Name'), findsNothing);
    expect(find.byType(EntityCard), findsNWidgets(2));
    expect(find.text('Item B'), findsOneWidget);
    expect(find.text('250'), findsOneWidget);
  });

  testWidgets('MoreMenuScreen routes destinations and logout',
      (tester) async {
    final selected = <int>[];
    var loggedOut = false;
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(_wrap(
      MoreMenuScreen(
        user: User(
            id: '1', username: 'Tester', password: 'x', userType: 'admin'),
        hasUpdate: true,
        onSelectTab: selected.add,
        onLogout: () => loggedOut = true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('DOCUMENTS'), findsOneWidget);
    expect(find.text('ANALYTICS & DATA'), findsOneWidget);
    expect(find.text('PREFERENCES'), findsOneWidget);
    expect(find.text('Quotations'), findsOneWidget);
    expect(find.text('Expenses'), findsOneWidget);
    // Settings row carries the update dot indicator.
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.tap(find.text('Quotations'));
    await tester.tap(find.text('Expenses'));
    await tester.tap(find.text('Logout'));
    expect(selected, [3, 8]);
    expect(loggedOut, isTrue);
  });
}
