import 'package:flutter/material.dart';
import 'report_screen.dart';
import 'map_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';

import 'dart:convert';
import '../services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 1. Changed to StatefulWidget to handle tab switching
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0; // Tracks the current active tab

  // 2. List of screens for the navigation
  static final List<Widget> _widgetOptions = <Widget>[
    const DashboardContent(), // Your original UI
    const MapViewScreen(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: _widgetOptions.elementAt(_selectedIndex), // Shows selected screen
      
      // --- BOTTOM NAVIGATION BAR ---
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed, // Keeps labels visible for 4 items
        currentIndex: _selectedIndex,
        selectedItemColor: const Color(0xFF005F52),
        unselectedItemColor: Colors.grey,
        onTap: _onItemTapped,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_outlined),
            label: 'History',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

// 3. Your original UI moved here to keep things clean
class DashboardContent extends StatefulWidget {
  const DashboardContent({super.key});

  @override
  State<DashboardContent> createState() => _DashboardContentState();
}

class _DashboardContentState extends State<DashboardContent> {
  bool _isLoading = true;
  String _username = "Citizen";
  
  // Dashboard stats
  int _totalReports = 0;
  int _pendingReports = 0;
  int _resolvedReports = 0;
  
  // Category stats for progress bars
  Map<String, int> _categories = {};
  
  // Recent reports
  List<dynamic> _recentReports = [];

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  Future<void> _fetchDashboardData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? 1;
      final userName = prefs.getString('username') ?? "Citizen";

      setState(() {
        _username = userName;
      });

      // Fetch stats
      final statsResponse = await ApiService.getStats(userId);
      
      // Fetch recent reports (limit to 3 for dashboard)
      final reportsResponse = await ApiService.getReports(userId: userId);

      if (statsResponse.statusCode == 200 && reportsResponse.statusCode == 200) {
        final statsData = jsonDecode(statsResponse.body);
        final reportsData = jsonDecode(reportsResponse.body) as List;
        
        setState(() {
          _totalReports = statsData['total'] ?? 0;
          _pendingReports = statsData['pending'] ?? 0;
          _resolvedReports = statsData['resolved'] ?? 0;
          _categories = Map<String, int>.from(statsData['categories'] ?? {});
          
          // Take top 3 most recent
          _recentReports = reportsData.take(3).toList();
          _isLoading = false;
        });
      } else {
        throw Exception("Failed to load data");
      }
    } catch (e) {
      debugPrint("Error fetching dashboard data: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _formatTime(String timestampStr) {
    if (timestampStr.isEmpty) return 'Unknown';
    try {
      DateTime dt = DateTime.parse(timestampStr).toLocal();
      Duration diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 60) {
        return '${diff.inMinutes == 0 ? 1 : diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        return '${diff.inHours}h ago';
      } else {
        return '${diff.inDays}d ago';
      }
    } catch (e) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF005F52)));
    }

    return RefreshIndicator(
      onRefresh: _fetchDashboardData,
      color: const Color(0xFF005F52),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _buildHeader(context),
                Positioned(
                  bottom: -10,
                  left: 30,
                  right: 30,
                  child: _buildMainActionButton(context),
                ),
              ],
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Recent Reports",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  TextButton(onPressed: () {
                    // Could navigate to history tab via callback realistically
                  }, child: const Text("View all", style: TextStyle(color: Colors.teal))),
                ],
              ),
            ),
            
            if (_recentReports.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20.0),
                child: Text("No reports submitted yet. Create one!"),
              )
            else
              ..._recentReports.map((report) {
                String cat = report['categories'] ?? 'Unknown';
                String timeAgo = _formatTime(report['timestamp'] ?? '');
                String subtitle = '$cat • $timeAgo';
                String status = report['status'] ?? 'Pending';
                
                Color statusCol = status == 'Pending' ? Colors.orange : (status == 'Resolved' ? Colors.green : Colors.blue);
                
                // Determine priority from category/status simplified
                String priority = status == 'Resolved' ? 'Low' : 'Medium';
                if (cat.contains('Damage') || cat.contains('Drainage') || cat.contains('Tree')) {
                  priority = status == 'Resolved' ? 'Low' : 'High';
                }
                Color priorityCol = priority == 'High' ? Colors.red : (priority == 'Medium' ? Colors.orange : Colors.green);
                
                return _buildReportCard(
                  report['description']?.toString().isNotEmpty == true ? report['description'] : 'Issue Reported',
                  subtitle,
                  status,
                  priority,
                  statusCol,
                  priorityCol
                );
              }).toList(),

            _buildOverviewSection(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // --- ALL YOUR HELPER METHODS (COPIED FROM YOUR CODE) ---
  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 60, 20, 60),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Welcome back,", style: TextStyle(color: Colors.white70, fontSize: 14)),
                  Text(_username, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                ],
              ),
               CircleAvatar(
                backgroundColor: Colors.white24,
                child: Text(_username.isNotEmpty ? _username.substring(0, 1).toUpperCase() : "U", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              )
            ],
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              _buildStatItem(Icons.description, _totalReports.toString(), "Total Reports"),
              _buildStatItem(Icons.access_time, _pendingReports.toString(), "Pending"),
              _buildStatItem(Icons.check_circle_outline, _resolvedReports.toString(), "Resolved"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildMainActionButton(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const CitizenReportScreen())),
      icon: const Icon(Icons.add, color: Colors.white),
      label: const Text("Report an Issue", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF147460),
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
  }

  Widget _buildReportCard(String title, String subtitle, String status, String priority, Color statusCol, Color priorityCol) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Icon(Icons.warning_amber_rounded, color: priorityCol, size: 20),
            ],
          ),
          Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildTag(status, statusCol),
              const SizedBox(width: 8),
              _buildTag(priority, priorityCol),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildOverviewSection() {
    // Generate dynamic category stats
    List<Widget> progressLines = [];
    if (_totalReports > 0 && _categories.isNotEmpty) {
      // Sort categories by count (descending)
      var sortedEntries = _categories.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      
      // Top 3 categories
      var topCategories = sortedEntries.take(3).toList();
      
      List<Color> catColors = [Colors.red, Colors.orange, Colors.teal];
      
      for (int i = 0; i < topCategories.length; i++) {
        var entry = topCategories[i];
        double pct = entry.value / _totalReports;
        progressLines.add(_buildProgressLine(entry.key, pct, catColors[i % catColors.length]));
      }
    } else {
      progressLines.add(const Text("No data available.", style: TextStyle(color: Colors.grey)));
    }

    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("City Issue Overview", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 20),
          ...progressLines,
        ],
      ),
    );
  }

  Widget _buildProgressLine(String label, double val, Color col) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
              Text("${(val * 100).toInt()}%", style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: val, backgroundColor: Colors.grey[200], color: col, minHeight: 6),
        ],
      ),
    );
  }
}