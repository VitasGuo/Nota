import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { dark, light, system }

class AppTheme {
  static Color accentColor = const Color(0xFF9B8EC4);
  static Color accentLight = const Color(0xFFE8A0BF);

  static const Color darkPrimaryColor = Color(0xFF1A1625);
  static const Color darkSecondaryColor = Color(0xFF241F30);
  static const Color darkCardColor = Color(0xFF2D2640);
  static const Color darkSurfaceColor = Color(0xFF13101D);
  static const Color darkTextPrimary = Color(0xFFF0EDE6);
  static const Color darkTextSecondary = Color(0xFF9A93A8);

  static const Color lightPrimaryColor = Color(0xFFF5F0FA);
  static const Color lightSecondaryColor = Color(0xFFE8E0F0);
  static const Color lightCardColor = Color(0xFFFFFFFF);
  static const Color lightSurfaceColor = Color(0xFFFAF7FF);
  static const Color lightTextPrimary = Color(0xFF1A2E24);
  static const Color lightTextSecondary = Color(0xFF5A5070);

  static Brightness _currentBrightness = Brightness.dark;

  static Brightness get currentBrightness => _currentBrightness;

  static void _setBrightness(Brightness brightness) {
    _currentBrightness = brightness;
  }

  static void setAccentColor(Color color) {
    accentColor = color;
    // 生成对应的浅色版本
    final hsl = HSLColor.fromColor(color);
    accentLight = hsl.withLightness((hsl.lightness + 0.2).clamp(0.0, 1.0)).toColor();
  }

  static LinearGradient get accentGradient => LinearGradient(
    colors: [accentColor, accentLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static Color get textPrimary =>
      _currentBrightness == Brightness.light ? lightTextPrimary : darkTextPrimary;

  static Color get textSecondary =>
      _currentBrightness == Brightness.light ? lightTextSecondary : darkTextSecondary;

  static Color get cardColor =>
      _currentBrightness == Brightness.light ? lightCardColor : darkCardColor;

  static Color get primaryColor =>
      _currentBrightness == Brightness.light ? lightPrimaryColor : darkPrimaryColor;

  static Color get surfaceColor =>
      _currentBrightness == Brightness.light ? lightSurfaceColor : darkSurfaceColor;

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: accentColor,
      scaffoldBackgroundColor: darkSurfaceColor,
      colorScheme: ColorScheme.dark(
        primary: accentColor,
        secondary: accentLight,
        surface: darkSurfaceColor,
        onSurface: darkTextPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkPrimaryColor,
        foregroundColor: darkTextPrimary,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: darkCardColor,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: darkPrimaryColor,
        selectedItemColor: accentColor,
        unselectedItemColor: darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSecondaryColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: darkTextSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: darkTextPrimary, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: darkTextPrimary, fontWeight: FontWeight.bold),
        titleLarge: TextStyle(color: darkTextPrimary, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: darkTextPrimary, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: darkTextPrimary),
        bodyMedium: TextStyle(color: darkTextSecondary),
        labelLarge: TextStyle(color: darkTextPrimary, fontWeight: FontWeight.w600),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF352E45),
        thickness: 0.5,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColor,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: accentColor,
      scaffoldBackgroundColor: lightSurfaceColor,
      colorScheme: ColorScheme.light(
        primary: accentColor,
        secondary: accentLight,
        surface: lightSurfaceColor,
        onSurface: lightTextPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: lightPrimaryColor,
        foregroundColor: lightTextPrimary,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: lightCardColor,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: lightCardColor,
        selectedItemColor: accentColor,
        unselectedItemColor: lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSecondaryColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: lightTextSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: lightTextPrimary, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: lightTextPrimary, fontWeight: FontWeight.bold),
        titleLarge: TextStyle(color: lightTextPrimary, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: lightTextPrimary, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: lightTextPrimary),
        bodyMedium: TextStyle(color: lightTextSecondary),
        labelLarge: TextStyle(color: lightTextPrimary, fontWeight: FontWeight.w600),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFD8D0E5),
        thickness: 0.5,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColor,
        foregroundColor: Colors.white,
      ),
    );
  }
}

class ThemeService {
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyAccentColor = 'accent_color';

  static Future<AppThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_keyThemeMode) ?? 0;
    return AppThemeMode.values[index];
  }

  static Future<void> setThemeMode(AppThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThemeMode, mode.index);
  }

  static Future<void> loadAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_keyAccentColor);
    if (colorValue != null) {
      AppTheme.setAccentColor(Color(colorValue));
    }
  }

  static Future<void> setAccentColor(Color color) async {
    AppTheme.setAccentColor(color);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAccentColor, color.toARGB32());
  }

  static ThemeData getTheme(AppThemeMode mode) {
    Brightness brightness;
    switch (mode) {
      case AppThemeMode.dark:
        brightness = Brightness.dark;
      case AppThemeMode.light:
        brightness = Brightness.light;
      case AppThemeMode.system:
        brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
    AppTheme._setBrightness(brightness);
    return brightness == Brightness.dark ? AppTheme.darkTheme : AppTheme.lightTheme;
  }
}
