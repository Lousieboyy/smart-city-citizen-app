import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../app_config.dart';
import '../user_session.dart';
import 'login_screen.dart';
import 'report_detail_screen.dart';
import '../widgets/glass_card.dart';
import '../widgets/pixel_widgets.dart';
import '../pixel_theme.dart';
import '../localization/app_strings.dart';

/// Report history screen.
class HistoryScreen extends StatefulWidget {
  /// Status to pre-filter to when arriving here from another tab (e.g. a
  /// tapped stat card on Home/Profile). Null/'All' shows everything.
  final String? initialStatusFilter;

  const HistoryScreen({super.key, this.initialStatusFilter});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _reports = [];
  bool _isLoading = true;
  Timer? _refreshTimer;

  final _statusOptions = ['All', ...ReportStatus.all];
  late String _filterStatus = widget.initialStatusFilter ?? 'All';

  // Cache of geocoded addresses for items that have coordinate addresses
  final Map<int, String> _resolvedAddresses = {};

  @override
  void initState() {
    super.initState();
    _fetchReports();

    // Auto-refresh history every 30 seconds silently in the background
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        _fetchReports(silent: true);
      }
    });
  }

  @override
  void didUpdateWidget(HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-apply the requested filter each time we're navigated back to this
    // tab with a new one (e.g. tapping a different stat card on Home).
    if (widget.initialStatusFilter != null &&
        widget.initialStatusFilter != oldWidget.initialStatusFilter) {
      setState(() => _filterStatus = widget.initialStatusFilter!);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchReports({bool silent = false}) async {
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

    if (!silent) setState(() => _isLoading = true);

    try {
      final response = await ApiService.getReports(
        userId:   session.userId,
        role:     session.role,
        username: session.username,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List<dynamic>;
        data.sort((a, b) {
          final ta = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime(0);
          final tb = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime(0);
          return tb.compareTo(ta);
        });
        setState(() {
          _reports   = data;
          _isLoading = false;
        });
      } else {
        throw Exception('Server error ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${tr('history_load_error_prefix')}$e'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  List<dynamic> get _filteredReports {
    if (_filterStatus == 'All') return _reports;
    return _reports.where((r) => (r['status'] ?? ReportStatus.pending) == _filterStatus).toList();
  }

  String _formatTime(String? ts) {
    if (ts == null) return tr('common_unknown');
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

  Future<void> _reverseGeocodeHistoryItem(int id, double? lat, double? lon) async {
    if (lat == null || lon == null) return;
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon');
      final res = await http.get(url, headers: {
        'User-Agent': 'SmartCityCitizenReportingApp/1.0',
        'Accept-Language': 'en',
      });
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final address = data['display_name'] ?? data['name'];
        if (address != null && mounted) {
          final parts = address.split(',');
          String shortAddress = "";
          if (parts.length > 2) {
            shortAddress = "${parts[0].trim()}, ${parts[1].trim()}";
          } else {
            shortAddress = address.toString();
          }
          setState(() {
            _resolvedAddresses[id] = shortAddress;
          });
        }
      }
    } catch (e) {
      debugPrint("Error reverse geocoding history item: $e");
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
        ? const Color(0xFFB45309) // Amber gold for high votes
        : upvotes >= 2
            ? const Color(0xFF52606D) // Hot pink for trending votes
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
                        color: glowColor, // Glowing color
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        automaticallyImplyLeading: false,
        title: Text(
          tr('history_title'),
          style: PixelTheme.pixelHeading(fontSize: 18, color: PixelTheme.primaryGreen),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: PixelTheme.accentOrange),
            tooltip: tr('common_refresh'),
            onPressed: _fetchReports,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status filter chips — single scrollable row instead of a
          // 2-row wrap, so the list below starts higher on screen.
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: _statusOptions.map((status) {
                final isSelected = _filterStatus == status;
                final Color chipBg = isSelected ? PixelTheme.primaryGreen : Colors.white;
                final Color chipTextColor = isSelected ? Colors.white : PixelTheme.textSecondary;

                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _filterStatus = status),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: chipBg,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: PixelTheme.pixelShadow,
                      ),
                      child: Center(
                        child: Text(
                          status == 'All' ? tr('category_All') : trStatus(status),
                          style: PixelTheme.pixelBody(fontSize: 13, color: chipTextColor, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),

          // Report list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: PixelTheme.accentOrange))
                : RefreshIndicator(
                    onRefresh: _fetchReports,
                    color: PixelTheme.accentOrange,
                    child: _filteredReports.isEmpty
                        ? ListView(
                            children: [
                              SizedBox(
                                  height:
                                      MediaQuery.of(context).size.height * 0.25),
                              Center(
                                child: Column(
                                  children: [
                                    const Icon(Icons.inbox_rounded,
                                        size: 64, color: PixelTheme.textMuted),
                                    const SizedBox(height: 16),
                                    Text(
                                      tr('history_empty'),
                                      style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textSecondary, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 140), // padded at bottom for float nav bar
                            itemCount: _filteredReports.length,
                            itemBuilder: (_, i) =>
                                _buildHistoryCard(_filteredReports[i]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final status = item['status'] ?? ReportStatus.pending;
    final cfg    = getStatusConfig(status);
    final rawAddress = item['address'] ?? item['location'] ?? tr('common_location_unknown');
    final int upvotes = item['upvotes'] is int
        ? item['upvotes']
        : (int.tryParse(item['upvotes']?.toString() ?? '0') ?? 0);

    final isCoords = rawAddress.toString().startsWith('Lat:') ||
                     rawAddress.toString().contains('Lon:') ||
                     RegExp(r'^-?\d+\.\d+').hasMatch(rawAddress.toString());

    String displayAddress = rawAddress.toString();
    if (isCoords) {
      if (_resolvedAddresses.containsKey(id)) {
        displayAddress = _resolvedAddresses[id]!;
      } else {
        final lat = item['latitude'] != null ? double.tryParse(item['latitude'].toString()) : null;
        final lon = item['longitude'] != null ? double.tryParse(item['longitude'].toString()) : null;
        _reverseGeocodeHistoryItem(id, lat, lon);
      }
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReportDetailScreen(report: item),
          ),
        ).then((_) => _fetchReports());
      },
      child: GlassCard(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cfg.color.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_getCategoryIcon((item['categories'] ?? '').toString()), size: 19, color: cfg.color),
                ),
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
                                item['categories'] != null ? trCategory(item['categories'].toString()) : tr('history_unknown_issue'),
                                style: PixelTheme.pixelHeading(fontSize: 14, color: PixelTheme.textPrimary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PixelBadge(text: trStatus(status), color: cfg.color),
                                if (upvotes > 0) ...[
                                  const SizedBox(width: 6),
                                  PixelBadge(text: '▲ $upvotes', color: PixelTheme.accentCyan),
                                ],
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(_formatTime(item['timestamp']),
                            style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.textMuted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Description
              Text(
                item['description'] ?? tr('history_no_description'),
                style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textSecondary, fontWeight: FontWeight.normal),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),

              // Location
              Row(
                children: [
                  const Icon(Icons.location_on_outlined, size: 14, color: PixelTheme.accentOrange),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      displayAddress,
                      style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              // AI prediction tag
              if (item['ai_prediction'] != null) ...[
                const SizedBox(height: 10),
                _buildInfoChip(
                  icon: Icons.auto_awesome,
                  label: '${tr('history_ai_match_prefix')}${item['ai_prediction']} (${item['confidence'] ?? ''})',
                  color: PixelTheme.accentOrange,
                ),
              ],

              // Assigned department tag
              if (item['assigned_department'] != null) ...[
                const SizedBox(height: 6),
                _buildInfoChip(
                  icon: Icons.business_rounded,
                  label: '${tr('history_department_prefix')}${item['assigned_department']}',
                  color: PixelTheme.accentCyan,
                ),
              ],

              // Assigned worker tag
              if (item['assigned_worker'] != null) ...[
                const SizedBox(height: 6),
                _buildInfoChip(
                  icon: Icons.engineering_rounded,
                  label: '${tr('history_assigned_worker_prefix')}${item['assigned_worker']}',
                  color: PixelTheme.accentYellow,
                ),
              ],

              // Authority / dispatch notes thread
              if (item['authority_notes'] != null &&
                  (item['authority_notes'] as String).isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: PixelTheme.bgInput,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.forum_rounded, size: 14, color: PixelTheme.textMuted),
                          const SizedBox(width: 6),
                          Text(tr('history_dispatch_thread'),
                              style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ...(item['authority_notes'] as String)
                          .split('\n')
                          .where((l) => l.isNotEmpty)
                          .map((line) {
                        final isAuth  = line.startsWith('[Authority]');
                        final isAdmin = line.startsWith('[Admin]');
                        final Color txtColor = isAuth
                            ? PixelTheme.accentGreen
                            : (isAdmin ? PixelTheme.accentCyan : PixelTheme.textPrimary);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: PixelTheme.bgSurface,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(line,
                              style: PixelTheme.pixelBody(fontSize: 13, color: txtColor, fontWeight: FontWeight.w500)),
                        );
                      }),
                    ],
                  ),
                ),
              ],

              // Original photo thumbnail
              if (item['image_path'] != null) ...[
                const SizedBox(height: 12),
                _buildImageThumbnail(
                    '${ApiService.baseUrl}${item['image_path'].toString().startsWith('/') ? item['image_path'] : '/${item['image_path']}'}'),
              ],

              // Worker completion proof
              if (item['completion_image_path'] != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: PixelTheme.accentYellow.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified_rounded, size: 14, color: PixelTheme.accentYellow),
                          const SizedBox(width: 6),
                          Text(tr('history_completion_proof'),
                              style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.accentYellow)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _buildImageThumbnail(
                          '${ApiService.baseUrl}${item['completion_image_path'].toString().startsWith('/') ? item['completion_image_path'] : '/${item['completion_image_path']}'}',
                          height: 120),
                      if (item['completion_notes'] != null &&
                          (item['completion_notes'] as String).isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(item['completion_notes'],
                            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary, fontWeight: FontWeight.w500)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: PixelTheme.pixelBody(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildImageThumbnail(String url, {double height = 140}) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => FullScreenImageViewer(imageUrl: url)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          child: Image.network(
            url,
            height: height,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              height: height,
              color: PixelTheme.bgInput,
              child: const Center(
                  child: Icon(Icons.broken_image_outlined, color: PixelTheme.textMuted)),
            ),
          ),
        ),
      ),
    );
  }
}


class FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;
  const FullScreenImageViewer({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    );
  }
}