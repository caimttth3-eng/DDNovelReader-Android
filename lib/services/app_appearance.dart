import 'package:flutter/material.dart';

/// Shared by the reader, its routes and the bookshelf.
class AppAppearance {
  static final nightMode = ValueNotifier<bool>(false);

  static ThemeData theme(bool dark) => ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF6498B5),
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF222222) : const Color(0xFFF2F2F2),
    ),
    scaffoldBackgroundColor: dark ? const Color(0xFF1A1A1A) : const Color(0xFFF2F2F2),
  );
}
