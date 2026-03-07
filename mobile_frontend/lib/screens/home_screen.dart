import 'package:flutter/material.dart';
import 'report_screen.dart';
import 'map_screen.dart';
import 'history_screen.dart';

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF005F52)),
      ),
      home: const HomeScreen(),
    ));

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
    const Center(child: Text('Profile', style: TextStyle(fontSize: 24))),
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
class DashboardContent extends StatelessWidget {
  const DashboardContent({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
                TextButton(onPressed: () {}, child: const Text("View all", style: TextStyle(color: Colors.teal))),
              ],
            ),
          ),
          _buildReportCard("Pothole on Jalan Ampang", "Road Damage • 2h ago", "In Progress", "High", Colors.orange, Colors.red),
          _buildReportCard("Broken streetlight at Taman Melati", "Street Lighting • 5h ago", "Submitted", "Medium", Colors.blue, Colors.orange),
          _buildReportCard("Illegal dumping near Sungai Besi", "Waste Management • 1d ago", "Resolved", "Low", Colors.green, Colors.orange),
          _buildOverviewSection(),
          const SizedBox(height: 20),
        ],
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
                children: const [
                  Text("Welcome back,", style: TextStyle(color: Colors.white70, fontSize: 14)),
                  Text("Mohamad Haikal", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                ],
              ),
              const CircleAvatar(
                backgroundColor: Colors.white24,
                child: Text("AR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              )
            ],
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              _buildStatItem(Icons.description, "24", "Total Reports"),
              _buildStatItem(Icons.access_time, "8", "Pending"),
              _buildStatItem(Icons.check_circle_outline, "14", "Resolved"),
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
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
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
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("City Issue Overview", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 20),
          _buildProgressLine("Road Damage", 0.35, Colors.red),
          _buildProgressLine("Street Lighting", 0.25, Colors.orange),
          _buildProgressLine("Waste Management", 0.20, Colors.teal),
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