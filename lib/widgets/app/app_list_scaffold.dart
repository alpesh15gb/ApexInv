import 'package:flutter/material.dart';

import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/widgets/app/app_buttons.dart';
import 'package:apexbooks/widgets/app/app_card.dart';
import 'package:apexbooks/widgets/app/app_empty_state.dart';

/// Shared list-screen building blocks.
///
/// Screens keep only domain-specific row builders, filter definitions, and
/// callbacks. Chrome, responsive behavior, pagination, and async states stay
/// here so accounting lists cannot drift apart again.
enum AppListState { loading, error, empty, data }

class AppListStat {
  final String label;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color accent;

  const AppListStat({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });
}

class AppStatGrid extends StatelessWidget {
  final List<AppListStat> stats;

  const AppStatGrid({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppPadding.medium;
        const minCardWidth = 170.0;
        final perRow =
            (constraints.maxWidth + spacing) ~/ (minCardWidth + spacing);
        final columns = perRow.clamp(1, stats.length);
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final stat in stats) SizedBox(width: cardWidth, child: _card(context, stat)),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context, AppListStat stat) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(AppPadding.xlarge),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stat.label,
                    style: TextStyle(
                        fontSize: AppFontSize.xsmall,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: AppPadding.xxsmall),
                Text(stat.value,
                    style: const TextStyle(
                        fontSize: AppFontSize.xxxlarge,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(stat.subtitle,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: stat.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
            ),
            child: Icon(stat.icon, color: stat.accent, size: 20),
          ),
        ],
      ),
    );
  }
}

class AppListHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final Widget? compactActions;

  const AppListHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.compactActions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppFontSize.xxlarge,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface)),
        const SizedBox(height: 2),
        Text(subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ],
    );

    if (context.isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleBlock,
          if (compactActions != null) ...[
            const SizedBox(height: AppPadding.medium),
            compactActions!,
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: titleBlock),
        if (actions.isNotEmpty)
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ),
      ],
    );
  }
}

class AppListFilterCard extends StatelessWidget {
  final Widget child;

  const AppListFilterCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppPadding.medium),
      child: child,
    );
  }
}

class AppTableHeader extends StatelessWidget {
  final List<Widget> children;
  final Widget? leading;

  const AppTableHeader({super.key, this.leading, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppBorderRadius.small),
          topRight: Radius.circular(AppBorderRadius.small),
        ),
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppPadding.xsmall, vertical: AppPadding.xxxsmall),
      child: Row(
        children: [
          if (leading != null) leading!,
          ...children,
        ],
      ),
    );
  }
}

class AppTableSelection extends StatelessWidget {
  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final double width;

  const AppTableSelection({
    super.key,
    required this.value,
    this.tristate = false,
    this.onChanged,
    this.width = 44,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Checkbox(
        value: value,
        tristate: tristate,
        onChanged: onChanged,
        activeColor: scheme.primary,
        checkColor: scheme.onPrimary,
        side: BorderSide(color: scheme.outline, width: 2),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class AppSortHeaderLabel extends StatelessWidget {
  final String label;
  final bool active;
  final bool ascending;
  final VoidCallback onTap;

  const AppSortHeaderLabel({
    super.key,
    required this.label,
    required this.active,
    required this.ascending,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: color)),
          ),
          const SizedBox(width: 2),
          Icon(
            !active
                ? Icons.unfold_more
                : (ascending ? Icons.arrow_upward : Icons.arrow_downward),
            size: 13,
            color: color,
          ),
        ],
      ),
    );
  }
}

class AppTableHeaderLabel extends StatelessWidget {
  final String label;
  final int flex;
  final double? width;

  const AppTableHeaderLabel(this.label, {super.key, this.flex = 2, this.width});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );
    final child = Text(label,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (width != null) return SizedBox(width: width, child: child);
    return Expanded(flex: flex, child: child);
  }
}

class AppPagination extends StatelessWidget {
  final Widget? leading;
  final String showingLabel;
  final String? rowsPerPageLabel;
  final int? pageSize;
  final ValueChanged<int>? onPageSizeChanged;
  final int currentPage;
  final int totalPages;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String previousLabel;
  final String nextLabel;
  final Widget pageIndicator;

  const AppPagination({
    super.key,
    this.leading,
    required this.showingLabel,
    this.rowsPerPageLabel,
    this.pageSize,
    this.onPageSizeChanged,
    required this.currentPage,
    required this.totalPages,
    required this.onPrevious,
    required this.onNext,
    required this.previousLabel,
    required this.nextLabel,
    required this.pageIndicator,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppPadding.xlarge, vertical: AppPadding.xsmall),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: AppPadding.medium),
            ],
            Text(showingLabel,
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(width: AppPadding.xxxlarge + 6),
            if (rowsPerPageLabel != null &&
                pageSize != null &&
                onPageSizeChanged != null) ...[
              Text(rowsPerPageLabel!,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
              const SizedBox(width: AppPadding.xsmall),
              DropdownButton<int>(
                value: pageSize,
                underline: const SizedBox(),
                items: const [10, 25, 50, 100]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (n) {
                  if (n != null) onPageSizeChanged!(n);
                },
              ),
              const SizedBox(width: AppPadding.medium),
            ],
            AppSecondaryButton(
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left, size: 18),
              label: Text(previousLabel),
            ),
            const SizedBox(width: AppPadding.medium),
            pageIndicator,
            const SizedBox(width: AppPadding.medium),
            AppSecondaryButton(
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right, size: 18),
              label: Text(nextLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class AppPageIndicator extends StatelessWidget {
  final int currentPage;
  final int totalPages;

  const AppPageIndicator(
      {super.key, required this.currentPage, required this.totalPages});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppPadding.medium, vertical: AppPadding.xxxsmall),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.xsmall),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
      ),
      child: Text('${currentPage + 1} / ${totalPages > 0 ? totalPages : 1}',
          style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: scheme.primary)),
    );
  }
}

class AppListStateView extends StatelessWidget {
  final AppListState state;
  final String? errorMessage;
  final String retryLabel;
  final VoidCallback? onRetry;
  final Widget emptyState;
  final Widget data;
  final double minHeight;

  const AppListStateView({
    super.key,
    required this.state,
    this.errorMessage,
    this.retryLabel = 'Retry',
    this.onRetry,
    required this.emptyState,
    required this.data,
    this.minHeight = 240,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (state) {
      case AppListState.loading:
        return SizedBox(height: minHeight, child: const AppLoadingState());
      case AppListState.error:
        return SizedBox(
          height: minHeight,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppPadding.xlarge),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 40, color: scheme.error),
                  const SizedBox(height: AppPadding.xsmall),
                  Text(errorMessage ?? 'Something went wrong',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  if (onRetry != null) ...[
                    const SizedBox(height: AppPadding.medium),
                    AppSecondaryButton(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(retryLabel),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      case AppListState.empty:
        return SizedBox(height: minHeight, child: emptyState);
      case AppListState.data:
        return data;
    }
  }
}
