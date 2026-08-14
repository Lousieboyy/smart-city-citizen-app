import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_session.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme_manager.dart';
import 'pixel_theme.dart';
import 'localization/locale_manager.dart';
import 'localization/app_strings.dart';
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

  @override
  void initState() {
    super.initState();
    _restoreSession();
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
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: PixelTheme.buildTheme(),
        home: Scaffold(
          backgroundColor: PixelTheme.bgPrimary,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: PixelTheme.accentOrange,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('common_loading'),
                  style: PixelTheme.pixelCaption(
                    fontSize: 10,
                    color: PixelTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

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
              home: _isLoggedIn ? const HomeScreen() : const LoginScreen(),
            );
          },
        );
      },
    );
  }
}