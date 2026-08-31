import 'package:flutter/material.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/widgets/adaptive/entity_card.dart';

/// One column of an [AdaptiveTable].
class AdaptiveColumn<T> {
  final String label;

  /// Fixed pixel width in table mode; when null the column flexes.
  final double? width;

  /// Flex used in table mode when [width] is null.
  final int flex;
  final Alignment alignment;
  final Widget Function(BuildContext context, T item) build;

  /// Whether the cell also appears as metadata inside the compact card.
  final bool includeInCard;

  const AdaptiveColumn({
    required this.label,
    required this.build,
    this.width,
    this.flex = 1,
    this.alignment = Alignment.centerLeft,
    this.includeInCard = false,
  });
}

/// Spec-driven entity list: a real table on medium/expanded windows and a
/// card list on compact phones, so screens describe their columns once.
class AdaptiveTable<T> extends StatelessWidget {
  final List<T> items;
  final List<AdaptiveColumn<T>> columns;
  final String Function(T item) titleOf;
  final String? Function(T item)? subtitleOf;
  final Widget? Function(T item)? trailingOf;
  final Color? Function(T item)? accentColorOf;
  final void Function(T item)? onTap;

  /// Toolbar rendered above both the table and the card list.
  final Widget? header;

  /// Shown instead of the list when [items] is empty.
  final Widget? empty;

  const AdaptiveTable({
    super.key,
    required this.items,
    required this.columns,
    required this.titleOf,
    this.subtitleOf,
    this.trailingOf,
    this.accentColorOf,
    this.onTap,
    this.header,
    this.empty,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return empty ?? const SizedBox.shrink();
    return ResponsiveBuilder(
      builder: (context, size) => size == WindowSize.compact
          ? _buildCardList(context)
          : _buildTable(context),
    );
  }

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outlineVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null) header!,
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            border: Border.all(color: outline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              for (final column in columns) _headerCell(context, column),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            border: Border(
              left: BorderSide(color: outline),
              right: BorderSide(color: outline),
              bottom: BorderSide(color: outline),
            ),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: outline),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onTap != null ? () => onTap!(items[i]) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          for (final column in columns)
                            _dataCell(context, column, items[i]),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerCell(BuildContext context, AdaptiveColumn<T> column) {
    final theme = Theme.of(context);
    final child = Text(
      column.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return _wrapCell(child, column);
  }

  Widget _dataCell(BuildContext context, AdaptiveColumn<T> column, T item) {
    return _wrapCell(column.build(context, item), column);
  }

  Widget _wrapCell(Widget child, AdaptiveColumn<T> column) {
    if (column.width != null) {
      return SizedBox(
        width: column.width,
        child: Align(alignment: column.alignment, child: child),
      );
    }
    return Expanded(
      flex: column.flex,
      child: Align(alignment: column.alignment, child: child),
    );
  }

  Widget _buildCardList(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null) header!,
        for (final item in items)
          EntityCard(
            accentColor: accentColorOf?.call(item),
            onTap: onTap != null ? () => onTap!(item) : null,
            child: () {
              final subtitle = subtitleOf?.call(item);
              final trailing = trailingOf?.call(item);
              final meta = [
                for (final column in columns)
                  if (column.includeInCard) column.build(context, item),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          titleOf(item),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (trailing != null) trailing,
                    ],
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 6, children: meta),
                  ],
                ],
              );
            }(),
          ),
      ],
    );
  }
}
