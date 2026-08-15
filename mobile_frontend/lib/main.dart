import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_session.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'theme_manager.dart';
import 'pixel_theme.dart';
import 'localization/locale_manager.dart';
import 'notification_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isLoggedIn = false;
  bool _isLoading = true;

  /// Session restore usually finishes in a few milliseconds, which would flash
  /// the splash for a single frame. Hold it until the intro animation has
  /// played through, so launch reads as deliberate rather than glitchy.
  static const Duration _minimumSplashDuration =
      Duration(milliseconds: 1600); // ≥ SplashScreen.introDuration

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Restore the session and hold the splash for whichever takes longer.
  Future<void> _bootstrap() async {
    await Future.wait([
      _restoreSession(),
      Future<void>.delayed(_minimumSplashDuration),
    ]);
    if (mounted) setState(() => _isLoading = false);
  }

  /// Restore the user session from persistent storage on app launch safely.
  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId      = prefs.getInt('user_id');
      final username    = prefs.getString('username')     ?? 'Citizen';
      final role        = prefs.getString('role')         ?? 'citizen';
      final token       = prefs.getString('token');       // JWT token
      final fullName    = prefs.getString('full_name')    ?? username;
      final icNumber    = prefs.getString('ic_number')    ?? '';
      final phoneNumber = prefs.getString('phone_number') ?? '';
      final email       = prefs.getString('email')        ?? '';
      final avatarIndex = prefs.getInt('avatar_index');
      final customPhotoBase64 = prefs.getString('custom_photo_base64');

      // Restore the theme mode preference
      final isLightTheme = prefs.getBool('is_light_theme') ?? false; // defaults to dark retro
      ThemeManager.themeModeNotifier.value = isLightTheme ? ThemeMode.light : ThemeMode.dark;

      // Restore the language preference
      LocaleManager.localeNotifier.value = prefs.getString('locale') ?? 'en';

      // Restore the notifications preference
      NotificationSettings.enabledNotifier.value = prefs.getBool('notifications_enabled') ?? true;

      if (userId != null) {
        UserSession.instance.populate(
          id:                userId,
          name:              username,
          userRole:          role,
          jwtToken:          token,
          customAvatarIndex: avatarIndex,
          userCustomPhotoBase64: customPhotoBase64,
          userFullName:      fullName,
          userIcNumber:      icNumber,
          userPhoneNumber:   phoneNumber,
          userEmail:         email,
        );
        _isLoggedIn = true;
      }
    } catch (e) {
      debugPrint('[MyApp] Error restoring session: $e');
      // Swallowed on purpose: a corrupt or unreadable prefs store should drop
      // the user at Login, not wedge the app on the splash screen.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeModeNotifier,
      builder: (context, currentThemeMode, child) {
        return ValueListenableBuilder<String>(
          valueListenable: LocaleManager.localeNotifier,
          builder: (context, currentLocale, child) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Melaka Smart City Reporting',
              themeMode: ThemeMode.dark, // locked to dark retro theme
              theme: PixelTheme.buildTheme(),
              darkTheme: PixelTheme.buildTheme(),
              // Cross-fades the splash into the first real screen instead of
              // cutting to it. Home and Login share a runtimeType across
              // rebuilds, so only the splash swap animates — a locale change
              // still updates the live screen in place rather than replaying
              // a transition over it.
              home: AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                child: _isLoading
                    ? const SplashScreen()
                    // Deliberately NOT const.
                    //
                    // A const constructor returns the same canonicalised
                    // instance on every rebuild. Flutter's element tree
                    // short-circuits when the new widget is identical to the
                    // old one, so the entire screen below this point would be
                    // skipped — the locale notifier fires, MaterialApp
                    // rebuilds, and nothing re-translates.
                    //
                    // Building a fresh instance lets the element update in
                    // place: the subtree rebuilds with the new language while
                    // State is preserved, so the selected tab and already-
                    // loaded reports survive the switch.
                    : (_isLoggedIn ? HomeScreen() : LoginScreen()),
              ),
            );
          },
        );
      },
    );
  }
}