import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:apexbooks/common/app_config.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/screens/auth/forgot_password_screen.dart';
import 'package:apexbooks/screens/auth/change_password_screen.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:apexbooks/providers/app_config_provider.dart';
import 'package:apexbooks/utils/post_auth_navigation.dart';

// Login Screen
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  // True when no local user exists yet: first launch creates the owner.
  // Cloud edition always authenticates remotely — never setup mode.
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    _checkNeedsSetup();
  }

  Future<void> _checkNeedsSetup() async {
    if (ref.read(appEditionConfigProvider).isCloud) return;
    final users = await ref.read(authRepositoryProvider).getAllUsers();
    if (!mounted) return;
    setState(() => _needsSetup = users.isEmpty);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _createOwner(AppEditionConfig cfg) async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;
    if (username.isEmpty || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a username and password')),
      );
      return;
    }
    if (password.length < 8) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be at least 8 characters')),
      );
      return;
    }
    if (password.toLowerCase() == username.toLowerCase()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must differ from username')),
      );
      return;
    }
    if (password != confirm) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passwords do not match')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final existing =
          await ref.read(authRepositoryProvider).getUserByUsername(username);
      if (existing != null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That username is already taken')),
        );
        return;
      }
      final user = User(
        id: const Uuid().v4(),
        username: username,
        password: password,
        userType: 'admin',
        passwordChanged: true,
      );
      await ref.read(authRepositoryProvider).insertUser(user);
      final created =
          await ref.read(authRepositoryProvider).getUserByUsername(username);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _needsSetup = false;
      });
      if (created == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Setup failed — please try again')),
        );
        return;
      }
      await _afterLoginNavigate(cfg, created);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Setup failed: $e')),
      );
    }
  }

  void _login(AppEditionConfig cfg) async {
    // for cloud the username will be email
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    final usernameText = cfg.isCloud ? "Email" : "Username";

    if (username.isEmpty || password.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please enter $usernameText and password')),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isLoading = true);

    final user =
        await ref.read(authRepositoryProvider).getUser(username, password);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid credentials')),
      );
      return;
    }

    _afterLoginNavigate(cfg, user);
  }

  Future<void> _afterLoginNavigate(AppEditionConfig cfg, User user) async {
    if (cfg.isCloud) {
      if (!mounted) return;
      await navigateAfterAuth(context, ref, user);
    } else if (!user.passwordChanged && !cfg.isCloud) {
      // Force password change
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ChangePasswordScreen(user: user, forced: true),
        ),
      );
    } else {
      if (!mounted) return;
      await navigateAfterAuth(context, ref, user);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appEditionConfigProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Phone: card fills the width (minus side padding) since there's no
    // room to spare. Tablet/desktop: a fixed comfortable width instead of
    // the old `width * 0.25`, which shrank to an unusably narrow card on
    // tablet portrait widths (e.g. ~190px at 768px wide).
    final isPhone = screenWidth < 600;
    final cardWidth = isPhone ? screenWidth - 48 : 420.0;
    final cardPadding = isPhone ? 20.0 : 32.0;
    final logoWidth = (cardWidth * 0.65).clamp(140.0, 230.0);
    return Scaffold(
      backgroundColor: isDark ? null : Colors.blue[50],
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!cfg.isCloud)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: cardWidth),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => launchUrl(
                          Uri.parse(AppConfig.website),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              const Icon(Icons.cloud_outlined,
                                  color: Colors.white, size: 24),
                              Wrap(
                                children: [
                                  const Text(
                                    'Need multi-device access? ',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  ),
                                  const Text(
                                    '"Apex Books Cloud Edition"',
                                    style: TextStyle(
                                        color: Colors.yellow, fontSize: 13),
                                  ),
                                  const Text(
                                    ' is available.',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 13),
                                  ),
                                ],
                              ),
                              Text(
                                'Learn more →',
                                style: TextStyle(
                                  color: Colors.blue[100],
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Card(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Container(
                    width: cardWidth,
                    padding: EdgeInsets.all(cardPadding),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          // TODO: swap to a real dark-mode asset once available.
                          isDark
                              ? 'assets/images/logo_dark.png'
                              : 'assets/images/logo.png',
                          width: logoWidth,
                          height: 100,
                          fit: BoxFit.contain,
                        ),
                        AppSpacing.hSmall,
                        if (!cfg.isCloud && _needsSetup) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.admin_panel_settings_outlined,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Welcome! Create the administrator account for this device. There are no default credentials.',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          AppSpacing.hLarge,
                        ],
                        TextField(
                          controller: _usernameController,
                          decoration: InputDecoration(
                            labelText: cfg.isCloud ? 'Email' : 'Username',
                            prefixIcon: const Icon(Icons.person),
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: cfg.isCloud
                              ? TextInputType.emailAddress
                              : TextInputType.text,
                        ),
                        AppSpacing.hMedium,
                        TextField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          onSubmitted: (_) => _login(cfg),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                        ),
                        if (!cfg.isCloud && _needsSetup) ...[
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: _obscurePassword,
                            onSubmitted: (_) => _createOwner(cfg),
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                              prefixIcon: Icon(Icons.lock_outline),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          AppSpacing.hMedium,
                        ],
                        AppSpacing.hXlarge,
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading
                                ? null
                                : () => _needsSetup && !cfg.isCloud
                                    ? _createOwner(cfg)
                                    : _login(cfg),
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 50),
                              backgroundColor: Theme.of(context).primaryColor,
                              foregroundColor: Colors.white,
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(_needsSetup && !cfg.isCloud
                                    ? 'Create administrator'
                                    : 'Login'),
                          ),
                        ),
                        AppSpacing.hSmall,
                        if (!cfg.isCloud)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        const ForgotPasswordScreen()),
                              ),
                              child: const Text('Forgot password?'),
                            ),
                          ),
                        AppSpacing.hLarge,
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => launchUrl(Uri.parse(AppConfig.website),
                                mode: LaunchMode.externalApplication),
                            child: Text(
                              AppConfig.website,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  decoration: TextDecoration.underline),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppConfig.version,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => launchUrl(
                                Uri.parse(AppConfig.supportForm),
                                mode: LaunchMode.externalApplication),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.support_agent_outlined,
                                    size: 14,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Need help? Contact Support',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        decoration: TextDecoration.underline),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
