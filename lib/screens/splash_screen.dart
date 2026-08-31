import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apexbooks/database/database_helper.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/common/constants.dart';
import 'package:apexbooks/common/setting_key.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/screens/auth/login_screen.dart';
import 'package:apexbooks/utils/app_logger.dart';
import 'package:apexbooks/utils/post_auth_navigation.dart';

const _tag = 'SplashScreen';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await DatabaseHelper().database;
    } catch (e, stack) {
      AppLogger.e(_tag, 'Database initialization failed', e, stack);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.splashInitErrorTitle),
          content: Text(l10n.splashInitErrorMessage('$e')),
          actions: [
            ElevatedButton(
              onPressed: () => _initializeApp(),
              child: Text(l10n.actionRetry),
            ),
          ],
        ),
      );
      return;
    }

    AppLogger.d(_tag, 'DB path: ${DatabaseHelper.path}');

    if (!mounted) return;
    // Auto-login: restore the last signed-in user straight into the app.
    // Only a logout (or a deleted user) drops back to the login screen.
    final savedUserId = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.currentUserId);
    if (!mounted) return;
    if (savedUserId != null && savedUserId.isNotEmpty) {
      final user =
          await ref.read(authRepositoryProvider).getUserById(savedUserId);
      if (!mounted) return;
      if (user != null) {
        await navigateAfterAuth(context, ref, user);
        return;
      }
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(AppLocalizations.of(context)!.splashInitializingMessage,
                style: const TextStyle(fontSize: 18)),
            AppSpacing.hXlarge,
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
