import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_session.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme_manager.dart';

void main() => runApp(const MyApp());

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

  /// Restore the user session from persistent storage on app launch.
  Future<void> _restoreSession() async {
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

    // Restore the theme mode preference
    final isLightTheme = prefs.getBool('is_light_theme') ?? false; // defaults to dark
    ThemeManager.themeModeNotifier.value = isLightTheme ? ThemeMode.light : ThemeMode.dark;

    if (userId != null) {
      // Populate the in-memory singleton so every screen has access immediately.
      UserSession.instance.populate(
        id:                userId,
        name:              username,
        userRole:          role,
        jwtToken:          token,
        customAvatarIndex: avatarIndex,
        userFullName:      fullName,
        userIcNumber:      icNumber,
        userPhoneNumber:   phoneNumber,
        userEmail:         email,
      );
    }

    setState(() {
      _isLoggedIn = userId != null;
      _isLoading  = false;
    });
  }

  static final ThemeData _darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: Colors.white,
      secondary: Color(0xFF888888),
      surface: Color(0xFF121212),
      error: Color(0xFFEF4444),
      brightness: Brightness.dark,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      bodyLarge: TextStyle(color: Color(0xFFF5F5F5)),
      bodyMedium: TextStyle(color: Color(0xFFAAAAAA)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1E1E1E),
      labelStyle: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
      hintStyle: const TextStyle(color: Color(0xFF666666), fontSize: 14),
      prefixIconColor: const Color(0xFFAAAAAA),
      suffixIconColor: const Color(0xFFAAAAAA),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.white24, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.white24, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.white, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: Colors.white),
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white, width: 1.5),
        ),
      ),
    ),
  );

  static final ThemeData _lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.transparent, // let background decorator control it
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF0D9488), // Premium Teal
      secondary: Color(0xFF78716C), // Stone neutral
      surface: Colors.white,
      error: Color(0xFFDC2626), // Red-600
      brightness: Brightness.light,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(color: Color(0xFF1C1917), fontWeight: FontWeight.bold),
      titleLarge: TextStyle(color: Color(0xFF1C1917), fontWeight: FontWeight.bold),
      bodyLarge: TextStyle(color: Color(0xFF1C1917)),
      bodyMedium: TextStyle(color: Color(0xFF44403C)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF5F5F4),
      labelStyle: const TextStyle(color: Color(0xFF78716C), fontSize: 14),
      hintStyle: const TextStyle(color: Color(0xFFA8A29E), fontSize: 14),
      prefixIconColor: const Color(0xFF78716C),
      suffixIconColor: const Color(0xFF78716C),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD6D3D1), width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD6D3D1), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF0D9488), width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: Color(0xFF1C1917)),
      titleTextStyle: TextStyle(
        color: Color(0xFF1C1917),
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: const Color(0xFF0D9488),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeModeNotifier,
      builder: (context, currentThemeMode, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Melaka Smart City Reporting',
          themeMode: ThemeMode.dark, // locked to dark mode
          theme: _lightTheme,
          darkTheme: _darkTheme,
          home: _isLoggedIn ? const HomeScreen() : const LoginScreen(),
        );
      },
    );
  }
}