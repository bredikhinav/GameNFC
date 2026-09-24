import 'package:flutter/material.dart';

/// Colors and type from the approved screen designs.
abstract final class C {
  static const bg = Color(0xFFFBF6EE);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF3ECDF);
  static const surfaceSand = Color(0xFFF0E9DC);
  static const border = Color(0xFFE6DDCD);
  static const borderStrong = Color(0xFFD5CBB9);

  static const ink = Color(0xFF1F2430);
  static const inkSoft = Color(0xFF2E3444);
  static const text2 = Color(0xFF5E5A52);
  static const text3 = Color(0xFF6B7080);

  static const green = Color(0xFF0F6B5C);
  static const greenDark = Color(0xFF0A4F44);
  static const greenPale = Color(0xFFD8EEE8);
  static const greenMint = Color(0xFFBFE0D6);

  static const coin = Color(0xFFF2B544);
  static const coinDark = Color(0xFFE09A1F);
  static const coinPale = Color(0xFFFCEBC4);

  static const red = Color(0xFFB3401F);
  static const redPale = Color(0xFFF8DDD3);
  static const peach = Color(0xFFF7C9B6);
  static const redDark = Color(0xFF7A2E14);

  static const lilac = Color(0xFFD9D2F2);
  static const violet = Color(0xFF3E2F86);
}

abstract final class T {
  static const _display = 'Unbounded';

  static const h1 = TextStyle(fontFamily: _display, fontSize: 28, fontWeight: FontWeight.w700, color: C.ink, height: 1.15);
  static const h2 = TextStyle(fontFamily: _display, fontSize: 22, fontWeight: FontWeight.w700, color: C.ink, height: 1.2);
  static const h3 = TextStyle(fontFamily: _display, fontSize: 18, fontWeight: FontWeight.w700, color: C.ink);
  static const amountXL = TextStyle(fontFamily: _display, fontSize: 56, fontWeight: FontWeight.w700, color: C.ink, height: 1);
  static const amountL = TextStyle(fontFamily: _display, fontSize: 40, fontWeight: FontWeight.w700, color: C.ink, height: 1);
  static const amountM = TextStyle(fontFamily: _display, fontSize: 20, fontWeight: FontWeight.w700, color: C.ink);
  static const key = TextStyle(fontFamily: _display, fontSize: 22, fontWeight: FontWeight.w600, color: C.ink);

  static const title = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: C.ink);
  static const body = TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: C.ink, height: 1.35);
  static const bodyBold = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: C.ink);
  static const secondary = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: C.text2, height: 1.4);
  static const small = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: C.text2);
  static const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: C.ink);
  static const caps = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: C.text2, letterSpacing: 0.8);
  static const button = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'Manrope',
    scaffoldBackgroundColor: C.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: C.green,
      primary: C.green,
      secondary: C.coin,
      error: C.red,
      surface: C.bg,
    ),
  );
  final radius = BorderRadius.circular(14);
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: color, width: width));
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.ink, displayColor: C.ink),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: const TextStyle(color: Color(0xFF9C968B), fontWeight: FontWeight.w500),
      border: border(C.border),
      enabledBorder: border(C.border),
      focusedBorder: border(C.green, 1.5),
      errorBorder: border(C.red),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.ink,
      contentTextStyle: TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w600, color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: C.bg,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    dividerTheme: const DividerThemeData(color: C.border, thickness: 1, space: 1),
    checkboxTheme: CheckboxThemeData(
      side: const BorderSide(color: C.text2, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.green : Colors.white),
    ),
  );
}
