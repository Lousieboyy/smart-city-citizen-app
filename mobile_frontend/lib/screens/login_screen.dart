import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../user_session.dart';
import 'home_screen.dart';
import 'signup_screen.dart';
import '../widgets/background_decorator.dart';
import '../widgets/glass_card.dart';

/// Login screen.
///
/// CHANGES vs original:
///   F-2  Now saves `role` to SharedPreferences AND into UserSession singleton.
///   F-4  No more `?? 1` fallback — if login succeeds, userId is guaranteed
///        to be a real ID from the server; if it fails we never reach HomeScreen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await ApiService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // FIX F-2 + F-4: Store ALL user fields — including role — in both
        // SharedPreferences (for persistence across app restarts) and the
        // in-memory UserSession singleton (for immediate access this session).
        final int    userId      = data['user_id']  as int;
        final String username    = data['username'] as String;
        final String role        = (data['role']    as String?) ?? 'citizen';
        final String token       = (data['token']   as String?) ?? '';
        final String fullName    = (data['fullName']    as String?) ?? username;
        final String icNumber    = (data['icNumber']    as String?) ?? '';
        final String phoneNumber = (data['phoneNumber'] as String?) ?? '';
        final String email       = (data['email']       as String?) ?? '';

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt   ('user_id',       userId);
        await prefs.setString('username',      username);
        await prefs.setString('role',          role);
        await prefs.setString('token',         token); // JWT token
        await prefs.setString('full_name',     fullName);
        await prefs.setString('ic_number',     icNumber);
        await prefs.setString('phone_number',  phoneNumber);
        await prefs.setString('email',         email);

        // Fetch custom avatar index if it exists in SharedPreferences
        final int? customAvatarIndex = prefs.getInt('avatar_index');

        UserSession.instance.populate(
          id:                userId,
          name:              username,
          userRole:          role,
          jwtToken:          token,
          customAvatarIndex: customAvatarIndex,
          userFullName:      fullName,
          userIcNumber:      icNumber,
          userPhoneNumber:   phoneNumber,
          userEmail:         email,
        );

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      } else {
        if (!mounted) return;
        final detail = jsonDecode(response.body)['detail'] ?? 'Unknown error';
        _showError('Login failed: $detail');
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Cannot connect to server. Check your network and try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: BackgroundDecorator(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Form(
                key: _formKey,
                child: GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                  borderRadius: BorderRadius.circular(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),
                      // Elegant Vector Logo Header
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark ? Colors.black : const Color(0xFFF5F5F4),
                            border: Border.all(color: isDark ? Colors.white : const Color(0xFFD6D3D1), width: 2.0),
                          ),
                          child: Icon(
                            Icons.query_stats_rounded,
                            size: 40,
                            color: isDark ? Colors.white : const Color(0xFF0D9488),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "DECISION SUPPORT",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : const Color(0xFF1C1917),
                          letterSpacing: 2.0,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "REPORTING SYSTEM",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.grey : const Color(0xFF78716C),
                          letterSpacing: 4.0,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 40),

                      // Username field
                      TextFormField(
                        controller: _usernameController,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.text,
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: "Username",
                          hintText: "Enter username",
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Please enter your username";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Password field with show/hide toggle
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _handleLogin(),
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: InputDecoration(
                          labelText: "Password",
                          hintText: "Enter password",
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: isDark ? Colors.white60 : const Color(0xFF78716C),
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.length < 4) {
                            return "Password must be at least 4 characters";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 32),

                      // Login button
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _handleLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                            foregroundColor: isDark ? Colors.black : Colors.white,
                          ),
                          child: _isLoading
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.5, color: isDark ? Colors.black : Colors.white),
                                )
                              : const Text("SIGN IN",
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.5,
                                      fontSize: 16)),
                        ),
                      ),

                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const SignupScreen()),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        child: const Text(
                          "Don't have an account? Sign up",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}