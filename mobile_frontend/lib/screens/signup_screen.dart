import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import '../widgets/background_decorator.dart';
import '../localization/app_strings.dart';

/// Signup screen in the "Wellness Calendar" theme.
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
          SnackBar(
            content: Text(
              tr('signup_success'),
              style: PixelTheme.pixelBody(fontSize: 13, color: Colors.white),
            ),
            backgroundColor: PixelTheme.accentGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        );
        Navigator.pop(context);
      } else {
        if (!mounted) return;
        final detail = jsonDecode(response.body)['detail'] ?? tr('common_unknown_error');
        _showError('${tr('signup_failed_prefix')}$detail');
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
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: PixelTheme.primaryGreen),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      extendBodyBehindAppBar: true,
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
                    // Header Logo Box
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: PixelTheme.primaryGreen,
                        shape: BoxShape.circle,
                        boxShadow: PixelTheme.pixelShadow,
                      ),
                      child: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 34,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 20),

                    Text(
                      tr('signup_title'),
                      style: PixelTheme.pixelHeading(
                        fontSize: 22,
                        color: PixelTheme.primaryGreen,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('signup_tagline'),
                      style: PixelTheme.pixelBody(
                        fontSize: 13,
                        color: PixelTheme.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),

                    PixelCard(
                      borderRadius: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Username
                          TextFormField(
                            controller: _usernameController,
                            textInputAction: TextInputAction.next,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_username_label'),
                              hintText: tr('signup_username_hint'),
                              prefixIcon: const Icon(Icons.person_outline_rounded, color: PixelTheme.accentOrange, size: 20),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().length < 2) {
                                return tr('signup_username_error');
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Full Name
                          TextFormField(
                            controller: _fullNameController,
                            textInputAction: TextInputAction.next,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_full_name_label'),
                              hintText: tr('signup_full_name_hint'),
                              prefixIcon: const Icon(Icons.badge_outlined, color: PixelTheme.accentOrange, size: 20),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) return tr('signup_full_name_error');
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // IC Number
                          TextFormField(
                            controller: _icController,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.number,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_ic_number_label'),
                              hintText: tr('signup_ic_hint'),
                              prefixIcon: const Icon(Icons.assignment_ind_outlined, color: PixelTheme.accentOrange, size: 20),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) return tr('signup_ic_required_error');
                              final cleanIc = val.replaceAll(RegExp(r'\D'), '');
                              if (cleanIc.length != 12) return tr('signup_ic_length_error');
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Phone Number
                          TextFormField(
                            controller: _phoneController,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.phone,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_phone_number_label'),
                              hintText: tr('signup_phone_hint'),
                              prefixIcon: const Icon(Icons.phone_outlined, color: PixelTheme.accentOrange, size: 20),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) return tr('signup_phone_error');
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Password
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePw,
                            textInputAction: TextInputAction.next,
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_password_label'),
                              hintText: tr('signup_password_hint'),
                              prefixIcon: const Icon(Icons.lock_outline_rounded, color: PixelTheme.accentOrange, size: 20),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePw ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                  color: PixelTheme.textSecondary,
                                  size: 18,
                                ),
                                onPressed: () => setState(() => _obscurePw = !_obscurePw),
                              ),
                            ),
                            validator: (val) {
                              if (val == null || val.length < 6) return tr('signup_password_error');
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Confirm Password
                          TextFormField(
                            controller: _confirmController,
                            obscureText: _obscureCnf,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _handleSignup(),
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary),
                            decoration: InputDecoration(
                              labelText: tr('field_confirm_password_label'),
                              hintText: tr('signup_confirm_password_hint'),
                              prefixIcon: const Icon(Icons.lock_reset_rounded, color: PixelTheme.accentOrange, size: 20),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureCnf ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                  color: PixelTheme.textSecondary,
                                  size: 18,
                                ),
                                onPressed: () => setState(() => _obscureCnf = !_obscureCnf),
                              ),
                            ),
                            validator: (val) {
                              if (val != _passwordController.text) return tr('signup_confirm_password_error');
                              return null;
                            },
                          ),
                          const SizedBox(height: 24),

                          PixelButton(
                            text: tr('common_create_account'),
                            isLoading: _isLoading,
                            onPressed: _isLoading ? null : _handleSignup,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
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
