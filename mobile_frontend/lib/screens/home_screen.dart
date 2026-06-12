import 'package:flutter/material.dart';
import 'report_screen.dart';
import 'map_screen.dart';
import 'history_screen.dart';
import 'profile_screen.dart';
import 'report_detail_screen.dart';
import '../app_config.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
  bool _hasUnreadNotification = false;
  StreamSubscription<StatusChange>? _notifSub;

  late final List<Widget> _widgetOptions = [
    const DashboardContent(),
    const MapViewScreen(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Start listening to notification updates to badge the History tab
    _notifSub = NotificationService.instance.changes.listen((change) {
      if (!mounted) return;
      setState(() {
        _hasUnreadNotification = true;
      });
    });
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      if (index == 2) {
        _hasUnreadNotification = false;
      }
    });
  }

  Widget _buildActiveTabIcon(IconData icon, Color activeColor, {bool showBadge = false}) {
    return SizedBox(
      width: 32,
      height: 34,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          // Shadow at the bottom
          Positioned(
            bottom: 1,
            child: Container(
              width: 10,
              height: 2.5,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: const BorderRadius.all(Radius.elliptical(5, 1.25)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.6),
                    blurRadius: 1.5,
                    spreadRadius: 0.5,
                  ),
                ],
              ),
            ),
          ),
          // Floating Teardrop Pin
          Positioned(
            top: 0,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Rotated Teardrop base
                Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: activeColor.withOpacity(0.25),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        topRight: Radius.circular(10),
                        bottomLeft: Radius.circular(10),
                        bottomRight: Radius.zero,
                      ),
                      border: Border.all(
                        color: activeColor, // Glowing border matches active tab color
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: activeColor.withOpacity(0.4),
                          blurRadius: 4,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                  ),
                ),
                // Icon
                Positioned.fill(
                  child: Center(
                    child: Transform.rotate(
                      angle: -math.pi / 4,
                      child: Icon(
                        icon,
                        color: Colors.white,
                        size: 11,
                      ),
                    ),
                  ),
                ),
                // Glowing notification dot (new symbol)
                if (showBadge)
                  Positioned(
                    top: -3,
                    right: -3,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444), // glowing red dot
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 0.8),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFEF4444).withOpacity(0.7),
                            blurRadius: 4,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInactiveTabIcon(IconData icon, {bool showBadge = false}) {
    if (!showBadge) {
      return Icon(icon);
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        Positioned(
          top: -2,
          right: -2,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFEF4444).withOpacity(0.7),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = _selectedIndex == 1
        ? const Color(0xFFA5B4FC)
        : const Color(0xFF818CF8);

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
              selectedItemColor: activeColor,
              unselectedItemColor: _selectedIndex == 1
                  ? Colors.white.withOpacity(0.85) // High-contrast white for unselected items on map screen
                  : Colors.white.withOpacity(0.6), // Brighter unselected label & icon color
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
              onTap: _onItemTapped,
              items: [
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.dashboard_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.dashboard_rounded, activeColor),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.map_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.map_rounded, activeColor),
                  label: 'Map',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.assignment_rounded, showBadge: _hasUnreadNotification),
                  activeIcon: _buildActiveTabIcon(Icons.assignment_rounded, activeColor, showBadge: _hasUnreadNotification),
                  label: 'History',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.person_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.person_rounded, activeColor),
                  label: 'Profile',
                ),
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

  IconData _getCategoryIcon(String category) {
    final cat = category.toLowerCase();
    if (cat.contains('road') || cat.contains('damage')) {
      return Icons.construction_rounded;
    } else if (cat.contains('light') || cat.contains('lamp')) {
      return Icons.lightbulb_rounded;
    } else if (cat.contains('waste') || cat.contains('trash') || cat.contains('rubbish')) {
      return Icons.delete_outline_rounded;
    } else if (cat.contains('drain') || cat.contains('water')) {
      return Icons.water_drop_rounded;
    } else if (cat.contains('noise')) {
      return Icons.volume_up_rounded;
    } else {
      return Icons.report_problem_rounded;
    }
  }

  Widget _build3DPin(String category, _StatusConfig cfg) {
    return SizedBox(
      width: 36,
      height: 48,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // Pin Shadow (stays at bottom)
          Positioned(
            bottom: 4,
            child: Container(
              width: 14,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: const BorderRadius.all(Radius.elliptical(7, 2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.55),
                    blurRadius: 3,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          // Teardrop Pin (offset slightly upward to float)
          Positioned(
            top: 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Rotated Teardrop base
                Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.85),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.zero,
                      ),
                      border: Border.all(
                        color: const Color(0xFFA5B4FC), // Glowing indigo border
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFA5B4FC).withOpacity(0.35),
                          blurRadius: 5,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                  ),
                ),
                // Category Icon
                Positioned.fill(
                  child: Center(
                    child: Transform.rotate(
                      angle: -math.pi / 4,
                      child: Icon(
                        _getCategoryIcon(category),
                        color: Colors.white,
                        size: 13,
                      ),
                    ),
                  ),
                ),
                // Status Alert Dot
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: cfg.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black, width: 1.0),
                      boxShadow: [
                        BoxShadow(
                          color: cfg.color.withOpacity(0.5),
                          blurRadius: 3,
                          spreadRadius: 0.5,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _StatusConfig _getStatusConfig(String status) {
    switch (status) {
      case ReportStatus.resolved:
        return const _StatusConfig(
            color: Color(0xFF059669),
            bg: Color(0xFFECFDF5),
            icon: Icons.check_circle_rounded,
            label: 'Resolved');
      case ReportStatus.inMaintenance:
        return const _StatusConfig(
            color: Color(0xFF7C3AED),
            bg: Color(0xFFF5F3FF),
            icon: Icons.construction_rounded,
            label: 'In Maintenance');
      case ReportStatus.inProcess:
        return const _StatusConfig(
            color: Color(0xFFD97706),
            bg: Color(0xFFFFFBEB),
            icon: Icons.autorenew_rounded,
            label: 'In Process');
      case ReportStatus.inReview:
        return const _StatusConfig(
            color: Color(0xFF2563EB),
            bg: Color(0xFFEFF6FF),
            icon: Icons.rate_review_rounded,
            label: 'In Review');
      default:
        return const _StatusConfig(
            color: Color(0xFFDC2626),
            bg: Color(0xFFFEF2F2),
            icon: Icons.hourglass_empty_rounded,
            label: 'Pending');
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
                        return _buildReportCard(_recentReports[index]);
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

  String _getFormattedDate() {
    final now = DateTime.now();
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    
    final dayName = days[now.weekday - 1];
    final monthName = months[now.month - 1];
    return "$dayName, $monthName ${now.day}, ${now.year}";
  }

  Widget _buildHeader(BuildContext context) {
    final username = UserSession.instance.username;
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 60, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date at the top, separate from row to keep Row centering clean
          Text(
            _getFormattedDate(),
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWorker ? "Worker Portal" : "Welcome back,",
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF818CF8).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFA5B4FC).withOpacity(0.35), width: 1.0),
                          ),
                          child: Text(
                            UserSession.instance.role.toUpperCase(),
                            style: const TextStyle(
                                color: Color(0xFFE0E7FF),
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            username,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF818CF8), Color(0xFFC084FC)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF818CF8).withOpacity(0.4),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ],
                  border: Border.all(color: Colors.white.withOpacity(0.25), width: 1.5),
                ),
                child: Center(
                  child: Text(
                    username.isNotEmpty ? username.substring(0, 1).toUpperCase() : "U",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              _buildStatItem(
                  Icons.assignment_rounded, _totalReports.toString(), isWorker ? "Assigned" : "Total", const Color(0xFF818CF8)),
              _buildStatItem(
                  Icons.pending_actions_rounded, _pendingReports.toString(), isWorker ? "In Process" : "Pending", const Color(0xFFFBBF24)),
              _buildStatItem(
                  Icons.task_alt_rounded, _resolvedReports.toString(), isWorker ? "In Maint." : "Resolved", const Color(0xFF34D399)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label, Color accentColor) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Underlay glow centered behind the card
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withOpacity(0.2),
                      blurRadius: 16,
                      spreadRadius: 3,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                margin: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.12),
                        shape: BoxShape.circle,
                        border: Border.all(color: accentColor.withOpacity(0.2), width: 1),
                      ),
                      child: Icon(icon, color: accentColor, size: 18),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      value,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        shadows: [
                          Shadow(
                            color: accentColor.withOpacity(0.3),
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
                        letterSpacing: 1.0,
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

  Widget _buildHeroActionCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF818CF8).withOpacity(0.18),
            const Color(0xFFC084FC).withOpacity(0.06),
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned(
              right: -30,
              bottom: -30,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF818CF8).withOpacity(0.12),
                ),
              ),
            ),
            Positioned(
              left: -40,
              top: -40,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFC084FC).withOpacity(0.12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF818CF8).withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF818CF8).withOpacity(0.3), width: 1.2),
                        ),
                        child: const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFFA5B4FC),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        "Empower Your City",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    "Report local issues, track maintenance in real-time, and build a smarter community together.",
                    style: TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF6366F1).withOpacity(0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
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
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroWorkerCard(BuildContext context, int taskCount) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFF59E0B).withOpacity(0.18),
            const Color(0xFFEF4444).withOpacity(0.06),
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned(
              right: -30,
              bottom: -30,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF59E0B).withOpacity(0.12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3), width: 1.2),
                        ),
                        child: const Icon(
                          Icons.engineering_rounded,
                          color: Color(0xFFFBBF24),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        "Worker Workspace",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    taskCount > 0 
                      ? "You have $taskCount active task(s) assigned. Check recent reports below to update progress or upload proof of completion."
                      : "No active tasks assigned at the moment. Good work! Tap refresh to fetch new dispatches.",
                    style: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  if (taskCount > 0) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFEF4444),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          "Requires Maintenance Action",
                          style: TextStyle(
                            color: Color(0xFFF87171),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainActionButton(BuildContext context) {
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');
    if (isWorker) {
      return _buildHeroWorkerCard(context, _totalReports);
    }
    return _buildHeroActionCard(context);
  }

  Widget _buildReportCard(Map<String, dynamic> item) {
    final cat = item['categories'] ?? 'Unknown';
    final timeAgo = _formatTime(item['timestamp']);
    final status = item['status'] ?? ReportStatus.pending;
    final cfg = _getStatusConfig(status);
    final description = item['description']?.toString().isNotEmpty == true
        ? item['description']
        : 'Issue Reported';

    final priority = (cat.contains('Damage') ||
            cat.contains('Drainage') ||
            cat.contains('Tree'))
        ? (status == ReportStatus.resolved ? 'Low' : 'High')
        : (status == ReportStatus.resolved ? 'Low' : 'Medium');

    Color priorityColor;
    if (priority == 'High') {
      priorityColor = const Color(0xFFEF4444); // Crimson
    } else if (priority == 'Medium') {
      priorityColor = const Color(0xFFD97706); // Amber
    } else {
      priorityColor = const Color(0xFF059669); // Emerald
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReportDetailScreen(report: item),
          ),
        ).then((_) => _fetchDashboardData());
      },
      child: GlassCard(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _build3DPin(cat, cfg),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              cat,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Colors.white),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Row(
                            children: [
                              _buildTag(cfg.label, cfg.color),
                              const SizedBox(width: 6),
                              _buildTag(priority, priorityColor),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(timeAgo,
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              description,
              style: const TextStyle(
                  color: Color(0xFFE2E8F0), fontSize: 13, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
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
            children: [
              Icon(
                _getCategoryIcon(label),
                size: 16,
                color: col,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0), fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                "${(val * 100).toInt()}%",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: col),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                Container(
                  height: 8,
                  color: Colors.white.withOpacity(0.06),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  width: val > 0 ? null : 0,
                  height: 8,
                  child: FractionallySizedBox(
                    widthFactor: val,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            col.withOpacity(0.6),
                            col,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: col.withOpacity(0.35),
                            blurRadius: 4,
                            spreadRadius: 0.5,
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusConfig {
  final Color    color;
  final Color    bg;
  final IconData icon;
  final String   label;
  const _StatusConfig({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
  });
}