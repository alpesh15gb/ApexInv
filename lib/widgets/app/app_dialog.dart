import 'package:flutter/material.dart';

import 'package:apexbooks/common/constants.dart';

/// Standard dialog action row: tertiary/cancel first (left), primary last
/// (right) — the order already used consistently across the app.
class AppDialogActions extends StatelessWidget {
  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback? onConfirm;
  final bool danger;
  final bool loading;

  const AppDialogActions({
    super.key,
    this.cancelLabel = 'Cancel',
    required this.confirmLabel,
    required this.onConfirm,
    this.danger = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final confirm = danger
        ? FilledButton(
            onPressed: loading ? null : onConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(confirmLabel),
          )
        : FilledButton(
            onPressed: loading ? null : onConfirm,
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(confirmLabel),
          );
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        const SizedBox(width: AppPadding.xsmall),
        confirm,
      ],
    );
  }
}

/// Standard confirmation dialog: radius 16, title + body + [AppDialogActions].
/// Returns true when confirmed, false/null otherwise.
class AppConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final bool danger;

  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.danger = false,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        danger: danger,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.large),
      ),
      title: Text(title),
      content: Text(message),
      actions: [
        AppDialogActions(
          confirmLabel: confirmLabel,
          danger: danger,
          onConfirm: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
