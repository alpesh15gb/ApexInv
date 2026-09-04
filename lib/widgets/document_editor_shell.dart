import 'package:flutter/material.dart';

/// Visual-only frame shared by financial document editors.
/// Business rules remain in the owning screen.
class DocumentEditorShell extends StatelessWidget {
  final Widget editor;
  final Widget actions;
  final List<String> validationErrors;
  final String stateLabel;
  final bool isDirty;

  const DocumentEditorShell({
    super.key,
    required this.editor,
    required this.actions,
    required this.validationErrors,
    required this.stateLabel,
    this.isDirty = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReviewStrip(
          stateLabel: stateLabel,
          isDirty: isDirty,
          validationErrors: validationErrors,
        ),
        Expanded(child: editor),
        actions,
      ],
    );
  }
}

class _ReviewStrip extends StatelessWidget {
  final String stateLabel;
  final bool isDirty;
  final List<String> validationErrors;

  const _ReviewStrip({
    required this.stateLabel,
    required this.isDirty,
    required this.validationErrors,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasErrors = validationErrors.isNotEmpty;
    final color =
        hasErrors ? theme.colorScheme.error : theme.colorScheme.primary;
    return Material(
      color: color.withValues(alpha: 0.07),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(hasErrors ? Icons.error_outline : Icons.check_circle_outline,
                size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasErrors
                        ? '${validationErrors.length} issue(s) need attention'
                        : stateLabel,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12),
                  ),
                  if (hasErrors)
                    Text(
                      validationErrors.join('  •  '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (isDirty && !hasErrors)
              Text('Unsaved changes',
                  style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
