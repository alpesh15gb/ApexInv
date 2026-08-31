import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/providers/repositories.dart';

class AccessibilityScreen extends ConsumerStatefulWidget {
  const AccessibilityScreen({super.key});

  @override
  ConsumerState<AccessibilityScreen> createState() =>
      _AccessibilityScreenState();
}

class _AccessibilityScreenState extends ConsumerState<AccessibilityScreen> {
  String _createInvoiceLayout = 'v2';

  @override
  void initState() {
    super.initState();
    _loadCreateInvoiceLayout();
  }

  Future<void> _loadCreateInvoiceLayout() async {
    final layout = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.createInvoiceLayout);
    if (!mounted) return;
    setState(() => _createInvoiceLayout = layout ?? 'v2');
  }

  Future<void> _setCreateInvoiceLayout(String value) async {
    if (value == _createInvoiceLayout) return;
    await ref
        .read(settingsRepositoryProvider)
        .setSetting(SettingKey.createInvoiceLayout, value);
    if (!mounted) return;
    setState(() => _createInvoiceLayout = value);
  }

  Widget _layoutText(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            _createInvoiceLayout == 'v1'
                ? l10n.accessibilityClassicLayoutLabel
                : l10n.accessibilityNewLayoutLabel,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(l10n.accessibilityLayoutDescription,
            style: TextStyle(
                fontSize: AppFontSize.xsmall,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _layoutToggle(AppLocalizations l10n) {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(
            value: 'v2',
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(l10n.dashboardLayoutNew)),
        ButtonSegment(
            value: 'v1',
            icon: const Icon(Icons.history, size: 16),
            label: Text(l10n.dashboardLayoutClassic)),
      ],
      selected: {_createInvoiceLayout},
      onSelectionChanged: (selection) =>
          _setCreateInvoiceLayout(selection.first),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? null
          : Colors.grey[50],
      appBar: AppBar(
        title: Text(l10n.settingsNavAccessibilityLabel),
        backgroundColor:
            Theme.of(context).appBarTheme.backgroundColor ?? primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.accessibilityCreateInvoiceLayoutSectionTitle,
                    style: const TextStyle(
                        fontSize: AppFontSize.large,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                // Text(
                //   'Switching mid-edit discards any unsaved changes on the invoice form — save or finish the invoice first.',
                //   style: TextStyle(
                //       fontSize: AppFontSize.small,
                //       color: Theme.of(context).colorScheme.onSurfaceVariant),
                // ),
                const SizedBox(height: 16),
                Card(
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppBorderRadius.medium),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    // Compact: stack the toggle under the text so neither
                    // the description nor the SegmentedButton collapses.
                    child: context.isCompact
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _layoutText(l10n),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: _layoutToggle(l10n),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: _layoutText(l10n)),
                              const SizedBox(width: 16),
                              _layoutToggle(l10n),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                if (!Platform.isAndroid) ...[
                  Text(l10n.dashboardKeyboardShortcutsTitle,
                      style: const TextStyle(
                          fontSize: AppFontSize.large,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    l10n.accessibilityShortcutsSubtitle,
                    style: TextStyle(
                        fontSize: AppFontSize.small,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppBorderRadius.medium),
                      side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      child: Column(
                        children: AppShortcuts.all(context)
                            .map((s) => Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .outlineVariant),
                                        ),
                                        child: Text(s.$1,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Text(s.$2,
                                            style:
                                                const TextStyle(fontSize: 13)),
                                      ),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}
