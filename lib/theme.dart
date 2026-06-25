import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Anjish brand — a vivid violet that reads well through frosted glass.
const _seed = Color(0xFF7C5CFF);

ThemeData _build(Brightness b) {
  final isDark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: b,
  ).copyWith(
    surface: isDark ? const Color(0xFF0A0A12) : const Color(0xFFF6F5FB),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'Roboto',
  );

  final onGlass = isDark ? Colors.white : const Color(0xFF15131F);

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: onGlass,
      displayColor: onGlass,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: onGlass,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: onGlass,
        fontWeight: FontWeight.w800,
        fontSize: 22,
        letterSpacing: -0.5,
      ),
    ),
    // Cards are subtle frosted panels (true blur applied via the Glass widget
    // where it matters).
    cardTheme: CardThemeData(
      elevation: 0,
      // Frosted-white cards on light, subtle-light on dark (not a muddy
      // dark tint over the light aurora).
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        side: BorderSide(color: onGlass.withValues(alpha: 0.25)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: onGlass.withValues(alpha: 0.08),
      side: BorderSide(color: onGlass.withValues(alpha: 0.12)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      labelStyle: TextStyle(color: onGlass, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: onGlass.withValues(alpha: 0.07),
      hintStyle: TextStyle(color: onGlass.withValues(alpha: 0.5)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? const Color(0xFF15131F) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(color: onGlass.withValues(alpha: 0.08)),
  );
}

class NimbusTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  /// Brand gradient used on accents, the brand mark, and progress.
  static const brandGradient = LinearGradient(
    colors: [Color(0xFF7C5CFF), Color(0xFF00B4D8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// Holds the user's light/dark/system choice and persists it.
class ThemeController extends ChangeNotifier {
  static const _key = 'nimbus_theme_mode';
  ThemeMode _mode = ThemeMode.dark; // glass shines on dark by default
  ThemeMode get mode => _mode;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    _mode = ThemeMode.values.firstWhere(
      (m) => m.name == v,
      orElse: () => ThemeMode.dark,
    );
    notifyListeners();
  }

  Future<void> set(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  void applySystemChrome(Brightness platformBrightness) {
    final isDark = _mode == ThemeMode.dark ||
        (_mode == ThemeMode.system && platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));
  }
}
