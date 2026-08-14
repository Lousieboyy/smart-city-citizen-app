import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import '../services/api_service.dart';
import '../user_session.dart';
import 'login_screen.dart';
import '../widgets/glass_card.dart';
import '../localization/app_strings.dart';
import '../localization/locale_manager.dart';
import '../notification_settings.dart';

/// Profile screen.
class ProfileScreen extends StatefulWidget {
  /// Called when the "Total Reports" stat is tapped, so Home can switch to
  /// History instead of just telling the user to do it themselves.
  final VoidCallback? onViewReportsTap;

  const ProfileScreen({super.key, this.onViewReportsTap});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int  _totalReports    = 0;
  int  _resolvedReports = 0;
  bool _isLoading = true;

  String get _username => UserSession.instance.username;
  String get _role     => UserSession.instance.role;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final session = UserSession.instance;
    if (!session.isLoggedIn) {
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
      return;
    }

    final isWorker = session.role.toLowerCase().contains('worker');

    try {
      if (isWorker) {
        final res = await ApiService.getReports(
          role: session.role,
          username: session.username,
        );
        if (res.statusCode == 200) {
          final reportsData = jsonDecode(res.body) as List;
          setState(() {
            _totalReports    = reportsData.length;
            _resolvedReports = reportsData.where((r) => r['status'] == 'In Maintenance').length;
            _isLoading       = false;
          });
        } else {
          setState(() => _isLoading = false);
        }
      } else {
        final res = await ApiService.getStats(session.userId!);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          setState(() {
            _totalReports    = data['total']    ?? 0;
            _resolvedReports = data['resolved'] ?? 0;
            _isLoading       = false;
          });
        } else {
          setState(() => _isLoading = false);
        }
      }
    } catch (e) {
      debugPrint('Profile stats error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _logout() async {
    PixelDialog.show(
      context: context,
      title: tr('profile_signout_title'),
      bodyText: tr('profile_signout_body'),
      cancelText: tr('common_cancel'),
      confirmText: tr('profile_signout_confirm'),
      headerColor: PixelTheme.alertRed,
      confirmButtonColor: PixelTheme.alertRed,
      onConfirm: () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('user_id');
        await prefs.remove('username');
        await prefs.remove('role');
        await prefs.remove('token');
        await prefs.remove('full_name');
        await prefs.remove('ic_number');
        await prefs.remove('phone_number');
        await prefs.remove('email');
        UserSession.instance.clear();

        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
          );
        }
      },
    );
  }

  Future<void> _pickCustomPhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 600, maxHeight: 600, imageQuality: 85);
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final base64Str = base64Encode(bytes);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('custom_photo_base64', base64Str);
        await prefs.remove('avatar_index');
        setState(() {
          UserSession.instance.customPhotoBase64 = base64Str;
          UserSession.instance.avatarIndex = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('profile_photo_updated')),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Profile] Error picking photo: $e');
    }
  }

  Future<void> _showAvatarOptionsModal() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: PixelTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined, color: PixelTheme.accentOrange),
                  title: Text(tr('profile_upload_own_photo'), style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary)),
                  onTap: () {
                    Navigator.pop(context);
                    _pickCustomPhoto();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.grid_view_rounded, color: PixelTheme.accentCyan),
                  title: Text(tr('profile_choose_preset_avatar'), style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary)),
                  onTap: () {
                    Navigator.pop(context);
                    _showAvatarSelectionDialog();
                  },
                ),
                if (UserSession.instance.customPhotoBase64 != null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    title: Text(tr('profile_remove_custom_photo'), style: PixelTheme.pixelBody(fontSize: 14, color: Colors.redAccent)),
                    onTap: () async {
                      Navigator.pop(context);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove('custom_photo_base64');
                      setState(() {
                        UserSession.instance.customPhotoBase64 = null;
                      });
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAvatarSelectionDialog() async {
    final selectedIndex = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: PixelTheme.bgSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            tr('profile_choose_preset_avatar'),
            style: PixelTheme.pixelHeading(fontSize: 16, color: PixelTheme.textPrimary),
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: 18,
              itemBuilder: (context, index) {
                final avatarIdx = index + 1;
                final avatarPath = 'assets/avatars/avatar_$avatarIdx.png';
                final isCurrent = UserSession.instance.avatarIndex == avatarIdx;

                return GestureDetector(
                  onTap: () => Navigator.pop(context, avatarIdx),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCurrent ? PixelTheme.accentOrange : Colors.transparent,
                        width: 3.0,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2.0),
                      child: ClipOval(
                        child: Image.asset(
                          avatarPath,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('common_cancel')),
            ),
          ],
        );
      },
    );

    if (selectedIndex != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('avatar_index', selectedIndex);
      await prefs.remove('custom_photo_base64');
      setState(() {
        UserSession.instance.avatarIndex = selectedIndex;
        UserSession.instance.customPhotoBase64 = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('profile_avatar_updated')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showEditProfileModal() {
    final usernameCtrl = TextEditingController(text: UserSession.instance.username);
    final fullNameCtrl = TextEditingController(text: UserSession.instance.fullName);
    final icNumberCtrl = TextEditingController(text: UserSession.instance.icNumber);
    final phoneCtrl    = TextEditingController(text: UserSession.instance.phoneNumber);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: PixelTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('profile_edit_details_title'),
                  style: PixelTheme.pixelHeading(fontSize: 17, color: PixelTheme.primaryGreen),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: usernameCtrl,
                  decoration: InputDecoration(labelText: tr('field_username_label')),
                  style: const TextStyle(color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: fullNameCtrl,
                  decoration: InputDecoration(labelText: tr('field_full_name_label')),
                  style: const TextStyle(color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: icNumberCtrl,
                  decoration: InputDecoration(labelText: tr('field_ic_number_label')),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  decoration: InputDecoration(labelText: tr('field_phone_number_label')),
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () async {
                    final newUsername = usernameCtrl.text.trim();
                    final newFullName = fullNameCtrl.text.trim();
                    final newIc       = icNumberCtrl.text.trim();
                    final newPhone    = phoneCtrl.text.trim();

                    if (newUsername.isEmpty) return;

                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('username', newUsername);
                    await prefs.setString('full_name', newFullName);
                    await prefs.setString('ic_number', newIc);
                    await prefs.setString('phone_number', newPhone);

                    setState(() {
                      UserSession.instance.username    = newUsername;
                      UserSession.instance.fullName    = newFullName;
                      UserSession.instance.icNumber    = newIc;
                      UserSession.instance.phoneNumber = newPhone;
                    });

                    if (context.mounted) Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: PixelTheme.accentOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(tr('common_save_changes')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: CircularProgressIndicator(color: PixelTheme.accentOrange),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Profile header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 64, 24, 20),
              child: Column(
                children: [
                  Stack(
                    children: [
                      GestureDetector(
                        onTap: _showAvatarOptionsModal,
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x40E08A5B),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: PixelTheme.accentOrange, width: 2.5),
                            ),
                            child: ClipOval(
                              child: getAvatarImageWidget(_username),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _showAvatarOptionsModal,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: PixelTheme.accentOrange,
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: const Icon(
                              Icons.camera_alt_outlined,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(_username,
                      style: PixelTheme.pixelHeading(fontSize: 18, color: PixelTheme.textPrimary)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: PixelTheme.accentOrange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      tr('role_${_role.toLowerCase()}'),
                      style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.accentOrange),
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _showEditProfileModal,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(tr('profile_edit_profile')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: PixelTheme.primaryGreen,
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        _buildQuickStat(
                          context,
                          '$_totalReports',
                          _role.toLowerCase().contains('worker') ? tr('profile_active_tasks') : tr('profile_total_reports'),
                          PixelTheme.accentOrange,
                          onTap: widget.onViewReportsTap,
                        ),
                        const SizedBox(width: 14),
                        _buildQuickStat(
                          context,
                          '$_resolvedReports',
                          _role.toLowerCase().contains('worker') ? tr('profile_completed') : trStatus('Resolved'),
                          PixelTheme.accentGreen,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Profile Information section
            _buildSectionHeader(tr('profile_information_section')),
            _buildMenuCard([
              _buildMenuItem(
                Icons.person_outline,
                tr('field_username_label'),
                trailingText: UserSession.instance.username,
              ),
              _buildMenuItem(
                Icons.badge_outlined,
                tr('field_full_name_label'),
                trailingText: UserSession.instance.fullName.isEmpty
                    ? tr('common_not_available')
                    : UserSession.instance.fullName,
              ),
              _buildMenuItem(
                Icons.fingerprint_rounded,
                tr('field_ic_number_label'),
                trailingText: UserSession.instance.icNumber.isEmpty
                    ? tr('common_not_available')
                    : UserSession.instance.icNumber,
              ),
              _buildMenuItem(
                Icons.phone_outlined,
                tr('field_phone_number_label'),
                trailingText: UserSession.instance.phoneNumber.isEmpty
                    ? tr('common_not_available')
                    : UserSession.instance.phoneNumber,
              ),
            ]),

            // Preferences section
            _buildSectionHeader(tr('profile_preferences_section')),
            _buildMenuCard([
              ValueListenableBuilder<String>(
                valueListenable: LocaleManager.localeNotifier,
                builder: (context, locale, _) => _buildMenuItem(
                  Icons.language_rounded,
                  tr('profile_language'),
                  trailingText: locale == 'bm' ? tr('profile_language_bm') : tr('profile_language_en'),
                  onTap: () => LocaleManager.toggleLocale(),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: NotificationSettings.enabledNotifier,
                builder: (context, enabled, _) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: PixelTheme.accentOrange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.notifications_none_rounded, color: PixelTheme.accentOrange, size: 18),
                  ),
                  title: Text(tr('profile_notifications'),
                      style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600)),
                  trailing: Switch.adaptive(
                    value: enabled,
                    activeTrackColor: PixelTheme.accentOrange,
                    onChanged: (_) => NotificationSettings.toggle(),
                  ),
                ),
              ),
            ]),

            // About section
            _buildSectionHeader(tr('profile_about_section')),
            _buildMenuCard([
              _buildMenuItem(Icons.shield_outlined, tr('profile_privacy_policy'), onTap: () {
                _showInfoDialog(tr('profile_privacy_policy'), tr('profile_privacy_policy_body'));
              }),
              _buildMenuItem(Icons.info_outline_rounded, tr('profile_about_app'),
                  trailingText: "v1.1.0", onTap: () {
                showAboutDialog(
                  context: context,
                  applicationName: 'Decision Support Reporting System',
                  applicationVersion: '1.1.0',
                  applicationLegalese: '© 2026 Decision Support Reporting System',
                );
              }),
            ]),

            // Log out button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              child: PixelButton(
                text: tr('profile_log_out'),
                color: PixelTheme.alertRed,
                icon: Icons.logout_rounded,
                height: 54,
                fontSize: 12,
                onPressed: _logout,
              ),
            ),
            const SizedBox(height: 140), // padding for floating bottom navigation bar
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _buildQuickStat(BuildContext context, String value, String label, Color accentColor, {VoidCallback? onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: PixelCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
                child: Column(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        onTap != null ? Icons.assignment_rounded : Icons.check_circle_rounded,
                        color: accentColor,
                        size: 17,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      value,
                      style: PixelTheme.pixelHeading(fontSize: 20, color: PixelTheme.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.textSecondary),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (onTap != null) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right_rounded, size: 12, color: PixelTheme.textMuted),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(24, 24, 20, 10),
      child: Text(title, style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary)),
    );
  }

  Widget _buildMenuCard(List<Widget> children) {
    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: EdgeInsets.zero,
      child: Column(children: children),
    );
  }

  Widget _buildMenuItem(IconData icon, String title,
      {String? trailingText, VoidCallback? onTap}) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: PixelTheme.accentOrange.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: PixelTheme.accentOrange, size: 18),
      ),
      title: Text(title,
          style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Text(trailingText,
                style: PixelTheme.pixelBody(color: PixelTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w500)),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: PixelTheme.textMuted, size: 20),
          ],
        ],
      ),
      onTap: onTap,
    );
  }

  void _showInfoDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: PixelTheme.bgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(title,
            style: PixelTheme.pixelHeading(fontSize: 16, color: PixelTheme.textPrimary)),
        content: Text(message, style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('common_ok')),
          ),
        ],
      ),
    );
  }
}