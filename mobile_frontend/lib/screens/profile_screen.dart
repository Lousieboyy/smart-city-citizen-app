import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../user_session.dart';
import 'login_screen.dart';
import '../widgets/glass_card.dart';

/// Profile screen.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Log Out',
            style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1917))),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

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
  }

  Future<void> _showAvatarSelectionDialog() async {
    final selectedIndex = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          title: Text(
            'Choose Avatar',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF1C1917),
            ),
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
                final isCurrent = UserSession.instance.avatarIndex == avatarIdx ||
                    (UserSession.instance.avatarIndex == null &&
                        getAvatarPath(_username) == avatarPath);

                return GestureDetector(
                  onTap: () => Navigator.pop(context, avatarIdx),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCurrent
                            ? (isDark ? Colors.white : const Color(0xFF0D9488))
                            : Colors.transparent,
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
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (selectedIndex != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('avatar_index', selectedIndex);
      setState(() {
        UserSession.instance.avatarIndex = selectedIndex;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Avatar updated successfully!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
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
                        onTap: _showAvatarSelectionDialog,
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : const Color(0xFFD6D3D1),
                              width: 2.0,
                            ),
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              getAvatarPath(_username),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _showAvatarSelectionDialog,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : const Color(0xFF0D9488),
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: Icon(
                              Icons.edit,
                              size: 14,
                              color: Theme.of(context).brightness == Brightness.dark
                                  ? Colors.black
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(_username,
                      style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1917),
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark ? Colors.black : const Color(0xFFF5F5F4),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white30 : const Color(0xFFD6D3D1), width: 1.0),
                    ),
                    child: Text(
                      _role.toUpperCase(),
                      style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF78716C),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2),
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
                          _role.toLowerCase().contains('worker') ? 'Active Tasks' : 'Total Reports',
                          Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF0D9488),
                        ),
                        const SizedBox(width: 14),
                        _buildQuickStat(
                          context,
                          '$_resolvedReports',
                          _role.toLowerCase().contains('worker') ? 'Completed' : 'Resolved',
                          Theme.of(context).brightness == Brightness.dark ? const Color(0xFF34D399) : const Color(0xFF059669),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Profile Information section
            _buildSectionHeader("PROFILE INFORMATION"),
            _buildMenuCard([
              _buildMenuItem(
                Icons.badge_outlined,
                "Full Name",
                trailingText: UserSession.instance.fullName.isEmpty
                    ? "N/A"
                    : UserSession.instance.fullName,
              ),
              _buildMenuItem(
                Icons.fingerprint_rounded,
                "IC Number",
                trailingText: UserSession.instance.icNumber.isEmpty
                    ? "N/A"
                    : UserSession.instance.icNumber,
              ),
              _buildMenuItem(
                Icons.phone_outlined,
                "Phone Number",
                trailingText: UserSession.instance.phoneNumber.isEmpty
                    ? "N/A"
                    : UserSession.instance.phoneNumber,
              ),

            ]),

            // Preferences section
            _buildSectionHeader("PREFERENCES"),
            _buildMenuCard([
              _buildMenuItem(Icons.language_rounded, "Language",
                  trailingText: "English", onTap: () {
                _showInfoDialog("Language",
                    "Language selection will be available in the next update.");
              }),
              _buildMenuItem(Icons.notifications_none_rounded, "Notifications",
                  trailingText: "Enabled", onTap: () {
                _showInfoDialog("Notifications",
                    "Notification settings will be available soon.");
              }),
            ]),

            // Activity section
            _buildSectionHeader("ACTIVITY"),
            _buildMenuCard([
              _buildMenuItem(Icons.description_outlined, "My Reports",
                  trailingText: '$_totalReports', onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      'Use the History tab at the bottom to view your reports.'),
                  behavior: SnackBarBehavior.floating,
                ));
              }),
            ]),

            // About section
            _buildSectionHeader("ABOUT"),
            _buildMenuCard([
              _buildMenuItem(Icons.shield_outlined, "Privacy Policy", onTap: () {
                _showInfoDialog("Privacy Policy",
                    "Privacy Policy details will be updated shortly.");
              }),
              _buildMenuItem(Icons.info_outline_rounded, "About App",
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
              child: OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 54),
                  side: const BorderSide(color: Colors.redAccent, width: 1.0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  backgroundColor: Colors.redAccent.withOpacity(0.05),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.logout_rounded, color: Colors.redAccent, size: 18),
                    SizedBox(width: 8),
                    Text("LOG OUT",
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            letterSpacing: 0.5)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 120), // padding for floating bottom navigation bar
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _buildQuickStat(BuildContext context, String value, String label, Color accentColor) {
    return Expanded(
      child: Container(
        margin: EdgeInsets.zero,
        child: SizedBox(
          width: double.infinity,
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            margin: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(8),
            borderColor: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : const Color(0xFFE7E5E4),
            child: Column(
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1917),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark ? Colors.grey : const Color(0xFF78716C),
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(24, 24, 20, 10),
      child: Text(title,
          style: TextStyle(
              color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF78716C),
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1)),
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
          color: Theme.of(context).brightness == Brightness.dark ? Colors.black : const Color(0xFFF5F5F4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : const Color(0xFFD6D3D1), width: 1.5),
        ),
        child: Icon(icon, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF0D9488), size: 18),
      ),
      title: Text(title,
          style:
              TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1917))),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Text(trailingText,
                style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.grey : const Color(0xFF78716C), fontSize: 13, fontWeight: FontWeight.w500)),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: Theme.of(context).brightness == Brightness.dark ? Colors.white30 : const Color(0xFFA8A29E), size: 20),
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
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF1C1917))),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }
}