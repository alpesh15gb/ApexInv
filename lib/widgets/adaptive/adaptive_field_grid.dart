import 'package:flutter/material.dart';
import 'package:apexbooks/common/breakpoints.dart';

/// Form-field layout helper: a single Row of Expanded fields on medium and
/// expanded windows, a 2-column grid on compact phones. One field per row on
/// extremely narrow (<340px) windows. Prevents 3-4 field desktop rows from
/// crushing below usable width.
class AdaptiveFieldGrid extends StatelessWidget {
  final List<Widget> fields;
  final double gap;

  const AdaptiveFieldGrid({
    super.key,
    required this.fields,
    this.gap = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (fields.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= Breakpoints.compactMax) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(child: fields[i]),
              ],
            ],
          );
        }
        final columns = width < 340 ? 1 : 2;
        final fieldWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final field in fields)
              SizedBox(width: fieldWidth, child: field),
          ],
        );
      },
    );
  }
}
