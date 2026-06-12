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
        title: const Text('Log Out',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
    await prefs.clear();
    UserSession.instance.clear();

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF818CF8)),
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
                    alignment: Alignment.center,
                    children: [
                      // Avatar background glow
                      Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF818CF8).withOpacity(0.35),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF818CF8), Color(0xFFC084FC)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF818CF8).withOpacity(0.3),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ],
                          border: Border.all(color: Colors.white.withOpacity(0.35), width: 2.0),
                        ),
                        child: Center(
                          child: Text(
                            _username.isNotEmpty
                                ? _username.substring(0, 1).toUpperCase()
                                : "U",
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 36,
                                fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF818CF8).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFA5B4FC).withOpacity(0.35), width: 1.0),
                        ),
                        child: Text(
                          _role.toUpperCase(),
                          style: const TextStyle(
                              color: Color(0xFFE0E7FF),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _username,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
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
                          const Color(0xFF818CF8),
                        ),
                        const SizedBox(width: 14),
                        _buildQuickStat(
                          context,
                          '$_resolvedReports',
                          _role.toLowerCase().contains('worker') ? 'Completed' : 'Resolved',
                          const Color(0xFF34D399),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

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
              _buildMenuItem(Icons.workspace_premium_outlined, "Citizen Score",
                  trailingText: _resolvedReports > 5 ? "Gold" : "Silver",
                  onTap: () {
                _showInfoDialog(
                  "Citizen Score",
                  "You are ranked as ${_resolvedReports > 5 ? 'Gold' : 'Silver'}. "
                      "Keep reporting and resolving issues to level up!",
                );
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
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Centered underlay glow
            Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withOpacity(0.15),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                margin: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(16),
                borderColor: accentColor.withOpacity(0.2),
                child: Column(
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        shadows: [
                          Shadow(
                            color: accentColor.withOpacity(0.35),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
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
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(24, 24, 20, 10),
      child: Text(title,
          style: const TextStyle(
              color: Color(0xFF818CF8),
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
          color: const Color(0xFF818CF8).withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF818CF8).withOpacity(0.2), width: 1),
        ),
        child: Icon(icon, color: const Color(0xFF818CF8), size: 18),
      ),
      title: Text(title,
          style:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Text(trailingText,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B), size: 20),
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
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white)),
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