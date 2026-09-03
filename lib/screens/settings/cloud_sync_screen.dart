import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:apexbooks/backup/backup_manager.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/sync/sync_controller.dart';
import 'package:apexbooks/sync/sync_engine.dart';
import 'package:apexbooks/sync/sync_account.dart';

/// Cloud sync settings (dbplan Phase 2): link/unlink an account on the
/// self-hosted sync server, show status, and trigger manual cycles.
///
/// Linked state → status card (account, company, last sync, pending ops,
/// Sync now, Unlink). Unlinked → sign-in / register form.
class CloudSyncScreen extends ConsumerStatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  ConsumerState<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends ConsumerState<CloudSyncScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _company = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  // After login-with-no-company the flow lands here to ask for a name.
  bool _needsCompany = false;

  @override
  void initState() {
    super.initState();
    _needsCompany = SyncController.instance.account?.companyId.isEmpty ?? false;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _company.dispose();
    super.dispose();
  }

  void _setBusy(bool v) => mounted
      ? setState(() {
          _busy = v;
          if (v) _error = null;
        })
      : null;

  void _fail(String msg) => mounted ? setState(() => _error = msg) : null;

  Future<void> _register() async {
    if (!_formValid()) return;
    _setBusy(true);
    final err = await SyncController.instance.registerAndLink(
        _email.text.trim(), _password.text, _company.text.trim());
    _setBusy(false);
    if (err != null) return _fail(err);
  }

  Future<void> _login() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      return _fail('Enter your email and password');
    }
    _setBusy(true);
    final err = await SyncController.instance
        .loginAndLink(_email.text.trim(), _password.text);
    _setBusy(false);
    if (err != null) return _fail(err);
    final account = SyncController.instance.account;
    if (account != null && account.companyId.isEmpty) {
      setState(() => _needsCompany = true);
    }
  }

  Future<void> _createCompany() async {
    if (_company.text.trim().isEmpty) {
      return _fail('Enter a company name');
    }
    _setBusy(true);
    final err = await SyncController.instance
        .createCompanyAndLink(_company.text.trim());
    _setBusy(false);
    if (err != null) return _fail(err);
    if (mounted) setState(() => _needsCompany = false);
  }

  bool _formValid() {
    if (_email.text.trim().isEmpty || !_email.text.contains('@')) {
      _fail('Enter a valid email');
      return false;
    }
    if (_password.text.length < 8) {
      _fail('Password must be at least 8 characters');
      return false;
    }
    if (_company.text.trim().isEmpty) {
      _fail('Enter a company name for your cloud books');
      return false;
    }
    return true;
  }

  Future<void> _unlink() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink cloud sync?'),
        content: const Text(
            'This device stops syncing. Data already on the server stays '
            'there and other devices keep syncing.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unlink')),
        ],
      ),
    );
    if (confirmed == true) {
      await SyncController.instance.unlink();
      if (mounted) setState(() => _needsCompany = false);
    }
  }

  Future<void> _syncNow() async {
    _setBusy(true);
    final err = await SyncController.instance.syncNow();
    _setBusy(false);
    if (err != null) _fail(err);
  }

  Future<void> _eraseLocalData() async {
    try {
      await DatabaseHelper().wipeDatabase();
      SyncController.instance.forgetDatabaseConnection();
      await BackupManager().deleteManagedBackups();
    } catch (e) {
      _fail('Could not erase all local data: $e');
    }
  }

  Future<void> _purgeCompany() async {
    final account = SyncController.instance.account;
    if (account == null || account.companyId.isEmpty) return;
    final credentials = await _showCompanyPurgeDialog(account.companyName);
    if (credentials == null) return;

    _setBusy(true);
    final error = await SyncAccountClient(baseUrl: SyncController.apiBaseUrl)
        .purgeCompany(
      account: account,
      companyName: credentials.companyName,
      password: credentials.password,
      retentionConfirmed: credentials.retentionConfirmed,
    );
    if (error != null) {
      _setBusy(false);
      _fail(error);
      return;
    }

    try {
      await SyncController.instance.unlink();
    } catch (_) {
      // The server is already purged; continue so the local database is not
      // retained merely because clearing the now-deleted sync setting failed.
    }
    await _eraseLocalData();
    _setBusy(false);
    if (mounted && _error == null) setState(() => _needsCompany = false);
  }

  Future<void> _wipeLocalOnly() async {
    final firstConfirmed = await _showLocalWipeWarning();
    if (firstConfirmed != true || !mounted) return;
    final finalConfirmed = await _showLocalWipeFinalConfirmation();
    if (finalConfirmed != true) return;
    _setBusy(true);
    if (SyncController.instance.isLinked) {
      try {
        await SyncController.instance.unlink();
      } catch (_) {
        // The controller has already stopped the engine before persistence.
      }
      if (mounted) setState(() => _needsCompany = false);
    }
    await _eraseLocalData();
    _setBusy(false);
  }

  Future<_PurgeCredentials?> _showCompanyPurgeDialog(String companyName) async {
    final typedCompany = TextEditingController();
    final password = TextEditingController();
    var retentionConfirmed = false;
    try {
      return await showDialog<_PurgeCredentials>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            final valid = typedCompany.text == companyName &&
                password.text.isNotEmpty &&
                retentionConfirmed;
            return AlertDialog(
              title: const Text('Permanently delete cloud company?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'This permanently deletes $companyName from cloud sync, '
                      'then erases this device and app-managed backups. Files '
                      'previously exported or shared outside the app cannot be deleted.',
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: typedCompany,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Type "$companyName" to confirm',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      obscureText: true,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    CheckboxListTile(
                      value: retentionConfirmed,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (value) => setDialogState(
                          () => retentionConfirmed = value ?? false),
                      title: const Text(
                          'I confirm that applicable tax, accounting, contractual, and legal-hold retention obligations have been addressed.'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                  onPressed: valid
                      ? () => Navigator.pop(
                            ctx,
                            _PurgeCredentials(typedCompany.text, password.text,
                                retentionConfirmed),
                          )
                      : null,
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(ctx).colorScheme.error),
                  child: const Text('Delete permanently'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      typedCompany.dispose();
      password.dispose();
    }
  }

  Future<bool?> _showLocalWipeWarning() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Erase local app data?'),
          content: const Text(
            'This deletes this device\'s database and app-managed backups. '
            'Files previously exported or shared outside the app cannot be deleted.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Continue')),
          ],
        ),
      );

  Future<bool?> _showLocalWipeFinalConfirmation() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Final confirmation'),
          content: const Text(
            'Erase all local app data now? This cannot be undone. Files '
            'previously exported or shared outside the app cannot be deleted.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              child: const Text('Erase local data'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider).valueOrNull ??
        SyncController.instance.status;
    final linked = SyncController.instance.isLinked && !_needsCompany;
    final theme = Theme.of(context);

    return Scaffold(
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('Cloud Sync', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Your data stays on this device and syncs to your own '
                  'Apex Books server. Enable on every device to keep them '
                  'identical.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                if (linked)
                  _StatusCard(
                    status: status,
                    onSyncNow: _syncNow,
                    onUnlink: _unlink,
                  )
                else if (_needsCompany)
                  _CompanyStep(
                    company: _company,
                    onCreate: _createCompany,
                  )
                else
                  _AuthCard(
                    email: _email,
                    password: _password,
                    company: _company,
                    obscure: _obscure,
                    onToggleObscure: () => setState(() => _obscure = !_obscure),
                    onRegister: _register,
                    onLogin: _login,
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                _DataRemovalCard(
                  onWipeLocal: _wipeLocalOnly,
                  onPurgeCompany: linked ? _purgeCompany : null,
                ),
              ],
            ),
    );
  }
}

// ── Linked: status card ─────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final SyncStatusState status;
  final Future<void> Function() onSyncNow;
  final Future<void> Function() onUnlink;

  const _StatusCard(
      {required this.status, required this.onSyncNow, required this.onUnlink});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = SyncController.instance.account;
    final syncing = status.cycle == SyncCycleStatus.syncing;
    final errored = status.cycle == SyncCycleStatus.error;
    final lastSync = status.lastSyncAt == null
        ? '—'
        : DateFormat('d MMM yyyy, HH:mm').format(status.lastSyncAt!);
    final healthy =
        !errored && status.pendingOps == 0 && status.lastSyncAt != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  errored
                      ? Icons.sync_problem
                      : syncing
                          ? Icons.sync
                          : Icons.cloud_done,
                  color: errored
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    errored
                        ? 'Sync error'
                        : syncing
                            ? 'Syncing…'
                            : 'Sync is on',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton(onPressed: onSyncNow, child: const Text('Sync now')),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: (healthy ? Colors.green : theme.colorScheme.primary)
                    .withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(healthy ? Icons.verified_outlined : Icons.info_outline,
                    size: 18,
                    color: healthy ? Colors.green : theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(healthy
                        ? 'System health: all changes are synced.'
                        : 'System health: review pending changes or sync status.')),
              ]),
            ),
            const SizedBox(height: 8),
            _row('Account', account?.email ?? '—'),
            _row('Company', account?.companyName ?? '—'),
            _row('Pending changes', '${status.pendingOps}'),
            _row('Last sync', lastSync),
            if (status.error != null) ...[
              const SizedBox(height: 8),
              Text(status.error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const Divider(height: 32),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onUnlink,
                style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error),
                child: const Text('Unlink this device'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 140, child: Text(label)),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

class _DataRemovalCard extends StatelessWidget {
  final Future<void> Function() onWipeLocal;
  final Future<void> Function()? onPurgeCompany;

  const _DataRemovalCard({required this.onWipeLocal, this.onPurgeCompany});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Data removal', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'App-managed backups are removed too. Previously exported or '
              'shared files remain outside the app and cannot be deleted here.',
            ),
            const SizedBox(height: 12),
            if (onPurgeCompany != null) ...[
              OutlinedButton.icon(
                onPressed: onPurgeCompany,
                icon: const Icon(Icons.cloud_off_outlined),
                style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error),
                label: const Text('Delete cloud company and local data'),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              onPressed: onWipeLocal,
              icon: const Icon(Icons.delete_forever_outlined),
              style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
              label: const Text('Erase local app data'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PurgeCredentials {
  final String companyName;
  final String password;
  final bool retentionConfirmed;

  const _PurgeCredentials(
      this.companyName, this.password, this.retentionConfirmed);
}

// ── Unlinked: sign-in / register card ───────────────────────────────────

class _AuthCard extends StatelessWidget {
  final TextEditingController email;
  final TextEditingController password;
  final TextEditingController company;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final VoidCallback onRegister;
  final VoidCallback onLogin;

  const _AuthCard({
    required this.email,
    required this.password,
    required this.company,
    required this.obscure,
    required this.onToggleObscure,
    required this.onRegister,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: obscure,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Password (8+ characters)',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: onToggleObscure,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: company,
              decoration: const InputDecoration(
                labelText: 'Company name (new account)',
                prefixIcon: Icon(Icons.business_outlined),
                helperText:
                    'Only used when registering; ignored when logging in',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRegister,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Create account & sync'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onLogin,
              icon: const Icon(Icons.login),
              label: const Text('Sign in to existing account'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Logged in but no company yet: name step ─────────────────────────────

class _CompanyStep extends StatelessWidget {
  final TextEditingController company;
  final VoidCallback onCreate;

  const _CompanyStep({required this.company, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Name your cloud company',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
                'Your account has no company yet. Pick a name — books from '
                'this device become its first data.'),
            const SizedBox(height: 16),
            TextField(
              controller: company,
              decoration: const InputDecoration(
                labelText: 'Company name',
                prefixIcon: Icon(Icons.business_outlined),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Create & start syncing'),
            ),
          ],
        ),
      ),
    );
  }
}
