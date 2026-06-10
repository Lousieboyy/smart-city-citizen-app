import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../user_session.dart';
import 'home_screen.dart';

/// Sign-up screen.
///
/// CHANGES vs original:
///   F-2  Now saves `role` ('citizen') to SharedPreferences and UserSession.
///   F-4  userId comes from the server response — never defaults to 1.
///   UX   Added password visibility toggle and confirm-password validation.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController  = TextEditingController();
  final _formKey    = GlobalKey<FormState>();
  bool _isLoading   = false;
  bool _obscurePw   = true;
  bool _obscureCnf  = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await ApiService.signup(
        _usernameController.text.trim(),
        _passwordController.text,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // FIX F-2 + F-4: persist and populate all user fields including role.
        final int    userId   = data['user_id'] as int;
        final String username = _usernameController.text.trim();
        const String role     = 'citizen'; // new accounts are always citizens

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt   ('user_id',  userId);
        await prefs.setString('username', username);
        await prefs.setString('role',     role);

        UserSession.instance.populate(id: userId, name: username, userRole: role);

        if (!mounted) return;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false,
        );
      } else {
        if (!mounted) return;
        final detail = jsonDecode(response.body)['detail'] ?? 'Unknown error';
        _showError('Signup failed: $detail');
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF090D1A), Color(0xFF1E1B4B), Color(0xFF312E81)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.person_add_alt_1_rounded, size: 64, color: Colors.white),
                    const SizedBox(height: 16),
                    const Text(
                      "Create Account",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1.0,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Join the Smart City reporting network",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white54,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 36),

                    // Username
                    TextFormField(
                      controller: _usernameController,
                      textInputAction: TextInputAction.next,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        labelText: "Username",
                        labelStyle: const TextStyle(color: Colors.white70, fontSize: 14),
                        hintText: "Choose a username",
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                        prefixIcon: const Icon(Icons.person_outline_rounded, color: Colors.white70),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white12, width: 1.0),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF818CF8), width: 1.5),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.0),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().length < 2) {
                          return "Username must be at least 2 characters";
                        }
                        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value.trim())) {
                          return "Only letters, numbers and underscores are allowed";
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Password
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePw,
                      textInputAction: TextInputAction.next,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        labelText: "Password",
                        labelStyle: const TextStyle(color: Colors.white70, fontSize: 14),
                        hintText: "At least 6 characters",
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                        prefixIcon: const Icon(Icons.lock_outline_rounded, color: Colors.white70),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePw ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            color: Colors.white60,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _obscurePw = !_obscurePw),
                        ),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white12, width: 1.0),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF818CF8), width: 1.5),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.0),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return "Password must be at least 6 characters";
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Confirm password
                    TextFormField(
                      controller: _confirmController,
                      obscureText: _obscureCnf,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _handleSignup(),
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        labelText: "Confirm Password",
                        labelStyle: const TextStyle(color: Colors.white70, fontSize: 14),
                        hintText: "Re-enter password",
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                        prefixIcon: const Icon(Icons.lock_reset_rounded, color: Colors.white70),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureCnf ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            color: Colors.white60,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _obscureCnf = !_obscureCnf),
                        ),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white12, width: 1.0),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF818CF8), width: 1.5),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.0),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value != _passwordController.text) {
                          return "Passwords do not match";
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 32),

                    // Sign up button
                    Container(
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF4F46E5).withOpacity(0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleSignup,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white),
                              )
                            : const Text("REGISTER NOW",
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                    fontSize: 15)),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
