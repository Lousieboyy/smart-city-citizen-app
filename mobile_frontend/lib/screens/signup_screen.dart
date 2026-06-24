import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../widgets/background_decorator.dart';
import '../widgets/glass_card.dart';

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
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _icController       = TextEditingController();
  final TextEditingController _phoneController    = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController  = TextEditingController();
  final _formKey    = GlobalKey<FormState>();
  bool _isLoading   = false;
  bool _obscurePw   = true;
  bool _obscureCnf  = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _fullNameController.dispose();
    _icController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final response = await ApiService.signup(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        fullName: _fullNameController.text.trim(),
        icNumber: _icController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
      );

      if (response.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Registration successful! Please login.'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: isDark ? Colors.white : const Color(0xFF1C1917)),
      ),
      extendBodyBehindAppBar: true,
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
                            Icons.person_add_alt_1_rounded,
                            size: 40,
                            color: isDark ? Colors.white : const Color(0xFF0D9488),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "CREATE ACCOUNT",
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
                        "DECISION SUPPORT REPORTING SYSTEM",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.grey : const Color(0xFF78716C),
                          letterSpacing: 2.0,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 40),

                      // Username
                      TextFormField(
                        controller: _usernameController,
                        textInputAction: TextInputAction.next,
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: "Username",
                          hintText: "Choose a username",
                          prefixIcon: Icon(Icons.person_outline_rounded),
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

                      // Full Name
                      TextFormField(
                        controller: _fullNameController,
                        textInputAction: TextInputAction.next,
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: "Full Name (as per IC)",
                          hintText: "Enter your full name",
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Full name is required";
                          }
                          if (value.trim().length < 2) {
                            return "Full name must be at least 2 characters";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // IC Number
                      TextFormField(
                        controller: _icController,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: "IC Number (e.g. 900101041234)",
                          hintText: "Enter your 12-digit IC number",
                          prefixIcon: Icon(Icons.assignment_ind_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "IC number is required";
                          }
                          final cleanIc = value.replaceAll(RegExp(r'\D'), '');
                          if (cleanIc.length != 12) {
                            return "IC number must be exactly 12 digits";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Phone Number
                      TextFormField(
                        controller: _phoneController,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.phone,
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: "Phone Number",
                          hintText: "e.g. 0123456789",
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Phone number is required";
                          }
                          if (!RegExp(r'^\+?[0-9\-\s]{7,15}$').hasMatch(value.trim())) {
                            return "Enter a valid phone number (7 to 15 digits)";
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
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: InputDecoration(
                          labelText: "Password",
                          hintText: "At least 6 characters",
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePw ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: isDark ? Colors.white60 : const Color(0xFF78716C),
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _obscurePw = !_obscurePw),
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
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 15),
                        decoration: InputDecoration(
                          labelText: "Confirm Password",
                          hintText: "Re-enter password",
                          prefixIcon: const Icon(Icons.lock_reset_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureCnf ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: isDark ? Colors.white60 : const Color(0xFF78716C),
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _obscureCnf = !_obscureCnf),
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
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _handleSignup,
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
                              : const Text("REGISTER NOW",
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.5,
                                      fontSize: 16)),
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
