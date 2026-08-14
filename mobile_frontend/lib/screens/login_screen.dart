import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../user_session.dart';
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import '../widgets/background_decorator.dart';
import '../localization/app_strings.dart';
import 'home_screen.dart';
import 'signup_screen.dart';

/// Login screen in the "Wellness Calendar" theme.
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
        await prefs.setString('token',         token);
        await prefs.setString('full_name',     fullName);
        await prefs.setString('ic_number',     icNumber);
        await prefs.setString('phone_number',  phoneNumber);
        await prefs.setString('email',         email);

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
        final detail = jsonDecode(response.body)['detail'] ?? tr('common_unknown_error');
        _showError('${tr('login_failed_prefix')}$detail');
      }
    } catch (e) {
      if (!mounted) return;
      _showError(tr('login_connection_error'));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: PixelTheme.pixelBody(fontSize: 13, color: Colors.white),
        ),
        backgroundColor: PixelTheme.alertRed,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PixelTheme.bgPrimary,
      body: BackgroundDecorator(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    // ── 1. Compact Brand Block (logo + wordmark + tagline) ────
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: PixelTheme.primaryGreen,
                            shape: BoxShape.circle,
                            boxShadow: PixelTheme.pixelShadow,
                          ),
                          child: const Icon(
                            Icons.apartment_rounded,
                            size: 28,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Smart City",
                              style: PixelTheme.pixelHeading(
                                fontSize: 20,
                                color: PixelTheme.primaryGreen,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tr('login_tagline'),
                              style: PixelTheme.pixelBody(
                                fontSize: 13,
                                color: PixelTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),

                    // ── 2. Login Card Container ────────────────────────
                    PixelCard(
                      borderRadius: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Username Field
                          TextFormField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_username_label'),
                              hintText: tr('login_username_hint'),
                              prefixIcon: const Icon(
                                Icons.person_outline_rounded,
                                color: PixelTheme.accentOrange,
                                size: 20,
                              ),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return tr('login_username_error');
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Password Field
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _handleLogin(),
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_password_label'),
                              hintText: tr('login_password_hint'),
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                color: PixelTheme.accentOrange,
                                size: 20,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: PixelTheme.textSecondary,
                                  size: 18,
                                ),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            validator: (val) {
                              if (val == null || val.length < 4) {
                                return tr('login_password_error');
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),

                          // Forgot Password Link
                          Align(
                            alignment: Alignment.centerRight,
                            child: GestureDetector(
                              onTap: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr('login_forgot_password_snack'),
                                      style: PixelTheme.pixelBody(fontSize: 13, color: Colors.white),
                                    ),
                                    backgroundColor: PixelTheme.surfaceDark,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                );
                              },
                              child: Text(
                                tr('login_forgot_password'),
                                style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.accentOrange),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Action Button
                          PixelButton(
                            text: tr('login_button_enter'),
                            isLoading: _isLoading,
                            onPressed: _isLoading ? null : _handleLogin,
                          ),
                          const SizedBox(height: 22),

                          // Sign Up Link
                          Center(
                            child: GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const SignupScreen()),
                              ),
                              child: RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '${tr('login_signup_prompt')} ',
                                      style: PixelTheme.pixelCaption(
                                        fontSize: 13,
                                        color: PixelTheme.textSecondary,
                                      ),
                                    ),
                                    TextSpan(
                                      text: tr('common_sign_up'),
                                      style: PixelTheme.pixelCaption(
                                        fontSize: 13,
                                        color: PixelTheme.accentOrange,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // ── 4. Footer Version Label ───────────────────────────────
                    Text(
                      "Smart City · v1.0",
                      style: PixelTheme.pixelCaption(
                        fontSize: 11,
                        color: PixelTheme.textMuted,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
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