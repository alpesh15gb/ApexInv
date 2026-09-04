import 'package:flutter/material.dart';

/// Standard primary action. Replaces ad-hoc `ElevatedButton` + primary
/// `styleFrom` mixes — one look for the main action on every screen.
class AppPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;
  final bool expanded;
  final bool loading;

  const AppPrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.expanded = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : (icon == null
            ? label
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [icon!, const SizedBox(width: 8), label],
              ));
    final button = FilledButton(
      onPressed: loading ? null : onPressed,
      child: child,
    );
    if (!expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

/// Standard secondary action (filters, secondary dialog actions).
class AppSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;

  const AppSecondaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return OutlinedButton(onPressed: onPressed, child: label);
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon!,
      label: label,
    );
  }
}

/// Standard destructive action. Error-red filled button; use for delete,
/// purge, and other irreversible actions (always behind a confirm dialog).
class AppDangerButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget label;
  final Widget? icon;

  const AppDangerButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: Theme.of(context).colorScheme.error,
      foregroundColor: Theme.of(context).colorScheme.onError,
    );
    if (icon == null) {
      return FilledButton(onPressed: onPressed, style: style, child: label);
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: icon!,
      label: label,
    );
  }
}
