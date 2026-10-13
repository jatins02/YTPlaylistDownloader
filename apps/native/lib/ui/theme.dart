import 'package:flutter/material.dart';

const blush = Color(0xFFFFF0F5);
const ink = Color(0xFF211A20);
const mutedInk = Color(0xFF66505D);
const focus = Color(0xFF75425F);
const controlBorder = Color(0xFF8C6B7C);
const surfaceMuted = Color(0xFFFAE8F0);
const surfaceHover = Color(0xFFF2DAE6);
const decorativeBorder = Color(0xFFDEC7D2);
const errorInk = Color(0xFF9D2349);

const _shape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
);

ButtonStyle _secondaryButtonStyle() =>
    OutlinedButton.styleFrom(
      foregroundColor: ink,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      side: const BorderSide(color: controlBorder),
      shape: _shape,
    ).copyWith(
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? const BorderSide(color: focus, width: 2)
            : const BorderSide(color: controlBorder),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused) ? surfaceHover : null,
      ),
    );

final appTheme = ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: blush,
  focusColor: surfaceHover,
  hoverColor: surfaceMuted,
  materialTapTargetSize: MaterialTapTargetSize.padded,
  visualDensity: VisualDensity.standard,
  appBarTheme: const AppBarTheme(
    backgroundColor: blush,
    foregroundColor: ink,
    surfaceTintColor: Colors.transparent,
  ),
  cardTheme: const CardThemeData(
    color: Colors.white,
    elevation: 0,
    shape: _shape,
    surfaceTintColor: Colors.transparent,
  ),
  dialogTheme: const DialogThemeData(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: _shape,
  ),
  colorScheme: ColorScheme.fromSeed(seedColor: focus).copyWith(
    primary: ink,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: ink,
    error: errorInk,
    onError: Colors.white,
    onSurfaceVariant: mutedInk,
    surfaceContainerHighest: surfaceMuted,
    outline: controlBorder,
  ),
  iconButtonTheme: IconButtonThemeData(
    style:
        IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: ink,
          highlightColor: surfaceHover,
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: focus, width: 2)
                : null,
          ),
        ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(style: _secondaryButtonStyle()),
  textButtonTheme: TextButtonThemeData(
    style:
        TextButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: _shape,
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: focus, width: 2)
                : null,
          ),
        ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: controlBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: controlBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: focus, width: 2),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style:
        FilledButton.styleFrom(
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? const BorderSide(color: focus, width: 3)
                : null,
          ),
        ),
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(fontSize: 16, color: ink),
    bodyMedium: TextStyle(fontSize: 16, color: ink),
    bodySmall: TextStyle(fontSize: 14, color: mutedInk),
    titleMedium: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
  ),
);
