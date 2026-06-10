import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_session.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

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
  ///
  /// CHANGE: Now also restores `role` and `username` into the UserSession
  /// singleton (F-2 + F-4..F-7). If userId is null the user is sent to login.
  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final userId   = prefs.getInt('user_id');
    final username = prefs.getString('username') ?? 'Citizen';
    final role     = prefs.getString('role')     ?? 'citizen';
    final token    = prefs.getString('token');  // JWT token

    if (userId != null) {
      // Populate the in-memory singleton so every screen has access immediately.
      UserSession.instance.populate(
        id:       userId,
        name:     username,
        userRole: role,
        jwtToken: token,
      );
    }

    setState(() {
      _isLoggedIn = userId != null;
      _isLoading  = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart City App',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFF8B5CF6),
          surface: Colors.transparent,
          error: const Color(0xFFEF4444),
          brightness: Brightness.dark,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          bodyLarge: TextStyle(color: Color(0xFFE2E8F0)),
          bodyMedium: TextStyle(color: Color(0xFF94A3B8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
          prefixIconColor: const Color(0xFF94A3B8),
          suffixIconColor: const Color(0xFF94A3B8),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.12), width: 1.0),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.0),
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
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: _isLoggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}