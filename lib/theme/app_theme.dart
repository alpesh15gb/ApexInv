import 'package:flutter/material.dart';

class AppTheme {
  // Non-Latin app-UI text (Nepali/Hindi Devanagari, Tibetan) falls back to
  // these bundled fonts instead of rendering as tofu boxes.
  static const _scriptFontFallback = ['NotoSansDevanagari', 'NotoSerifTibetan'];

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      primaryColor: const Color(0xFF155EEF),
      visualDensity: VisualDensity.standard,
      fontFamilyFallback: _scriptFontFallback,
    );
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF6F8FC),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF155EEF),
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFDCEAFF),
        onPrimaryContainer: Color(0xFF003A9B),
        secondary: Color(0xFFF79009),
        onSecondary: Color(0xFF3B2200),
        secondaryContainer: Color(0xFFFFE8C2),
        onSecondaryContainer: Color(0xFF563300),
        error: Color(0xFFB42318),
        onError: Colors.white,
        surface: Colors.white,
        onSurface: Color(0xFF172033),
        surfaceContainer: Colors.white,
        surfaceContainerHighest: Color(0xFFEEF2F7),
        onSurfaceVariant: Color(0xFF596780),
        outline: Color(0xFFBAC4D4),
        outlineVariant: Color(0xFFDCE2EB),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF172033),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        titleTextStyle: TextStyle(
          color: Color(0xFF172033),
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: const CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: Color(0xFFDCE2EB)),
        ),
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFFDCE2EB), space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: const BorderSide(color: Color(0xFFBAC4D4)),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: Color(0xFFBAC4D4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: Color(0xFFBAC4D4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: Color(0xFF155EEF), width: 2),
        ),
      ),
    );
  }

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        primaryColor: const Color(0xFF84ADFF),
        fontFamilyFallback: _scriptFontFallback,
        scaffoldBackgroundColor: const Color(0xFF101828),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF172033),
          foregroundColor: Color(0xFFF8FAFC),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF84ADFF),
          onPrimary: Color(0xFF002E78),
          primaryContainer: Color(0xFF163E7A),
          onPrimaryContainer: Color(0xFFDCEAFF),
          secondary: Color(0xFFFFB547),
          onSecondary: Color(0xFF4A2C00),
          error: Color(0xFFFFB4AB),
          onError: Color(0xFF690005),
          surface: Color(0xFF172033),
          surfaceContainer: Color(0xFF172033),
          surfaceContainerHighest: Color(0xFF222D42),
          onSurface: Color(0xFFF1F5F9),
          onSurfaceVariant: Color(0xFFB7C2D4),
          outline: Color(0xFF7D899D),
          outlineVariant: Color(0xFF35425A),
        ),
        cardColor: const Color(0xFF172033),
        cardTheme: const CardThemeData(
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFF35425A)),
          ),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFF35425A), space: 1),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            side: const BorderSide(color: Color(0xFF7D899D)),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF172033),
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF7D899D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF7D899D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFF84ADFF), width: 2),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF222D42),
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      );
}
