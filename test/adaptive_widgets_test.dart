import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/screens/more_menu_screen.dart';
import 'package:apexbooks/widgets/adaptive/adaptive_table.dart';
import 'package:apexbooks/widgets/adaptive/adaptive_field_grid.dart';
import 'package:apexbooks/widgets/adaptive/app_dialog.dart';
import 'package:apexbooks/widgets/adaptive/sticky_action_bar.dart';
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
    // Accent bar = 4px-wide positioned bar stretched between top/bottom.
    final accentBars = tester.widgetList<Positioned>(
      find.byWidgetPredicate(
        (w) => w is Positioned && w.width == 4 && w.top == 0 && w.bottom == 0,
      ),
    );
    expect(accentBars.length, 1);
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

  testWidgets('MoreMenuScreen routes destinations and logout', (tester) async {
    final selected = <int>[];
    var loggedOut = false;
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    _setSurface(tester, const Size(400, 800));
    await tester.pumpWidget(_wrap(
      MoreMenuScreen(
        user:
            User(id: '1', username: 'Tester', password: 'x', userType: 'admin'),
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

  testWidgets(
      'AdaptiveFieldGrid: single row on wide, 2-col grid on compact, '
      '1-col below 340', (tester) async {
    Widget grid() => AdaptiveFieldGrid(fields: [
          const TextField(decoration: InputDecoration(labelText: 'A')),
          const TextField(decoration: InputDecoration(labelText: 'B')),
          const TextField(decoration: InputDecoration(labelText: 'C')),
        ]);

    // Wide (medium test surface 800x600): one Row, all three fields share it.
    await tester.pumpWidget(
        _wrap(Scaffold(body: SingleChildScrollView(child: grid()))));
    final rowA = tester.getTopLeft(find.byType(TextField).at(0));
    final rowB = tester.getTopLeft(find.byType(TextField).at(1));
    expect(rowB.dy, rowA.dy, reason: 'wide: fields side by side');

    // Compact 400px: two columns — first two share a row, third wraps.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        _wrap(Scaffold(body: SingleChildScrollView(child: grid()))));
    await tester.pump();
    final colA = tester.getTopLeft(find.byType(TextField).at(0));
    final colB = tester.getTopLeft(find.byType(TextField).at(1));
    final colC = tester.getTopLeft(find.byType(TextField).at(2));
    expect(colB.dy, colA.dy, reason: 'compact 400: 2 columns');
    expect(colC.dy, greaterThan(colA.dy),
        reason: 'compact 400: third field wraps to row 2');

    // Extremely narrow 320px: one field per row.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 800);
    await tester.pumpWidget(
        _wrap(Scaffold(body: SingleChildScrollView(child: grid()))));
    await tester.pump();
    final nA = tester.getTopLeft(find.byType(TextField).at(0));
    final nB = tester.getTopLeft(find.byType(TextField).at(1));
    final nC = tester.getTopLeft(find.byType(TextField).at(2));
    expect(nB.dy, greaterThan(nA.dy), reason: '320: stacked');
    expect(nC.dy, greaterThan(nB.dy), reason: '320: stacked');
  });

  testWidgets('StickyActionBar renders child without overflow at 320px',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(
      Scaffold(
        body: Column(
          children: [
            const Spacer(),
            StickyActionBar(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.save),
                  label: const Text('Save settings'),
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Save settings'), findsOneWidget);
  });

  testWidgets(
      'Accented EntityCard inside a vertical ListView at 320px renders its '
      'content (regression: stretch accent bar blanked invoice cards)',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(
      Scaffold(
        body: ListView.builder(
          itemCount: 5,
          itemBuilder: (context, i) => EntityCard(
            key: ValueKey(i),
            accentColor: i.isEven ? Colors.green : Colors.red,
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('#INV-00${i + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Customer $i'),
                const SizedBox(height: 4),
                Text('Out: ${100 + i}.00'),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Real content assertions — the invoice card text must actually be on
    // screen and laid out with sane dimensions, not just "no exception".
    expect(find.text('#INV-001'), findsOneWidget);
    expect(find.text('#INV-002'), findsOneWidget);
    expect(find.text('Customer 0'), findsOneWidget);
    final cardRect = tester.getRect(find.text('#INV-001'));
    expect(cardRect.width, greaterThan(100),
        reason: 'invoice text must have usable width at 320px');
    expect(cardRect.height, greaterThan(0));
    // Scroll the last card into view — every record must be reachable.
    await tester.scrollUntilVisible(
      find.text('#INV-005'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('#INV-005'), findsOneWidget);
  });
}
