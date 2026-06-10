import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../app_config.dart';
import '../user_session.dart';
import 'login_screen.dart';
import 'report_detail_screen.dart';
import '../widgets/glass_card.dart';

/// Report history screen.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _reports = [];
  bool _isLoading = true;

  final _statusOptions = ['All', ...ReportStatus.all];
  String _filterStatus = 'All';

  // Cache of geocoded addresses for items that have coordinate addresses
  final Map<int, String> _resolvedAddresses = {};

  @override
  void initState() {
    super.initState();
    _fetchReports();
  }

  Future<void> _fetchReports() async {
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

    setState(() => _isLoading = true);

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
          content: Text('Error loading reports: $e'),
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
    if (ts == null) return 'Unknown';
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        automaticallyImplyLeading: false,
        title: const Text(
          'My Reports',
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 22),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF818CF8)),
            tooltip: 'Refresh',
            onPressed: _fetchReports,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status filter chips (uses Wrap to avoid horizontal scrolling/overflow on mobile)
          Container(
            color: Colors.transparent,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _statusOptions.map((status) {
                final isSelected = _filterStatus == status;
                final cfg = status == 'All' ? null : _getStatusConfig(status);
                final Color activeColor = cfg?.color ?? const Color(0xFF818CF8);
                return GestureDetector(
                  onTap: () => setState(() => _filterStatus = status),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected ? activeColor : Colors.white.withOpacity(0.12),
                        width: 1.2,
                      ),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          // Report list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF818CF8)))
                : RefreshIndicator(
                    onRefresh: _fetchReports,
                    color: const Color(0xFF818CF8),
                    child: _filteredReports.isEmpty
                        ? ListView(
                            children: [
                              SizedBox(
                                  height:
                                      MediaQuery.of(context).size.height * 0.25),
                              const Center(
                                child: Column(
                                  children: [
                                    Icon(Icons.inbox_rounded,
                                        size: 64, color: Color(0xFF64748B)),
                                    SizedBox(height: 16),
                                    Text(
                                      'No reports found.',
                                      style: TextStyle(
                                          color: Color(0xFF94A3B8),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120), // padded at bottom for float nav bar
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
    final cfg    = _getStatusConfig(status);
    final rawAddress = item['address'] ?? item['location'] ?? 'Location unknown';

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
        padding: EdgeInsets.zero,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: cfg.color, width: 4.5),
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: cfg.color.withOpacity(0.1), shape: BoxShape.circle),
                    child: Icon(cfg.icon, color: cfg.color, size: 18),
                  ),
                  const SizedBox(width: 12),
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
                                item['categories'] ?? 'Unknown Issue',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Colors.white),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                  color: cfg.color.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: cfg.color.withOpacity(0.2))),
                              child: Text(cfg.label,
                                  style: TextStyle(
                                      color: cfg.color,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(_formatTime(item['timestamp']),
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Description
              Text(
                item['description'] ?? 'No description provided',
                style: const TextStyle(
                    color: Color(0xFFE2E8F0), fontSize: 13, height: 1.4),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),

              // Location
              Row(
                children: [
                  const Icon(Icons.location_on_outlined, size: 14, color: Color(0xFF94A3B8)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      displayAddress,
                      style: const TextStyle(
                          color: Color(0xFF94A3B8), fontSize: 12),
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
                  label: 'AI Match: ${item['ai_prediction']} (${item['confidence'] ?? ''})',
                  color: const Color(0xFF818CF8),
                  bg: const Color(0xFF818CF8),
                ),
              ],

              // Assigned department tag
              if (item['assigned_department'] != null) ...[
                const SizedBox(height: 6),
                _buildInfoChip(
                  icon: Icons.business_rounded,
                  label: 'Department: ${item['assigned_department']}',
                  color: const Color(0xFF38BDF8),
                  bg: const Color(0xFF38BDF8),
                ),
              ],

              // Assigned worker tag
              if (item['assigned_worker'] != null) ...[
                const SizedBox(height: 6),
                _buildInfoChip(
                  icon: Icons.engineering_rounded,
                  label: 'Assigned Worker: ${item['assigned_worker']}',
                  color: const Color(0xFFC084FC),
                  bg: const Color(0xFFC084FC),
                ),
              ],

              // Authority / dispatch notes thread
              if (item['authority_notes'] != null &&
                  (item['authority_notes'] as String).isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.forum_rounded, size: 13, color: Color(0xFF94A3B8)),
                          SizedBox(width: 6),
                          Text('Dispatch Thread',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF94A3B8))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...(item['authority_notes'] as String)
                          .split('\n')
                          .where((l) => l.isNotEmpty)
                          .map((line) {
                        final isAuth  = line.startsWith('[Authority]');
                        final isAdmin = line.startsWith('[Admin]');
                        Color bubbleColor = Colors.white.withOpacity(0.04);
                        Color txtColor = const Color(0xFFE2E8F0);
                        Color borderColor = Colors.white.withOpacity(0.08);
                        if (isAuth) {
                          bubbleColor = const Color(0xFF059669).withOpacity(0.1);
                          txtColor = const Color(0xFF34D399); // emerald-400
                          borderColor = const Color(0xFF059669).withOpacity(0.2);
                        } else if (isAdmin) {
                          bubbleColor = const Color(0xFF2563EB).withOpacity(0.1);
                          txtColor = const Color(0xFF60A5FA); // blue-400
                          borderColor = const Color(0xFF2563EB).withOpacity(0.2);
                        }
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: bubbleColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: borderColor, width: 0.8),
                          ),
                          child: Text(line,
                              style: TextStyle(
                                fontSize: 11,
                                color: txtColor,
                                fontWeight: FontWeight.w500,
                              )),
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
                    '${ApiService.baseUrl}${item['image_path']}'),
              ],

              // Worker completion proof
              if (item['completion_image_path'] != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.verified_rounded,
                              size: 14, color: Color(0xFFC084FC)),
                          SizedBox(width: 6),
                          Text('Worker Completion Proof',
                              style: TextStyle(
                                  color: Color(0xFFC084FC),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _buildImageThumbnail(
                          '${ApiService.baseUrl}${item['completion_image_path']}',
                          height: 120),
                      if (item['completion_notes'] != null &&
                          (item['completion_notes'] as String).isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(item['completion_notes'],
                            style: const TextStyle(
                                color: Color(0xFFE9D5FF), fontSize: 12, fontWeight: FontWeight.w500)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required Color color,
    required Color bg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.2), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.bold)),
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
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          url,
          height: height,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            height: height,
            color: Colors.white.withOpacity(0.05),
            child: const Center(
                child: Icon(Icons.broken_image_outlined, color: Color(0xFF94A3B8))),
          ),
        ),
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