import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _username = 'Citizen';
  int _totalReports = 0;
  int _resolvedReports = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? 1;
      final userName = prefs.getString('username') ?? 'Citizen';

      setState(() {
        _username = userName;
      });

      final statsResponse = await ApiService.getStats(userId);

      if (statsResponse.statusCode == 200) {
        final statsData = jsonDecode(statsResponse.body);
        setState(() {
          _totalReports = statsData['total'] ?? 0;
          _resolvedReports = statsData['resolved'] ?? 0;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching profile stats: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF005F52)));
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          // Header Section with Gradient
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 40),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF01262E), Color(0xFF005F52)],
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Column(
              children: [
                 CircleAvatar(
                  radius: 45,
                  backgroundColor: Colors.white24,
                  child: Text(_username.isNotEmpty ? _username.substring(0, 1).toUpperCase() : "U", style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 15),
                Text(_username, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                const Text("citizen@smartcity.gov", style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 25),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildQuickStat("$_totalReports", "Reports"),
                    _buildQuickStat("$_resolvedReports", "Resolved"),
                  ],
                ),
              ],
            ),
          ),

          // PREFERENCES Section
          _buildSectionHeader("PREFERENCES"),
          _buildMenuCard([
            _buildMenuItem(Icons.language, "Language", trailingText: "English"),
            _buildMenuItem(Icons.notifications_none_rounded, "Notifications", trailingText: "Enabled"),
          ]),

          // ACTIVITY Section
          _buildSectionHeader("ACTIVITY"),
          _buildMenuCard([
            _buildMenuItem(Icons.description_outlined, "My Reports", trailingText: "$_totalReports"),
            _buildMenuItem(Icons.workspace_premium_outlined, "Citizen Score", trailingText: _resolvedReports > 5 ? "Gold" : "Silver"),
          ]),

          // ABOUT Section
          _buildSectionHeader("ABOUT"),
          _buildMenuCard([
            _buildMenuItem(Icons.shield_outlined, "Privacy Policy"),
            _buildMenuItem(Icons.info_outline, "About App", trailingText: "v1.0.0"),
          ]),

          // Logout Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
            child: OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 55),
                side: const BorderSide(color: Colors.redAccent, width: 0.8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
                  SizedBox(width: 10),
                  Text("Log Out", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // --- REUSABLE HELPER WIDGETS ---

  Widget _buildQuickStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(25, 25, 20, 10),
      child: Text(
        title,
        style: const TextStyle(color: Colors.blueGrey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1),
      ),
    );
  }

  Widget _buildMenuCard(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildMenuItem(IconData icon, String title, {String? trailingText}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 2),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: const Color(0xFFF0F4F4), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: const Color(0xFF005F52), size: 20),
      ),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null) 
            Text(trailingText, style: const TextStyle(color: Colors.grey, fontSize: 14)),
          const SizedBox(width: 5),
          const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
        ],
      ),
      onTap: () {
        // Handle navigation
      },
    );
  }
}