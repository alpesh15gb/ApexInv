import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/navigation/dashboard_destinations.dart';
import 'package:apexbooks/providers/industry_provider.dart';
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

void main() {
  test('destination ids are stable and unique', () {
    final ids = DashboardTab.values.map((tab) => tab.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(DashboardTab.dashboard.id, 0);
    expect(DashboardTab.moreMenu.id, 100);
  });

  test('fromId resolves every legacy id and aliases 12 to reports', () {
    for (final tab in DashboardTab.values) {
      expect(DashboardTab.fromId(tab.id), tab);
    }
    expect(DashboardTab.fromId(12), DashboardTab.reports);
    expect(DashboardTab.fromId(999), isNull);
  });

  test('sidebar order covers every destination exactly once', () {
    final ordered = dashboardSidebarOrder.toSet();
    expect(ordered.length, dashboardSidebarOrder.length);
    expect(
      ordered,
      containsAll(
          DashboardTab.values.where((tab) => tab != DashboardTab.moreMenu)),
    );
  });

  test('mobile targets are valid destinations', () {
    expect(mobileTabTargets.length, lessThanOrEqualTo(5));
    for (final tab in mobileTabTargets) {
      expect(DashboardTab.values, contains(tab));
    }
  });

  test('generic POS and sale-order flows stay out of jewellery mode', () {
    expect(DashboardTab.pos.industries, {IndustryProfile.retail});
    expect(DashboardTab.saleOrders.industries, {IndustryProfile.retail});
  });

  testWidgets('every destination has a non-empty localized label',
      (tester) async {
    await tester.pumpWidget(_wrap(
      Builder(builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        for (final tab in DashboardTab.values) {
          expect(tab.label(l10n).trim(), isNotEmpty,
              reason: '${tab.name} must have a label');
          expect(tab.sectionHeader(l10n)?.trim().isNotEmpty ?? true, isTrue);
        }
        return const SizedBox.shrink();
      }),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('registry icons resolve on all breakpoints', (tester) async {
    for (final size in [
      const Size(400, 800),
      const Size(768, 800),
      const Size(1440, 900),
    ]) {
      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      _setSurface(tester, size);
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          final l10n = AppLocalizations.of(context)!;
          return Wrap(
            children: [
              for (final tab in DashboardTab.values)
                Icon(tab.outlinedIcon, semanticLabel: tab.label(l10n)),
            ],
          );
        }),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'icons must lay out at $size');
    }
  });
}
