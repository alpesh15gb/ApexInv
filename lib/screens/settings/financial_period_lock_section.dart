import 'package:flutter/material.dart';

import 'package:apexbooks/database/period_lock_service.dart';
import 'package:apexbooks/utils/app_date.dart';
import 'package:apexbooks/widgets/app/app.dart';

/// Financial period lock editor, embedded in Settings (admin-only surface).
///
/// Non-admin callers get an empty box ([isAdmin] gate doubles the
/// SettingsScreen-level admin gate so the control unit-tests in isolation).
/// Changes apply immediately behind an explicit confirm dialog and are
/// audit-logged by [PeriodLockService.setLockedBeforeDate].
class FinancialPeriodLockSection extends StatefulWidget {
  final bool isAdmin;
  final String? username;

  const FinancialPeriodLockSection({
    super.key,
    required this.isAdmin,
    this.username,
  });

  @override
  State<FinancialPeriodLockSection> createState() =>
      _FinancialPeriodLockSectionState();
}

class _FinancialPeriodLockSectionState
    extends State<FinancialPeriodLockSection> {
  DateTime? _lockedBefore;
  DateTime? _picked;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Non-admin users see an empty box and must not touch the database.
    if (widget.isAdmin) {
      _reload();
    } else {
      _loading = false;
    }
  }

  Future<void> _reload() async {
    DateTime? current;
    try {
      current = await PeriodLockService.getLockedBeforeDate();
    } catch (_) {
      current = null;
    }
    if (!mounted) return;
    setState(() {
      _lockedBefore = current;
      _picked = current;
      _loading = false;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _picked ?? _lockedBefore ?? now;
    final chosen = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (chosen != null && mounted) {
      setState(() => _picked = DateTime(chosen.year, chosen.month, chosen.day));
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _applyLock() async {
    final picked = _picked;
    if (picked == null || _saving) return;
    final ok = await _confirm(
      title: 'Lock financial period?',
      body: 'Documents dated on or before ${AppDate.dateKey(picked)} will '
          'become read-only for everyone (no creates, edits, deletes, '
          'payments or ledger postings). This is audit-logged.',
      confirmLabel: 'Lock period',
    );
    if (!ok) return;
    setState(() => _saving = true);
    try {
      await PeriodLockService.setLockedBeforeDate(
        picked,
        username: widget.username,
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Period locked through ${AppDate.dateKey(picked)}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set lock: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearLock() async {
    if (_lockedBefore == null || _saving) return;
    final ok = await _confirm(
      title: 'Unlock financial period?',
      body: 'Documents dated on or before '
          '${AppDate.dateKey(_lockedBefore!)} will become editable again. '
          'This is audit-logged.',
      confirmLabel: 'Unlock',
    );
    if (!ok) return;
    setState(() => _saving = true);
    try {
      await PeriodLockService.setLockedBeforeDate(
        null,
        username: widget.username,
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Financial period unlocked'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear lock: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Admin-only control: non-admin users never see lock state or actions.
    if (!widget.isAdmin) return const SizedBox.shrink();
    if (_loading) {
      return const AppCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    final locked = _lockedBefore != null;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                color: locked
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).primaryColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Financial period lock',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      locked
                          ? 'Locked through ${AppDate.dateKey(_lockedBefore!)} — '
                              'earlier documents are read-only.'
                          : 'Unlocked — all periods are editable.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Lock documents dated on or before the selected date. Applies '
            'immediately to invoices, quotations, credit/debit notes, '
            'purchase bills and orders, payments, expenses, transfers, '
            'adjustments, loans and cheques. Viewing, printing and exporting '
            'are unaffected.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _pickDate,
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(
                    _picked == null
                        ? 'Choose lock date'
                        : AppDate.dateKey(_picked!),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppPrimaryButton(
                  onPressed: (_saving || _picked == null) ? null : _applyLock,
                  icon: const Icon(Icons.lock_rounded, size: 16),
                  label: const Text('Lock period'),
                  loading: _saving,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppSecondaryButton(
                  onPressed: (_saving || !locked) ? null : _clearLock,
                  icon: const Icon(Icons.lock_open_rounded, size: 16),
                  label: const Text('Unlock'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
