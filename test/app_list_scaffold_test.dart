import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/widgets/app/app_list_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void _setSurface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

const _stats = [
  AppListStat(
      label: 'Total',
      value: '12',
      subtitle: 'All records',
      icon: Icons.groups_outlined,
      accent: Colors.blue),
  AppListStat(
      label: 'Open',
      value: '3',
      subtitle: 'Needs attention',
      icon: Icons.warning_amber_rounded,
      accent: Colors.orange),
  AppListStat(
      label: 'Paid',
      value: '9',
      subtitle: 'Settled',
      icon: Icons.check_circle_outline,
      accent: Colors.green),
];

Widget _pagination() => AppPagination(
      showingLabel: 'Showing 1–3 of 3',
      rowsPerPageLabel: 'Rows per page',
      pageSize: 10,
      onPageSizeChanged: (_) {},
      currentPage: 0,
      totalPages: 1,
      onPrevious: null,
      onNext: () {},
      previousLabel: 'Previous',
      nextLabel: 'Next',
      pageIndicator: const AppPageIndicator(currentPage: 0, totalPages: 1),
    );

void main() {
  testWidgets('AppListHeader renders title, subtitle, and actions',
      (tester) async {
    await tester.pumpWidget(_wrap(
      AppListHeader(
        title: 'Parties',
        subtitle: 'Everyone you trade with',
        actions: [
          TextButton(onPressed: () {}, child: const Text('New')),
        ],
      ),
    ));
    expect(find.text('Parties'), findsOneWidget);
    expect(find.text('Everyone you trade with'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('AppStatGrid lays out without overflow at 400/768/1440',
      (tester) async {
    for (final size in [
      const Size(400, 800),
      const Size(768, 800),
      const Size(1440, 900),
    ]) {
      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      _setSurface(tester, size);
      await tester.pumpWidget(_wrap(
        const SingleChildScrollView(child: AppStatGrid(stats: _stats)),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'stat grid must lay out at $size');
      expect(find.text('Total'), findsOneWidget);
    }
  });

  testWidgets('AppPagination renders labels and indicator', (tester) async {
    await tester.pumpWidget(_wrap(_pagination()));
    expect(find.text('Showing 1–3 of 3'), findsOneWidget);
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
  });

  testWidgets('AppListStateView covers loading/error/empty/data',
      (tester) async {
    var retried = false;

    await tester.pumpWidget(_wrap(
      AppListStateView(
        state: AppListState.loading,
        emptyState: const Text('empty'),
        data: const Text('data'),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(_wrap(
      AppListStateView(
        state: AppListState.error,
        errorMessage: 'Load failed',
        onRetry: () => retried = true,
        emptyState: const Text('empty'),
        data: const Text('data'),
      ),
    ));
    expect(find.text('Load failed'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);

    await tester.pumpWidget(_wrap(
      const AppListStateView(
        state: AppListState.empty,
        emptyState: Text('empty'),
        data: Text('data'),
      ),
    ));
    expect(find.text('empty'), findsOneWidget);
    expect(find.text('data'), findsNothing);

    await tester.pumpWidget(_wrap(
      const AppListStateView(
        state: AppListState.data,
        emptyState: Text('empty'),
        data: Text('data'),
      ),
    ));
    expect(find.text('data'), findsOneWidget);
  });

  testWidgets('AppTableHeader renders selection and labels', (tester) async {
    var selected = false;
    await tester.pumpWidget(_wrap(
      StatefulBuilder(builder: (context, setState) {
        return AppTableHeader(
          leading: AppTableSelection(
            value: selected,
            onChanged: (value) => setState(() => selected = value ?? false),
          ),
          children: const [
            AppTableHeaderLabel('Name', flex: 3),
            AppTableHeaderLabel('Total'),
          ],
        );
      }),
    ));
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(selected, isTrue);
  });
}
