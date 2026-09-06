import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/sync_conflicts.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Review log for silent sync overwrites (companion to the Cloud Sync
/// screen). Every row is one pulled remote op that contended with a
/// locally-modified row: what each side had, and which side LWW kept.
///
/// Actions per conflict:
///  - Mark reviewed — dismisses it from the unreviewed queue (device-local,
///    never synced).
///  - Restore my version — re-applies this device's snapshot as a fresh
///    local edit, so it re-syncs out on the next cycle (and marks reviewed).
class SyncConflictsScreen extends StatefulWidget {
  const SyncConflictsScreen({super.key});

  @override
  State<SyncConflictsScreen> createState() => _SyncConflictsScreenState();
}

class _SyncConflictsScreenState extends State<SyncConflictsScreen> {
  static const _repo = SyncConflictsRepository();
  Future<List<SyncConflict>>? _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = DatabaseHelper().database.then((db) => _repo.list(db));
    });
  }

  Future<void> _markReviewed(SyncConflict conflict) async {
    setState(() => _busy = true);
    try {
      await _repo.markReviewed(await DatabaseHelper().database, conflict.id);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  Future<void> _restoreMine(SyncConflict conflict) async {
    final confirmed = await AppConfirmDialog.show(
      context,
      title: 'Restore your version?',
      message:
          '“${_describeRow(conflict)}” will be overwritten with the values '
          'this device had, and the restored values will sync to your other '
          'devices on the next sync.',
      confirmLabel: 'Restore',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _repo.restoreMyVersion(await DatabaseHelper().database, conflict);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  static String _describeRow(SyncConflict c) => '${c.tableName} • ${c.rowPk}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync conflicts')),
      body: FutureBuilder<List<SyncConflict>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const AppLoadingState();
          }
          final conflicts = snapshot.data!;
          if (conflicts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_done_outlined,
                        size: 56, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text('No sync conflicts',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'When a change from another device overwrites an edit '
                      'made here (or the other way around), it is listed here '
                      'for review.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          final unreviewed = conflicts.where((c) => !c.reviewed).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                unreviewed == 0
                    ? 'All caught up — ${conflicts.length} reviewed.'
                    : '$unreviewed need${unreviewed == 1 ? 's' : ''} review',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              for (final conflict in conflicts)
                _ConflictCard(
                  conflict: conflict,
                  busy: _busy,
                  onMarkReviewed: () => _markReviewed(conflict),
                  onRestoreMine: () => _restoreMine(conflict),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final SyncConflict conflict;
  final bool busy;
  final VoidCallback onMarkReviewed;
  final VoidCallback onRestoreMine;

  const _ConflictCard({
    required this.conflict,
    required this.busy,
    required this.onMarkReviewed,
    required this.onRestoreMine,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remoteWon = conflict.winner == 'remote';
    final diffs =
        diffSnapshots(conflict.localSnapshot, conflict.remoteSnapshot);
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Opacity(
        opacity: conflict.reviewed ? 0.65 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${conflict.tableName} • ${conflict.rowPk}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                _WinnerChip(remoteWon: remoteWon),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('d MMM yyyy, HH:mm')
                  .format(conflict.occurredAt.toLocal()),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              remoteWon
                  ? 'The other device’s version is now saved here. Your '
                      'previous values are shown so you can compare or '
                      'restore them.'
                  : 'Your version was kept; the incoming change from the '
                      'other device was set aside. Nothing was overwritten.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (conflict.localSnapshot == null)
              _note(context, 'Deleted on this device before the sync.')
            else if (conflict.remoteSnapshot == null)
              _note(context, 'Deleted on the other device.')
            else if (diffs.isEmpty)
              _note(context, 'Both sides carried the same values.')
            else
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    for (final d in diffs.take(20))
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(d.column,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                'Yours: ${_formatValue(d.local)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                'Theirs: ${_formatValue(d.remote)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (diffs.length > 20)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '…and ${diffs.length - 20} more field(s)',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (!conflict.reviewed)
                  OutlinedButton(
                    onPressed: busy ? null : onMarkReviewed,
                    child: const Text('Mark reviewed'),
                  ),
                if (remoteWon)
                  FilledButton(
                    onPressed: busy ? null : onRestoreMine,
                    child: const Text('Restore my version'),
                  ),
                if (conflict.reviewed)
                  Chip(
                    label: const Text('Reviewed'),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontStyle: FontStyle.italic,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      );

  static String _formatValue(Object? value) {
    if (value == null) return '—';
    final text = value.toString();
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }
}

class _WinnerChip extends StatelessWidget {
  final bool remoteWon;
  const _WinnerChip({required this.remoteWon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = remoteWon ? Colors.orange : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        remoteWon ? 'Theirs kept' : 'Yours kept',
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
