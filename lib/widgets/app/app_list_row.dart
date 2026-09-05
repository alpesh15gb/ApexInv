import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/widgets/app/app_card.dart';

/// Standard list row: leading icon/avatar, title + subtitle, trailing amount
/// and actions. Unifies the Card+ListTile / Card+InkWell-custom mixes used
/// across invoice, customer, product, bill, and order lists.
/// Display-only; tap and menu behavior comes from the caller.
class AppListRow extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const AppListRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: ListTile(
        dense: true,
        leading: leading,
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: AppFontSize.small + 1),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppFontSize.xsmall,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: trailing,
        onLongPress: onLongPress,
      ),
    );
  }
}

/// Standard leading badge for list rows: tinted circle with an icon,
/// replacing the hand-rolled CircleAvatar mixes.
class AppRowIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const AppRowIcon(this.icon, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).primaryColor;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: 0.12),
      ),
      child: Icon(icon, size: 20, color: c),
    );
  }
}

/// Standard section header for grouped content (settings sections,
/// report groups): small caps label.
class AppSectionHeader extends StatelessWidget {
  final String label;

  const AppSectionHeader(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
          bottom: AppPadding.xsmall, top: AppPadding.medium),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: AppFontSize.xsmall,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
