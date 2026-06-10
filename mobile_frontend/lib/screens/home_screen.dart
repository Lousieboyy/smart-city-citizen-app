import 'package:flutter/material.dart';
import 'report_screen.dart';
import 'map_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';

import 'dart:async';
import 'dart:convert';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../user_session.dart';
import 'login_screen.dart';
import '../widgets/glass_card.dart';
import '../widgets/background_decorator.dart';

/// Main shell screen with bottom navigation.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  late final List<Widget> _widgetOptions = [
    const DashboardContent(),
    const MapViewScreen(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  void _onItemTapped(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true, // Allows body widgets (like maps) to sit behind the floating navbar
        body: IndexedStack(
          index: _selectedIndex,
          children: _widgetOptions,
        ),
        bottomNavigationBar: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom > 0
                ? MediaQuery.of(context).padding.bottom
                : 20,
            left: 16,
            right: 16,
          ),
          child: GlassCard(
            color: _selectedIndex == 1
                ? Colors.black.withOpacity(0.88) // High contrast dark backing for map screen
                : Colors.black.withOpacity(0.65), // Darker frosted glass backing for other screens
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(24),
            child: BottomNavigationBar(
              elevation: 0,
              backgroundColor: Colors.transparent,
              type: BottomNavigationBarType.fixed,
              currentIndex: _selectedIndex,
              selectedItemColor: _selectedIndex == 1
                  ? const Color(0xFFA5B4FC) // Lighter indigo for maximum contrast on map tab
                  : const Color(0xFF818CF8),
              unselectedItemColor: _selectedIndex == 1
                  ? Colors.white.withOpacity(0.85) // High-contrast white for unselected items on map screen
                  : Colors.white.withOpacity(0.6), // Brighter unselected label & icon color
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
              onTap: _onItemTapped,
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(Icons.dashboard_rounded), label: 'Home'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.map_rounded), label: 'Map'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.assignment_rounded), label: 'History'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.person_rounded), label: 'Profile'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  DASHBOARD TAB
// ─────────────────────────────────────────────────────────────
class DashboardContent extends StatefulWidget {
  const DashboardContent({super.key});

  @override
  State<DashboardContent> createState() => _DashboardContentState();
}

class _DashboardContentState extends State<DashboardContent> {
  bool _isLoading = true;
  bool _hasError  = false;

  int _totalReports   = 0;
  int _pendingReports = 0;
  int _resolvedReports = 0;
  Map<String, int> _categories = {};
  List<dynamic>    _recentReports = [];

  // ── Notification banner state ──────────────────────────────────────────
  StreamSubscription<StatusChange>? _notifSub;
  StatusChange? _pendingNotif;
  bool _showNotifBanner = false;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();

    // Start polling for status changes and show banner on change
    NotificationService.instance.start(intervalSeconds: 60);
    _notifSub = NotificationService.instance.changes.listen((change) {
      if (!mounted) return;
      setState(() {
        _pendingNotif    = change;
        _showNotifBanner = true;
      });
      // Auto-dismiss after 6 seconds
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) setState(() => _showNotifBanner = false);
      });
      // Refresh dashboard data so the counts update
      _fetchDashboardData();
    });
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchDashboardData() async {
    final session = UserSession.instance;
    if (!session.isLoggedIn) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
      return;
    }

    setState(() { _isLoading = true; _hasError = false; });

    final isWorker = session.role.toLowerCase().contains('worker');

    try {
      if (isWorker) {
        final reportsResponse = await ApiService.getReports(
          role: session.role,
          username: session.username,
        );

        if (reportsResponse.statusCode == 200) {
          final reportsData = jsonDecode(reportsResponse.body) as List;
          setState(() {
            _totalReports    = reportsData.length;
            _pendingReports  = reportsData.where((r) => r['status'] == 'In Process').length;
            _resolvedReports = reportsData.where((r) => r['status'] == 'In Maintenance').length;
            _categories      = {};
            for (var r in reportsData) {
              final cat = r['categories'] ?? 'Other';
              _categories[cat] = (_categories[cat] ?? 0) + 1;
            }
            _recentReports   = reportsData.take(3).toList();
            _isLoading       = false;
          });
        } else {
          throw Exception('Server returned an error');
        }
      } else {
        final statsResponse   = await ApiService.getStats(session.userId!);
        final reportsResponse = await ApiService.getReports(userId: session.userId!);

        if (statsResponse.statusCode == 200 && reportsResponse.statusCode == 200) {
          final statsData   = jsonDecode(statsResponse.body);
          final reportsData = jsonDecode(reportsResponse.body) as List;

          setState(() {
            _totalReports    = statsData['total']    ?? 0;
            _pendingReports  = statsData['pending']  ?? 0;
            _resolvedReports = statsData['resolved'] ?? 0;
            _categories      = Map<String, int>.from(statsData['categories'] ?? {});
            _recentReports   = reportsData.take(3).toList();
            _isLoading       = false;
          });
        } else {
          throw Exception('Server returned an error');
        }
      }
    } catch (_) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
    }
  }

  String _formatTime(String? ts) {
    if (ts == null || ts.isEmpty) return 'Unknown';
    try {
      final dt   = DateTime.parse(ts).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 60) return '${diff.inMinutes == 0 ? 1 : diff.inMinutes}m ago';
      if (diff.inHours   < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return 'Unknown';
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

    if (_hasError) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 64, color: Color(0xFF94A3B8)),
              const SizedBox(height: 16),
              const Text(
                'Could not load dashboard data.',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetchDashboardData,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _fetchDashboardData,
            color: const Color(0xFF818CF8),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(context),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _buildMainActionButton(context),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text(
                          "Recent Reports",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_recentReports.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                      child: Center(
                        child: Text(
                          "No reports submitted yet. Create one!",
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                        ),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: _recentReports.length,
                      itemBuilder: (context, index) {
                        final report = _recentReports[index];
                        final cat     = report['categories'] ?? 'Unknown';
                        final timeAgo = _formatTime(report['timestamp']);
                        final status  = report['status'] ?? 'Pending';

                        // Premium Accent Mapping
                        Color statusColor;
                        if (status == 'Pending') {
                          statusColor = const Color(0xFFD97706); // Amber
                        } else if (status == 'Resolved') {
                          statusColor = const Color(0xFF059669); // Emerald
                        } else {
                          statusColor = const Color(0xFF3B82F6); // Royal Blue
                        }

                        final priority = (cat.contains('Damage') ||
                                cat.contains('Drainage') ||
                                cat.contains('Tree'))
                            ? (status == 'Resolved' ? 'Low' : 'High')
                            : (status == 'Resolved' ? 'Low' : 'Medium');

                        Color priorityColor;
                        if (priority == 'High') {
                          priorityColor = const Color(0xFFEF4444); // Crimson
                        } else if (priority == 'Medium') {
                          priorityColor = const Color(0xFFD97706); // Amber
                        } else {
                          priorityColor = const Color(0xFF059669); // Emerald
                        }

                        return _buildReportCard(
                          report['description']?.toString().isNotEmpty == true
                              ? report['description']
                              : 'Issue Reported',
                          '$cat • $timeAgo',
                          status,
                          priority,
                          statusColor,
                          priorityColor,
                        );
                      },
                    ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _buildOverviewSection(),
                  ),
                  const SizedBox(height: 120), // padding to prevent being hidden by floating nav bar
                ],
              ),
            ),
          ),

          // ── Status-change notification banner ──────────────────────────
          if (_showNotifBanner && _pendingNotif != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: _buildNotificationBanner(_pendingNotif!),
            ),
        ],
      ),
    );
  }

  // ── Notification Banner ────────────────────────────────────────────────

  Widget _buildNotificationBanner(StatusChange change) {
    final isResolved = change.newStatus == 'Resolved';
    final bannerColor = isResolved
        ? const Color(0xFF059669)   // Emerald for resolved
        : const Color(0xFF6366F1);  // Indigo for in-progress

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: bannerColor.withOpacity(0.92),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: bannerColor.withOpacity(0.45),
              blurRadius: 20,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isResolved ? Icons.check_circle_rounded : Icons.update_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Report Status Updated',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${change.category}: ${change.oldStatus} → ${change.newStatus}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _showNotifBanner = false),
              child: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helper Widgets ───────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final username = UserSession.instance.username;
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWorker ? "Field Worker Portal" : "Welcome back,",
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.2),
                ),
                child: Center(
                  child: Text(
                    username.isNotEmpty ? username.substring(0, 1).toUpperCase() : "U",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              _buildStatItem(
                  Icons.assignment_rounded, _totalReports.toString(), isWorker ? "Assigned" : "Total"),
              _buildStatItem(
                  Icons.pending_actions_rounded, _pendingReports.toString(), isWorker ? "In Process" : "Pending"),
              _buildStatItem(
                  Icons.task_alt_rounded, _resolvedReports.toString(), isWorker ? "In Maint." : "Resolved"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label) {
    return Expanded(
      child: GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFF818CF8), size: 20),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainActionButton(BuildContext context) {
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');
    if (isWorker) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.info_outline_rounded, color: Color(0xFF818CF8), size: 20),
            const SizedBox(width: 8),
            Text(
              "You have $_totalReports active task(s) assigned",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CitizenReportScreen()),
        ),
        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white),
        label: const Text(
          "Report an Issue",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  Widget _buildReportCard(String title, String subtitle, String status,
      String priority, Color statusCol, Color priorityCol) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.report_problem_rounded, color: priorityCol, size: 18),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _buildTag(status, statusCol),
              const SizedBox(width: 8),
              _buildTag(priority, priorityCol),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.2), width: 1.0),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildOverviewSection() {
    List<Widget> lines = [];

    if (_totalReports > 0 && _categories.isNotEmpty) {
      final sorted = _categories.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = sorted.take(3).toList();
      final colors = [
        const Color(0xFFEF4444), // Crimson Red
        const Color(0xFFF59E0B), // Amber Orange
        const Color(0xFF06B6D4), // Cyan
      ];

      for (int i = 0; i < top.length; i++) {
        lines.add(_buildProgressLine(
            top[i].key, top[i].value / _totalReports, colors[i]));
      }
    } else {
      lines.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Text(
              "No data available.",
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
            ),
          ),
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "City Issue Overview",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
          ),
          const SizedBox(height: 20),
          ...lines,
        ],
      ),
    );
  }

  Widget _buildProgressLine(String label, double val, Color col) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0), fontWeight: FontWeight.w500),
              ),
              Text(
                "${(val * 100).toInt()}%",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: val,
              backgroundColor: Colors.white.withOpacity(0.08),
              color: col,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}