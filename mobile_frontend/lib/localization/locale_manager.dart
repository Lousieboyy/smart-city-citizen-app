import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global app language switch (English / Bahasa Malaysia).
///
/// Mirrors ThemeManager's ValueNotifier + SharedPreferences pattern so
/// toggling the language rebuilds the whole tree live, the same way the
/// theme toggle already does.
class LocaleManager {
  static final ValueNotifier<String> localeNotifier = ValueNotifier<String>('en');

  static bool get isBm => localeNotifier.value == 'bm';

  static Future<void> toggleLocale() async {
    final newLocale = localeNotifier.value == 'en' ? 'bm' : 'en';
    localeNotifier.value = newLocale;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', newLocale);
  }
}
