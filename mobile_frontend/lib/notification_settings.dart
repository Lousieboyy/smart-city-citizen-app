import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/notification_service.dart';

/// Global on/off switch for the app's status-change notification polling.
///
/// Mirrors ThemeManager's ValueNotifier + SharedPreferences pattern.
/// NotificationService.start() already calls stop() internally first, so
/// it's safe to call idempotently from both app startup and this toggle.
class NotificationSettings {
  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(true);

  static Future<void> toggle() async {
    final newValue = !enabledNotifier.value;
    enabledNotifier.value = newValue;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', newValue);

    if (newValue) {
      NotificationService.instance.start(intervalSeconds: 60);
    } else {
      NotificationService.instance.stop();
    }
  }
}
