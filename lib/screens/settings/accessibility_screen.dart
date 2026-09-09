import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/widgets/app/app.dart';

class AccessibilityScreen extends ConsumerStatefulWidget {
  const AccessibilityScreen({super.key});

  @override
  ConsumerState<AccessibilityScreen> createState() =>
      _AccessibilityScreenState();
}

class _AccessibilityScreenState extends ConsumerState<AccessibilityScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? null
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      appBar: AppBar(
        title: Text(l10n.settingsNavAccessibilityLabel),
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
                  AppCard(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
                                        borderRadius: BorderRadius.circular(6),
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
                                          style: const TextStyle(fontSize: 13)),
                                    ),
                                  ],
                                ),
                              ))
                          .toList(),
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
