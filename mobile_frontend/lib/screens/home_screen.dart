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
import '../theme_manager.dart';

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

  Widget _buildTabIcon(IconData icon, bool isActive, Color activeColor, {bool showBadge = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Calculate unselected color dynamically
    final inactiveColor = isDark
        ? (_selectedIndex == 1
            ? Colors.white.withOpacity(0.85)
            : Colors.white.withOpacity(0.6))
        : (_selectedIndex == 1
            ? const Color(0xFF78716C)
            : const Color(0xFFA8A29E));
            
    final color = isActive ? activeColor : inactiveColor;
    
    return TweenAnimationBuilder<double>(
      key: ValueKey("${icon.codePoint}_${isActive}"),
      tween: Tween<double>(begin: isActive ? 1.0 : 1.18, end: isActive ? 1.18 : 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                color: color,
                size: 24,
                shadows: (isActive && isDark) ? [
                  const Shadow(
                    color: Colors.white,
                    blurRadius: 10,
                  ),
                  Shadow(
                    color: Colors.white.withOpacity(0.6),
                    blurRadius: 20,
                  ),
                ] : (isActive && !isDark) ? [
                  const Shadow(
                    color: Colors.white,
                    blurRadius: 6,
                  ),
                  Shadow(
                    color: const Color(0xFF0D9488).withOpacity(0.4),
                    blurRadius: 15,
                  ),
                ] : null,
              ),
              if (showBadge)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      shape: BoxShape.circle,
                      border: Border.all(color: isDark ? Colors.black : Colors.white, width: 0.8),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveTabIcon(IconData icon, Color activeColor, {bool showBadge = false}) {
    return _buildTabIcon(icon, true, activeColor, showBadge: showBadge);
  }

  Widget _buildInactiveTabIcon(IconData icon, {bool showBadge = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark ? Colors.white : const Color(0xFF0D9488);
    return _buildTabIcon(icon, false, activeColor, showBadge: showBadge);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark
        ? Colors.white
        : const Color(0xFF0D9488); // Teal for light mode active tab

    final unselectedColor = isDark
        ? (_selectedIndex == 1
            ? Colors.white.withOpacity(0.85)
            : Colors.white.withOpacity(0.6))
        : (_selectedIndex == 1
            ? const Color(0xFF78716C)
            : const Color(0xFFA8A29E));

    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true, // Allows body widgets (like maps) to sit behind the floating navbar
        body: SmoothIndexedStack(
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
            color: isDark
                ? const Color(0xFF1C1917) // Fully solid dark charcoal in dark mode
                : Colors.white, // Fully solid white in light mode
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(24),
            child: BottomNavigationBar(
              elevation: 0,
              backgroundColor: Colors.transparent,
              type: BottomNavigationBarType.fixed,
              currentIndex: _selectedIndex,
              selectedItemColor: activeColor,
              unselectedItemColor: unselectedColor,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
              onTap: _onItemTapped,
              items: [
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.space_dashboard_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.space_dashboard_rounded, activeColor),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.explore_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.explore_rounded, activeColor),
                  label: 'Map',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.task_alt_rounded, showBadge: _hasUnreadNotification),
                  activeIcon: _buildActiveTabIcon(Icons.task_alt_rounded, activeColor, showBadge: _hasUnreadNotification),
                  label: 'History',
                ),
                BottomNavigationBarItem(
                  icon: _buildInactiveTabIcon(Icons.face_rounded),
                  activeIcon: _buildActiveTabIcon(Icons.face_rounded, activeColor),
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
  List<dynamic>    _workerTasksToDo = [];
  List<dynamic>    _workerTasksSubmitted = [];

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
        // Fetch worker's personal reports to compute assigned task counts
        final workerResponse = await ApiService.getReports(
          role: session.role,
          username: session.username,
        );
        // Fetch global stats and reports for overview and recent list (open to all users)
        final statsResponse   = await ApiService.getStats();
        final reportsResponse = await ApiService.getReports();

        if (workerResponse.statusCode == 200 &&
            statsResponse.statusCode == 200 &&
            reportsResponse.statusCode == 200) {
          final workerReports = jsonDecode(workerResponse.body) as List;
          final statsData = jsonDecode(statsResponse.body);
          final reportsData = jsonDecode(reportsResponse.body) as List;

          // Sort global reports by timestamp descending to show the live 3 most recent
          reportsData.sort((a, b) {
            final ta = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime(0);
            final tb = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime(0);
            return tb.compareTo(ta);
          });

          setState(() {
            _totalReports    = workerReports.length;
            _pendingReports  = workerReports.where((r) => r['status'] == 'In Process').length;
            _resolvedReports = workerReports.where((r) => r['status'] == 'In Maintenance').length;
            _categories      = Map<String, int>.from(statsData['categories'] ?? {});
            _recentReports   = reportsData.take(3).toList();
            _workerTasksToDo = workerReports.where((r) => r['worker_completed'] != 1).toList();
            _workerTasksSubmitted = workerReports.where((r) => r['worker_completed'] == 1).toList();
            _isLoading       = false;
          });
        } else {
          throw Exception('Server returned an error');
        }
      } else {
        // Citizen: fetch global stats and reports (open to all users)
        final statsResponse   = await ApiService.getStats();
        final reportsResponse = await ApiService.getReports();

        if (statsResponse.statusCode == 200 && reportsResponse.statusCode == 200) {
          final statsData   = jsonDecode(statsResponse.body);
          final reportsData = jsonDecode(reportsResponse.body) as List;

          // Sort global reports by timestamp descending to show the live 3 most recent
          reportsData.sort((a, b) {
            final ta = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime(0);
            final tb = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime(0);
            return tb.compareTo(ta);
          });

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

  Widget _build3DPin(String category, _StatusConfig cfg, {int upvotes = 0}) {
    final double sizeMultiplier = 1.0 + math.min(upvotes * 0.10, 0.40);
    final double baseWidth = 24.0 * sizeMultiplier;
    final double baseHeight = 24.0 * sizeMultiplier;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color glowColor = upvotes >= 5
        ? const Color(0xFFF59E0B) // Amber gold for high votes
        : upvotes >= 2
            ? const Color(0xFFEC4899) // Hot pink for trending votes
            : (isDark ? Colors.white : const Color(0xFF1C1917));

    return SizedBox(
      width: 36 * sizeMultiplier,
      height: 48 * sizeMultiplier,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // Pin Shadow (stays at bottom)
          Positioned(
            bottom: 4,
            child: Transform.scale(
              scale: sizeMultiplier,
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
                    width: baseWidth,
                    height: baseHeight,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black.withOpacity(0.85) : const Color(0xFFF5F5F4),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        topRight: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.zero,
                      ),
                      border: Border.all(
                        color: glowColor,
                        width: 1.5 + (upvotes * 0.4).clamp(0.0, 2.0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: glowColor.withOpacity(0.35 + (upvotes * 0.05).clamp(0.0, 0.45)),
                          blurRadius: 5 + upvotes * 2.0,
                          spreadRadius: 0.5 + upvotes * 0.3,
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
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                        size: 13 * sizeMultiplier,
                      ),
                    ),
                  ),
                ),
                // Status Alert Dot
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    width: 7 * sizeMultiplier,
                    height: 7 * sizeMultiplier,
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
                // Upvotes indicator
                if (upvotes > 0)
                  Positioned(
                    bottom: -3,
                    right: -3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                      decoration: BoxDecoration(
                        color: glowColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.black, width: 1.0),
                      ),
                      child: Text(
                        "+$upvotes",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 7,
                          fontWeight: FontWeight.w900,
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
            color: const Color(0xFF0EA5E9),
            bg: const Color(0xFFF0F9FF),
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
      case ReportStatus.rejected:
        return const _StatusConfig(
            color: Color(0xFFEF4444),
            bg: Color(0xFFFEF2F2),
            icon: Icons.cancel_rounded,
            label: 'Rejected');
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
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
            color: Colors.white,
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
                  
                  if (isWorker) ...[
                    // ── WORKER ACTIVE TASKS TO-DO ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text(
                            "My Tasks To-Do",
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
                    if (_workerTasksToDo.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: GlassCard(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.task_alt_rounded,
                                  color: isDark ? Colors.white70 : const Color(0xFF0D9488),
                                  size: 36,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  "No pending tasks assigned. You're all caught up!",
                                  style: TextStyle(
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _workerTasksToDo.length,
                        itemBuilder: (context, index) {
                          return _buildReportCard(_workerTasksToDo[index]);
                        },
                      ),

                    // ── WORKER SUBMITTED TASKS ──
                    if (_workerTasksSubmitted.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text(
                              "Submitted (Awaiting Review)",
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
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _workerTasksSubmitted.length,
                        itemBuilder: (context, index) {
                          return _buildReportCard(_workerTasksSubmitted[index]);
                        },
                      ),
                    ],
                  ] else ...[
                    // ── CITIZEN RECENT REPORTS ──
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
                  ],
                  
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
        : const Color(0xFFFBBF24);  // Lavender/purple for in-progress

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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
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
                          style: TextStyle(
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                username,
                                style: TextStyle(
                                  color: isDark ? Colors.white : const Color(0xFF1C1917),
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white.withOpacity(0.18) : const Color(0xFFF5F5F4),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isDark ? Colors.white.withOpacity(0.35) : const Color(0xFFD6D3D1),
                                  width: 1.0,
                                ),
                              ),
                              child: Text(
                                UserSession.instance.role.toUpperCase(),
                                style: TextStyle(
                                    color: isDark ? Colors.white70 : const Color(0xFF78716C),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 8),
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: isDark ? Colors.white : const Color(0xFFE7E5E4), width: 1.5),
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        getAvatarPath(username),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 52),
              Row(
                children: [
                  _buildStatItem(
                      Icons.assignment_rounded,
                      _totalReports.toString(),
                      isWorker ? "Assigned" : "Total",
                      isDark ? Colors.white : const Color(0xFF0D9488),
                      'assets/stat_total.png'),
                  _buildStatItem(
                      Icons.pending_actions_rounded,
                      _pendingReports.toString(),
                      isWorker ? "In Process" : "Pending",
                      isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                      'assets/stat_pending.png'),
                  _buildStatItem(
                      Icons.task_alt_rounded,
                      _resolvedReports.toString(),
                      isWorker ? "In Maint." : "Resolved",
                      isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                      'assets/stat_resolved.png'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label, Color accentColor, String assetPath) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          width: double.infinity,
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            margin: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Image.asset(
                    assetPath,
                    width: 110,
                    height: 110,
                    fit: BoxFit.contain,
                    color: isDark 
                        ? Colors.white.withOpacity(0.08) 
                        : const Color(0xFF1C1917).withOpacity(0.08),
                    colorBlendMode: BlendMode.srcIn,
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.black : const Color(0xFFF5F5F4),
                          shape: BoxShape.circle,
                          border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFD6D3D1), width: 1.5),
                        ),
                        child: Icon(icon, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 18),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        value,
                        style: TextStyle(
                          color: isDark ? Colors.white : const Color(0xFF1C1917),
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        label.toUpperCase(),
                        style: TextStyle(
                          color: isDark ? Colors.grey : const Color(0xFF78716C),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroActionCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4), width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.black : const Color(0xFFF5F5F4),
                        shape: BoxShape.circle,
                        border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFD6D3D1), width: 1.5),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        color: isDark ? Colors.white : const Color(0xFF0D9488),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      "Empower Your City",
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  "Report local issues, track maintenance in real-time, and build a smarter community together.",
                  style: TextStyle(
                    color: isDark ? const Color(0xFFCCCCCC) : const Color(0xFF44403C),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CitizenReportScreen()),
                      );
                      if (result == true) {
                        _fetchDashboardData();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                      foregroundColor: isDark ? Colors.black : Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: Icon(Icons.add_circle_outline_rounded, color: isDark ? Colors.black : Colors.white),
                    label: Text(
                      "Report an Issue",
                      style: TextStyle(color: isDark ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: -10,
          bottom: -10,
          child: IgnorePointer(
            child: Opacity(
              opacity: isDark ? 0.08 : 0.05,
              child: Icon(
                Icons.location_city_rounded,
                size: 130,
                color: isDark ? Colors.white : const Color(0xFF1C1917),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroWorkerCard(BuildContext context, int taskCount) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4), width: 1.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.black : const Color(0xFFF5F5F4),
                        shape: BoxShape.circle,
                        border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFD6D3D1), width: 1.5),
                      ),
                      child: Icon(
                        Icons.engineering_rounded,
                        color: isDark ? Colors.white : const Color(0xFF0D9488),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      "Worker Workspace",
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                  style: TextStyle(
                    color: isDark ? const Color(0xFFCCCCCC) : const Color(0xFF44403C),
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
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white : const Color(0xFFDC2626),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "Requires Maintenance Action",
                        style: TextStyle(
                          color: isDark ? Colors.white : const Color(0xFFDC2626),
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
        ),
        Positioned(
          right: -10,
          bottom: -10,
          child: IgnorePointer(
            child: Opacity(
              opacity: isDark ? 0.08 : 0.05,
              child: Icon(
                Icons.engineering_rounded,
                size: 130,
                color: isDark ? Colors.white : const Color(0xFF1C1917),
              ),
            ),
          ),
        ),
      ],
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cat = item['categories'] ?? 'Unknown';
    final timeAgo = _formatTime(item['timestamp']);
    final status = item['status'] ?? ReportStatus.pending;
    final cfg = _getStatusConfig(status);
    final description = item['description']?.toString().isNotEmpty == true
        ? item['description']
        : 'Issue Reported';

    final isLowPriority = status == ReportStatus.resolved || status == ReportStatus.rejected;
    final priority = (cat.contains('Damage') ||
            cat.contains('Drainage') ||
            cat.contains('Tree'))
        ? (isLowPriority ? 'Low' : 'High')
        : (isLowPriority ? 'Low' : 'Medium');

    Color priorityColor;
    if (priority == 'High') {
      priorityColor = const Color(0xFFEF4444); // Crimson
    } else if (priority == 'Medium') {
      priorityColor = const Color(0xFFD97706); // Amber
    } else {
      priorityColor = const Color(0xFF059669); // Emerald
    }

    final int upvotes = item['upvotes'] is int
        ? item['upvotes']
        : (int.tryParse(item['upvotes']?.toString() ?? '0') ?? 0);

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
                _build3DPin(cat, cfg, upvotes: upvotes),
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
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: isDark ? Colors.white : const Color(0xFF1C1917)),
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
                              if (upvotes > 0) ...[
                                const SizedBox(width: 6),
                                _buildTag('▲ $upvotes Upvotes', const Color(0xFFEC4899)),
                              ],
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(timeAgo,
                          style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), fontSize: 11, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              description,
              style: TextStyle(
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF44403C), fontSize: 13, height: 1.4),
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "City Issue Overview",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isDark ? Colors.white : const Color(0xFF1C1917)),
          ),
          const SizedBox(height: 20),
          ...lines,
        ],
      ),
    );
  }

  Widget _buildProgressLine(String label, double val, Color col) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _getCategoryIcon(label),
                size: 16,
                color: isDark ? Colors.white : const Color(0xFF1C1917),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white : const Color(0xFF1C1917),
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                "${(val * 100).toInt()}%",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isDark ? Colors.white : const Color(0xFF1C1917)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(
                  height: 6,
                  color: isDark ? Colors.white12 : const Color(0xFFE7E5E4),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  width: val > 0 ? null : 0,
                  height: 6,
                  child: FractionallySizedBox(
                    widthFactor: val,
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white : col,
                        borderRadius: BorderRadius.circular(4),
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

class SmoothIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const SmoothIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<SmoothIndexedStack> createState() => _SmoothIndexedStackState();
}

class _SmoothIndexedStackState extends State<SmoothIndexedStack>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 0.02), // subtle lift transition
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _controller.forward();
  }

  @override
  void didUpdateWidget(SmoothIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.reset();
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: IndexedStack(
          index: widget.index,
          children: widget.children,
        ),
      ),
    );
  }
}