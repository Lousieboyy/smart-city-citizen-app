import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeManager {
  static final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

  static void toggleTheme() async {
    final newMode = themeModeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    themeModeNotifier.value = newMode;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_light_theme', newMode == ThemeMode.light);
  }

  static bool get isDark => themeModeNotifier.value == ThemeMode.dark;
}
