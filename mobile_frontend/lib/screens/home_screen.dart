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
import '../notification_settings.dart';
import '../user_session.dart';
import 'login_screen.dart';
import '../theme_manager.dart';

import '../widgets/glass_card.dart';
import '../widgets/background_decorator.dart';
import '../pixel_theme.dart';
import '../widgets/nav_icons.dart';
import '../widgets/pixel_widgets.dart';
import '../localization/app_strings.dart';
import '../localization/locale_manager.dart';

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

  // Set when a stat card on Home/Profile is tapped, so the History tab can
  // land pre-filtered instead of making the user reapply the filter by hand.
  String? _pendingHistoryFilter;

  List<Widget> get _widgetOptions => [
        DashboardContent(
          onStatTap: _goToHistory,
          onProfileTap: () => _onItemTapped(3),
        ),
        // Not const, for the same reason as `home:` in main.dart — a const
        // instance is identical across rebuilds, so this tab would keep the old
        // language after a locale switch.
        MapViewScreen(),
        HistoryScreen(initialStatusFilter: _pendingHistoryFilter),
        ProfileScreen(onViewReportsTap: () => _goToHistory(null)),
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

  /// Switches to the History tab, optionally pre-filtered to [status].
  void _goToHistory(String? status) {
    setState(() {
      _pendingHistoryFilter = status;
      _selectedIndex = 2;
      _hasUnreadNotification = false;
    });
  }

  Widget _buildTabIcon(NavIconType icon, bool isActive, Color activeColor, {bool showBadge = false}) {
    final inactiveColor = const Color(0xFFB7B3AC);
    final color = isActive ? activeColor : inactiveColor;

    return TweenAnimationBuilder<double>(
      key: ValueKey("${icon.name}_$isActive"),
      tween: Tween<double>(begin: isActive ? 1.0 : 1.1, end: isActive ? 1.1 : 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              NavIcon(type: icon, color: color, size: 24),
              if (showBadge)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: PixelTheme.alertRed,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 0.8),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveTabIcon(NavIconType icon, Color activeColor, {bool showBadge = false}) {
    return _buildTabIcon(icon, true, activeColor, showBadge: showBadge);
  }

  Widget _buildInactiveTabIcon(NavIconType icon, {bool showBadge = false}) {
    return _buildTabIcon(icon, false, PixelTheme.primaryGreen, showBadge: showBadge);
  }

  Widget _navItem(int index, NavIconType icon, String label, {bool showBadge = false}) {
    final isActive = _selectedIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => _onItemTapped(index),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              isActive
                  ? _buildActiveTabIcon(icon, PixelTheme.primaryGreen, showBadge: showBadge)
                  : _buildInactiveTabIcon(icon, showBadge: showBadge),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PixelTheme.pixelCaption(
                  fontSize: 10,
                  color: isActive ? PixelTheme.primaryGreen : const Color(0xFFB7B3AC),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                : 16,
            left: 16,
            right: 16,
          ),
          child: SizedBox(
            height: 108,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: PixelTheme.pixelShadow,
                    ),
                    child: Row(
                      children: [
                        _navItem(0, NavIconType.home, tr('nav_home')),
                        _navItem(1, NavIconType.map, tr('nav_map')),
                        const SizedBox(width: 64),
                        _navItem(2, NavIconType.history, tr('nav_history'), showBadge: _hasUnreadNotification),
                        _navItem(3, NavIconType.profile, tr('nav_profile')),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  // Sits 8px lower than the nav bar's top edge (72) rather than
                  // centred on it, so the button reads as resting in the bar
                  // instead of floating off it.
                  bottom: 34,
                  child: GestureDetector(
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CitizenReportScreen()),
                      );
                      if (result == true) setState(() {});
                    },
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: PixelTheme.accentOrange,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: PixelTheme.accentOrange.withOpacity(0.45),
                            offset: const Offset(0, 8),
                            blurRadius: 18,
                          ),
                        ],
                        border: Border.all(color: PixelTheme.bgPrimary, width: 4),
                      ),
                      child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
                    ),
                  ),
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
  /// Called with a status string (or null for "all") when a stat card is
  /// tapped, so Home can switch to History pre-filtered.
  final ValueChanged<String?>? onStatTap;

  /// Called when the header avatar is tapped. Switches to the Profile tab
  /// rather than pushing a second copy of the screen on top of the nav bar.
  final VoidCallback? onProfileTap;

  const DashboardContent({super.key, this.onStatTap, this.onProfileTap});

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
  List<dynamic>    _workerTeamPool = [];
  int?             _claimingId;

  // ── Notification banner state ──────────────────────────────────────────
  StreamSubscription<StatusChange>? _notifSub;
  StatusChange? _pendingNotif;
  bool _showNotifBanner = false;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();

    // Start polling for status changes and show banner on change,
    // unless the user has turned notifications off in Profile.
    if (NotificationSettings.enabledNotifier.value) {
      NotificationService.instance.start(intervalSeconds: 60);
    }
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
        // Jobs this worker has claimed. The unclaimed team pool is fetched
        // separately so the two lists can be shown as distinct sections.
        final workerResponse = await ApiService.getReports(
          role: session.role,
          username: session.username,
          scope: 'mine',
        );
        final poolResponse = await ApiService.getTeamPool();
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

          // The pool is a soft dependency: if it fails the worker should still
          // see their own tasks rather than an error screen.
          final poolReports = poolResponse.statusCode == 200
              ? jsonDecode(poolResponse.body) as List
              : <dynamic>[];

          setState(() {
            _totalReports    = workerReports.length;
            _pendingReports  = workerReports.where((r) => r['status'] == 'In Process').length;
            _resolvedReports = workerReports.where((r) => r['status'] == 'In Maintenance').length;
            _categories      = Map<String, int>.from(statsData['categories'] ?? {});
            _recentReports   = reportsData.take(3).toList();
            _workerTeamPool  = poolReports;
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
    if (ts == null || ts.isEmpty) return tr('common_unknown');
    try {
      final dt   = DateTime.parse(ts).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 60) return trCount('common_minutes_ago', diff.inMinutes == 0 ? 1 : diff.inMinutes);
      if (diff.inHours   < 24) return trCount('common_hours_ago', diff.inHours);
      return trCount('common_days_ago', diff.inDays);
    } catch (_) {
      return tr('common_unknown');
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

  Widget _build3DPin(String category, StatusConfig cfg, {int upvotes = 0}) {
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


  @override
  Widget build(BuildContext context) {
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3, color: PixelTheme.accentOrange),
              ),
              const SizedBox(height: 14),
              Text(
                tr('home_loading_reports'),
                style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasError) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: PixelCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 40, color: PixelTheme.alertRed),
                  const SizedBox(height: 14),
                  Text(
                    tr('home_error_title'),
                    textAlign: TextAlign.center,
                    style: PixelTheme.pixelHeading(fontSize: 16, color: PixelTheme.textPrimary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('home_error_body'),
                    textAlign: TextAlign.center,
                    style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                  ),
                  const SizedBox(height: 18),
                  PixelButton(
                    text: tr('common_retry'),
                    color: PixelTheme.alertRed,
                    height: 46,
                    fontSize: 13,
                    icon: Icons.refresh_rounded,
                    onPressed: _fetchDashboardData,
                  ),
                ],
              ),
            ),
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
            color: PixelTheme.accentOrange,
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
                    // ── TEAM POOL: unclaimed work anyone on the team can take ──
                    if (_workerTeamPool.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildSectionHeading(
                          tr('home_worker_team_pool'),
                          Icons.groups_2_outlined,
                          PixelTheme.accentCyan,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          tr('home_worker_team_pool_hint'),
                          style: PixelTheme.pixelBody(
                            fontSize: 11,
                            color: PixelTheme.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _workerTeamPool.length,
                        itemBuilder: (context, index) =>
                            _buildPoolCard(_workerTeamPool[index]),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // ── WORKER ACTIVE TASKS TO-DO ──
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildSectionHeading(tr('home_worker_tasks_todo'), Icons.assignment_turned_in_outlined, PixelTheme.accentOrange),
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
                                const Icon(
                                  Icons.task_alt_rounded,
                                  color: PixelTheme.accentOrange,
                                  size: 36,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  tr('home_worker_no_tasks'),
                                  style: PixelTheme.pixelBody(
                                    fontSize: 13,
                                    color: PixelTheme.textSecondary,
                                    fontWeight: FontWeight.w600,
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
                          children: [
                            _buildSectionHeading(tr('home_worker_submitted'), Icons.hourglass_top_rounded, PixelTheme.accentCyan),
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
                        children: [
                          _buildSectionHeading(tr('home_recent_reports'), Icons.history_rounded, PixelTheme.accentOrange),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_recentReports.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: PixelCard(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.assignment_outlined, color: PixelTheme.accentOrange, size: 32),
                              const SizedBox(height: 12),
                              Text(
                                tr('home_no_reports_title'),
                                style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                tr('home_no_reports_body'),
                                textAlign: TextAlign.center,
                                style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                              ),
                              const SizedBox(height: 16),
                              PixelButton(
                                text: tr('common_file_report'),
                                color: PixelTheme.accentOrange,
                                height: 46,
                                fontSize: 13,
                                onPressed: () async {
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const CitizenReportScreen()),
                                  );
                                  if (result == true) _fetchDashboardData();
                                },
                              ),
                            ],
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
                  const SizedBox(height: 140), // padding to prevent being hidden by floating nav bar
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
                  Text(
                    tr('home_notif_banner_title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${change.category}: ${trStatus(change.oldStatus)} → ${trStatus(change.newStatus)}',
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
    final months = LocaleManager.isBm
        ? ['Jan', 'Feb', 'Mac', 'Apr', 'Mei', 'Jun', 'Jul', 'Ogo', 'Sep', 'Okt', 'Nov', 'Dis']
        : ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final days = LocaleManager.isBm
        ? ['Isn', 'Sel', 'Rab', 'Kha', 'Jum', 'Sab', 'Ahd']
        : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    final dayName = days[now.weekday - 1];
    final monthName = months[now.month - 1];
    return "$dayName, $monthName ${now.day}, ${now.year}";
  }

  /// EN / BM switch.
  ///
  /// Shows both options with the active one highlighted rather than a single
  /// label that flips, so the language can be changed without first tapping to
  /// find out what the control does. Writes through LocaleManager, which
  /// persists the choice and rebuilds the tree, so this stays in step with the
  /// same setting in Profile.
  Widget _buildLanguageToggle() {
    return ValueListenableBuilder<String>(
      valueListenable: LocaleManager.localeNotifier,
      builder: (context, locale, _) {
        Widget segment(String code, String label) {
          final isActive = locale == code;
          return GestureDetector(
            onTap: isActive ? null : () => LocaleManager.toggleLocale(),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isActive ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                label,
                style: PixelTheme.pixelCaption(
                  fontSize: 11,
                  color: isActive ? PixelTheme.primaryGreen : Colors.white.withOpacity(0.75),
                ),
              ),
            ),
          );
        }

        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              segment('en', tr('lang_short_en')),
              segment('bm', tr('lang_short_bm')),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final username = UserSession.instance.username;
    final isWorker = UserSession.instance.role.toLowerCase().contains('worker');

    return Container(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 26),
      decoration: const BoxDecoration(
        color: PixelTheme.primaryGreen,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(32),
          bottomRight: Radius.circular(32),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Flexible so a long localised date can't push the toggle off a
              // narrow screen — the switch is wider than the badge that used to
              // sit here.
              Flexible(
                child: Text(
                  _getFormattedDate(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PixelTheme.pixelCaption(fontSize: 12, color: Colors.white.withOpacity(0.7)),
                ),
              ),
              const SizedBox(width: 8),
              _buildLanguageToggle(),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              // Tapping the avatar is the shortcut most users reach for first,
              // so it opens the Profile tab.
              InkWell(
                onTap: () => widget.onProfileTap?.call(),
                customBorder: const CircleBorder(),
                child: Semantics(
                  button: true,
                  label: tr('home_open_profile'),
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.0),
                    ),
                    child: ClipOval(
                      child: getAvatarImageWidget(username),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWorker ? tr('home_greeting_worker') : tr('home_greeting_citizen'),
                      style: PixelTheme.pixelCaption(fontSize: 11, color: Colors.white.withOpacity(0.65)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      username,
                      style: PixelTheme.pixelHeading(fontSize: 19, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Role badge sits on the avatar row so it reads as a label for the
              // person, rather than floating up beside the date.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tr('role_${UserSession.instance.role.toLowerCase()}'),
                  style: PixelTheme.pixelCaption(fontSize: 11, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              // For a worker the first tile is the team pool — the work they
              // could pick up — rather than a total that hides it.
              _buildStatItem(
                  isWorker ? Icons.groups_2_outlined : Icons.assignment_outlined,
                  isWorker
                      ? _workerTeamPool.length.toString()
                      : _totalReports.toString(),
                  isWorker ? tr('home_stat_pool') : tr('home_stat_total'),
                  PixelTheme.accentCyan,
                  onTap: () => widget.onStatTap?.call(null)),
              _buildStatItem(
                  Icons.pending_actions_outlined,
                  isWorker ? _totalReports.toString() : _pendingReports.toString(),
                  isWorker ? tr('home_stat_mine') : trStatus(ReportStatus.pending),
                  PixelTheme.tagYellow,
                  onTap: () => widget.onStatTap
                      ?.call(isWorker ? ReportStatus.inProcess : ReportStatus.pending)),
              _buildStatItem(
                  Icons.check_circle_outline_rounded,
                  _resolvedReports.toString(),
                  isWorker ? tr('home_stat_in_maint') : trStatus(ReportStatus.resolved),
                  Colors.white,
                  onTap: () => widget.onStatTap
                      ?.call(isWorker ? ReportStatus.inMaintenance : ReportStatus.resolved)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeading(String text, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
        ),
      ],
    );
  }

  Widget _buildStatItem(IconData icon, String value, String label, Color accentColor, {VoidCallback? onTap}) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(icon, color: accentColor, size: 18),
                  const SizedBox(height: 8),
                  Text(
                    value,
                    style: PixelTheme.pixelHeading(fontSize: 18, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: PixelTheme.pixelCaption(fontSize: 10, color: Colors.white.withOpacity(0.7)),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroActionCard(BuildContext context) {
    return PixelCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: PixelTheme.accentOrange.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.campaign_outlined, color: PixelTheme.accentOrange, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('home_report_issue_title'),
                      style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('home_report_issue_body'),
                      style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          PixelButton(
            text: tr('common_file_report'),
            color: PixelTheme.accentOrange,
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CitizenReportScreen()),
              );
              if (result == true) {
                _fetchDashboardData();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeroWorkerCard(BuildContext context, int taskCount) {
    return PixelCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: PixelTheme.accentCyan.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.engineering_outlined, color: PixelTheme.accentCyan, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('home_worker_workspace_title'),
                  style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  taskCount > 0
                      ? trCount('home_worker_workspace_active', taskCount)
                      : tr('home_worker_workspace_empty'),
                  style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                ),
              ],
            ),
          ),
        ],
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

  /// Compact single-line-per-fact report row. Replaces the old six-panel
  /// stacked card: the whole row is already the tap target, so it no longer
  /// duplicates that as a full-width "View Full Details" button underneath.
  /// Claim a job from the team pool.
  ///
  /// The server settles races, so a 409 here is expected rather than
  /// exceptional: another worker got there first and we just refresh.
  Future<void> _claimPoolTask(Map<String, dynamic> item) async {
    final id = item['id'] as int?;
    if (id == null || _claimingId != null) return;

    setState(() => _claimingId = id);
    try {
      final res = await ApiService.claimTask(id);
      if (!mounted) return;

      if (res.statusCode == 200) {
        _showSnack(tr('worker_claim_success'), PixelTheme.accentGreen);
      } else if (res.statusCode == 409) {
        _showSnack(tr('worker_claim_taken'), PixelTheme.accentOrange);
      } else {
        _showSnack(
          ApiService.errorDetail(res, tr('worker_claim_failed')),
          PixelTheme.alertRed,
        );
      }
    } catch (_) {
      if (mounted) _showSnack(tr('worker_claim_failed'), PixelTheme.alertRed);
    } finally {
      if (mounted) setState(() => _claimingId = null);
      await _fetchDashboardData();
    }
  }

  void _showSnack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: PixelTheme.pixelBody(fontSize: 12)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// An unclaimed job in the team pool, with an Accept button.
  /// Compact "agency crew" tag, e.g. "mbmb TeamA" — agency lowercase, crew
  /// name with spaces stripped so the two read as one short label. Null when
  /// the report has no team yet (still Pending / In Review).
  String? _teamCrewTag(Map<String, dynamic> item) {
    final team = (item['assigned_team'] as String?)?.trim();
    if (team == null || team.isEmpty) return null;
    final crew = (item['assigned_crew'] as String?)?.trim();
    if (crew == null || crew.isEmpty) return team.toLowerCase();
    return '${team.toLowerCase()} ${crew.replaceAll(' ', '')}';
  }

  Widget _buildPoolCard(Map<String, dynamic> item) {
    final cat = (item['categories'] ?? 'Uncategorized').toString();
    final location =
        (item['location'] ?? item['address'] ?? tr('common_location_unknown')).toString();
    final id = item['id'] as int?;
    final busy = _claimingId == id;
    final releaseCount = item['release_count'] is int ? item['release_count'] as int : 0;
    final teamTag = _teamCrewTag(item);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: PixelCard(
        padding: const EdgeInsets.all(14),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ReportDetailScreen(report: item)),
          ).then((_) => _fetchDashboardData());
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: PixelTheme.accentCyan.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.inbox_rounded,
                      color: PixelTheme.accentCyan, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              cat,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PixelTheme.pixelBody(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (teamTag != null) ...[
                            const SizedBox(width: 6),
                            PixelBadge(text: teamTag, color: PixelTheme.accentCyan),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PixelTheme.pixelBody(
                          fontSize: 11,
                          color: PixelTheme.textSecondary,
                        ),
                      ),
                      if (releaseCount > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          trCount('worker_pool_released', releaseCount),
                          style: PixelTheme.pixelBody(
                            fontSize: 10,
                            color: PixelTheme.accentOrange,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? null : () => _claimPoolTask(item),
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.handshake_outlined, size: 16),
                label: Text(
                  busy ? tr('worker_claiming') : tr('worker_accept_task'),
                  style: PixelTheme.pixelBody(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: PixelTheme.accentCyan,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportCard(Map<String, dynamic> item) {
    final cat = (item['categories'] ?? 'Uncategorized').toString();
    final status = (item['status'] ?? ReportStatus.pending).toString();
    final isResolved = status.trim().toLowerCase().contains('resolve');
    final isRejected = status.trim().toLowerCase().contains('reject');
    final cfg = getStatusConfig(status);
    final priority = getReportPriority(cat, status);
    final location = (item['location'] ?? item['address'] ?? tr('common_location_unknown')).toString();

    final int upvotes = item['upvotes'] is int
        ? item['upvotes']
        : (int.tryParse(item['upvotes']?.toString() ?? '0') ?? 0);

    // Real AI diagnostics when the backend has actually scanned the report —
    // never a placeholder value, since a fake match number is worse than none.
    final String? aiPrediction = (item['ai_prediction'] as String?)?.trim();
    final double? aiConfidence = double.tryParse((item['confidence'] ?? '').toString().replaceAll('%', ''));
    final bool hasAiData = aiPrediction != null && aiPrediction.isNotEmpty;
    final String? aiCaption = hasAiData
        ? (aiConfidence != null ? '$aiPrediction · ${aiConfidence.toInt()}% ${tr('common_match')}' : aiPrediction)
        : null;

    final iconColor = isResolved
        ? PixelTheme.accentGreen
        : (isRejected ? PixelTheme.alertRed : PixelTheme.accentOrange);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: PixelCard(
        padding: const EdgeInsets.all(14),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReportDetailScreen(report: item),
            ),
          ).then((_) => _fetchDashboardData());
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(_getCategoryIcon(cat), size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          trCategory(cat),
                          style: PixelTheme.pixelHeading(fontSize: 14, color: PixelTheme.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 18, color: PixelTheme.textMuted),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PixelBadge(text: trStatus(status), color: cfg.color),
                      PixelBadge(text: tr('priority_${priority.label}'), color: priority.color),
                      if (_teamCrewTag(item) != null)
                        PixelBadge(text: _teamCrewTag(item)!, color: PixelTheme.accentCyan),
                      if (upvotes > 0)
                        PixelBadge(text: '▲ ${trCount('common_confirmed_count', upvotes)}', color: PixelTheme.accentCyan),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.map_outlined, size: 12, color: PixelTheme.textMuted),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          location,
                          style: PixelTheme.pixelBody(fontSize: 12, color: PixelTheme.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded, size: 11, color: PixelTheme.textMuted),
                      const SizedBox(width: 5),
                      Text(
                        _formatTime(item['timestamp']?.toString()),
                        style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.textMuted),
                      ),
                    ],
                  ),
                  // AI caption gets its own line — sharing a row with the
                  // timestamp left it truncating mid-percentage on most
                  // screen widths.
                  if (aiCaption != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome, size: 11, color: PixelTheme.accentPurple),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            aiCaption,
                            style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.accentPurple),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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

  Widget _buildOverviewSection() {
    List<Widget> lines = [];

    if (_totalReports > 0 && _categories.isNotEmpty) {
      final sorted = _categories.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = sorted.take(3).toList();
      // Three genuinely distinguishable hues — accentYellow (amber) sits too
      // close to accentOrange to tell apart at a glance in a thin bar.
      final colors = [
        PixelTheme.accentOrange,
        PixelTheme.accentGreen,
        PixelTheme.accentCyan,
      ];

      for (int i = 0; i < top.length; i++) {
        lines.add(_buildProgressLine(
            top[i].key, top[i].value / _totalReports, colors[i]));
      }
    } else {
      lines.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Text(
              tr('home_no_data'),
              style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textMuted),
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
          _buildSectionHeading(tr('home_issue_overview'), Icons.bar_chart_rounded, PixelTheme.accentOrange),
          const SizedBox(height: 20),
          ...lines,
        ],
      ),
    );
  }

  Widget _buildProgressLine(String label, double val, Color col) {
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
                color: PixelTheme.textPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                trCategory(label),
                style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                "${(val * 100).toInt()}%",
                style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
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
                  color: PixelTheme.bgInput,
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
                        color: col,
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