import 'package:flutter/material.dart';

const blush = Color(0xFFFFF0F5);
const ink = Color(0xFF211A20);
const mutedInk = Color(0xFF66505D);
const focus = Color(0xFF75425F);
const controlBorder = Color(0xFF8C6B7C);

final appTheme = ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: blush,
  colorScheme: ColorScheme.fromSeed(seedColor: focus).copyWith(
    primary: ink,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: ink,
    error: const Color(0xFF9D2349),
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
    style: FilledButton.styleFrom(
      minimumSize: const Size(44, 48),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(fontSize: 16, color: ink),
    bodyMedium: TextStyle(fontSize: 16, color: ink),
    bodySmall: TextStyle(fontSize: 14, color: mutedInk),
  ),
);
