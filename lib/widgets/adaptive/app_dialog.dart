import 'package:flutter/material.dart';
import 'package:apexbooks/common/breakpoints.dart';

/// Adaptive dialog container: [AlertDialog] on medium/expanded windows, a
/// modal bottom sheet with a drag handle on compact (phones). Replaces the
/// desktop-only `SizedBox(width: ...)` dialog pattern.
class AppDialog {
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget content,
    List<Widget>? actions,
    double maxWidth = 560,
    bool scrollable = true,
  }) {
    if (Breakpoints.isCompact(MediaQuery.sizeOf(context).width)) {
      return _showSheet<T>(context, title, content, actions, scrollable);
    }
    return showDialog<T>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        scrollable: scrollable,
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: content,
        ),
        actions: actions,
      ),
    );
  }

  static Future<T?> _showSheet<T>(
    BuildContext context,
    String title,
    Widget content,
    List<Widget>? actions,
    bool scrollable,
  ) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
                ),
                Flexible(
                  child: scrollable
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: content,
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: content,
                        ),
                ),
                if (actions != null && actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
