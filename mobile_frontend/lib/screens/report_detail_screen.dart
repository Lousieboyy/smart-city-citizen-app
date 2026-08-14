import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import '../app_config.dart';
import '../user_session.dart';
import 'history_screen.dart'; // For FullScreenImageViewer reference
import 'package:http/http.dart' as http;
import '../widgets/glass_card.dart';
import '../widgets/background_decorator.dart';
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import '../localization/app_strings.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

/// Detailed view of a single report, containing a status timeline
/// and role-specific action cards for workers to start/complete tasks.
class ReportDetailScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  const ReportDetailScreen({super.key, required this.report});

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  late Map<String, dynamic> _report;
  bool _isLoadingAction = false;
  
  // Worker fields
  XFile? _proofImageFile;
  Uint8List? _proofImageBytes;
  String? _proofImageName;
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _notesController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Worker navigation & route fields
  Position? _workerPosition;
  List<LatLng> _routePoints = [];
  bool _loadingRoute = false;
  String _routeDistance = '';
  String _routeDuration = '';

  @override
  void initState() {
    super.initState();
    _report = widget.report;
    _fetchWorkerLocationAndRoute();
  }

  Future<void> _fetchWorkerLocationAndRoute() async {
    final userRole = UserSession.instance.role;
    final isWorker = userRole.toLowerCase().contains('worker');
    if (!isWorker) return;

    final lat = _report['latitude'] is double
        ? _report['latitude']
        : double.tryParse(_report['latitude']?.toString() ?? '');
    final lng = _report['longitude'] is double
        ? _report['longitude']
        : double.tryParse(_report['longitude']?.toString() ?? '');

    if (lat == null || lng == null) return;

    setState(() => _loadingRoute = true);

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        return;
      }

      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      setState(() {
        _workerPosition = pos;
      });

      final url = 'https://router.project-osrm.org/route/v1/driving/${pos.longitude},${pos.latitude};$lng,$lat?overview=full&geometries=geojson';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final geometry = route['geometry'];
          final coordinates = geometry['coordinates'] as List;
          
          final List<LatLng> points = coordinates.map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();
          
          final distanceMeters = (route['distance'] as num).toDouble();
          final durationSeconds = (route['duration'] as num).toDouble();
          
          setState(() {
            _routePoints = points;
            _routeDistance = distanceMeters >= 1000
                ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
                : '${distanceMeters.toStringAsFixed(0)} m';
            _routeDuration = '${(durationSeconds / 60).toStringAsFixed(0)} ${tr('detail_mins_suffix')}';
          });
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch worker route: $e");
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _launchGoogleMaps(double lat, double lng) async {
    final googleMapsUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
    );
    try {
      await launchUrl(googleMapsUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not launch Google Maps: $e');
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  // Reload report data from server
  Future<void> _refreshReport() async {
    try {
      final session = UserSession.instance;
      final response = await ApiService.getReports(
        userId: session.userId,
        role: session.role,
        username: session.username,
      );
      if (response.statusCode == 200) {
        final List<dynamic> all = jsonDecode(response.body) as List<dynamic>;
        final updated = all.firstWhere((r) => r['id'] == _report['id'], orElse: () => null);
        if (updated != null && mounted) {
          setState(() {
            _report = updated;
          });
        }
      }
    } catch (_) {
      // Fail silently on bg auto-refresh
    }
  }

  // Action: Worker accepts & starts work
  Future<void> _handleStartMaintenance() async {
    setState(() => _isLoadingAction = true);
    try {
      final res = await ApiService.startMaintenance(_report['id']);
      if (res.statusCode == 200) {
        _showSnackBar(tr('detail_maintenance_started'), PixelTheme.accentGreen);
        await _refreshReport();
      } else {
        final err = jsonDecode(res.body)['detail'] ?? tr('detail_update_failed');
        _showSnackBar('${tr('report_error_prefix')}$err', PixelTheme.alertRed);
      }
    } catch (e) {
      _showSnackBar(tr('detail_connection_failed'), PixelTheme.alertRed);
    } finally {
      if (mounted) setState(() => _isLoadingAction = false);
    }
  }

  // Action: Worker submits completion proof
  Future<void> _handleCompleteTask() async {
    if (!_formKey.currentState!.validate()) return;
    if (_proofImageBytes == null && _proofImageFile == null) {
      _showSnackBar(tr('detail_completion_proof_required'), PixelTheme.alertRed);
      return;
    }

    setState(() => _isLoadingAction = true);
    try {
      final streamedResponse = (_proofImageBytes != null)
          ? await ApiService.completeTaskBytes(
              _report['id'],
              _notesController.text.trim(),
              _proofImageBytes,
              _proofImageName,
            )
          : await ApiService.completeTask(
              _report['id'],
              _notesController.text.trim(),
              _proofImageFile!.path,
            );
      final response = await ResponseDecoder.decode(streamedResponse);
      if (response.statusCode == 200) {
        _showSnackBar(tr('detail_completion_proof_submitted'), PixelTheme.accentGreen);
        _notesController.clear();
        setState(() {
          _proofImageFile = null;
          _proofImageBytes = null;
          _proofImageName = null;
        });
        await _refreshReport();
      } else {
        final err = jsonDecode(response.body)['detail'] ?? tr('detail_submit_proof_failed');
        _showSnackBar('${tr('report_error_prefix')}$err', PixelTheme.alertRed);
      }
    } catch (e) {
      _showSnackBar(tr('detail_connection_failed'), PixelTheme.alertRed);
    } finally {
      if (mounted) setState(() => _isLoadingAction = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _proofImageFile = picked;
      _proofImageBytes = bytes;
      _proofImageName = picked.name;
    });
  }

  void _showImagePickerOptions(bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0F0F0F) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                Icons.photo_library_rounded, 
                color: isDark ? Colors.white : const Color(0xFFE08A5B),
              ),
              title: Text(
                tr('report_choose_gallery'),
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF2B2B28),
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.camera_alt_rounded,
                color: isDark ? Colors.white : const Color(0xFFE08A5B),
              ),
              title: Text(
                tr('report_take_photo'),
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF2B2B28),
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSnackBar(String msg, Color bg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }


  String _formatTime(String? ts) {
    if (ts == null || ts.isEmpty) return tr('common_unknown');
    try {
      final dt = DateTime.parse(ts).toLocal();
      return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = _report['status'] ?? ReportStatus.pending;
    final cfg = getStatusConfig(status);
    final userRole = UserSession.instance.role;
    final isWorker = userRole.toLowerCase().contains('worker');
    final isWorkerCompleted = _report['worker_completed'] == 1;

    const appBarColor = PixelTheme.primaryGreen;

    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            tr('detail_title'),
            style: TextStyle(
              color: appBarColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          iconTheme: IconThemeData(color: appBarColor),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: appBarColor),
              onPressed: _refreshReport,
              tooltip: tr('common_refresh'),
            ),
          ],
        ),
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Image
              _buildImageHeader(),

              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Details (Category + Status)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _report['categories'] != null ? trCategory(_report['categories'].toString()) : tr('detail_uncategorized'),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF2B2B28),
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: cfg.color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: cfg.color.withOpacity(0.2), width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cfg.icon, color: cfg.color, size: 14),
                              const SizedBox(width: 5),
                              Text(
                                trStatus(status),
                                style: TextStyle(
                                  color: cfg.color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    
                    // Reported At timestamp & Upvote Button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.access_time_rounded, 
                              color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85), 
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${tr('detail_reported_at_prefix')}${_formatTime(_report['timestamp'])}',
                              style: TextStyle(
                                color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85), 
                                fontSize: 13, 
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                        _buildUpvoteButton(),
                      ],
                    ),

                    // AI Analysis Banner
                    if (_report['ai_prediction'] != null) ...[
                      const SizedBox(height: 18),
                      _buildAIBanner(),
                    ],

                    const SizedBox(height: 20),

                    // Location Card
                    _buildSectionHeader(tr('detail_location_details'), Icons.location_on_rounded),
                    _buildLocationCard(),

                    const SizedBox(height: 20),

                    // Description Card
                    _buildSectionHeader(tr('report_step_description'), Icons.description_rounded),
                    _buildDescriptionCard(),

                    // Timeline / History Step progress
                    const SizedBox(height: 20),
                    _buildSectionHeader(tr('detail_workflow_timeline'), Icons.route_rounded),
                    _buildTimelineCard(),

                    // Communication Thread (if authority notes present)
                    if (userRole.toLowerCase() != 'citizen' &&
                        _report['authority_notes'] != null &&
                        (_report['authority_notes'] as String).trim().isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _buildSectionHeader(tr('detail_communication_thread'), Icons.forum_rounded),
                      _buildAuthorityNotesCard(),
                    ],

                    // Worker Completion Proof (if completed already)
                    if (isWorkerCompleted) ...[
                      const SizedBox(height: 20),
                      _buildSectionHeader(tr('detail_completion_proof'), Icons.task_alt_rounded),
                      _buildCompletionProofCard(),
                    ],

                    // ── ROLE ACTIONS FOR WORKERS ──
                    if (isWorker && !isWorkerCompleted) ...[
                      const SizedBox(height: 24),
                      _buildWorkerActionCard(status),
                    ],

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper UI Widgets ──────────────────────────────────────────────────────

  Widget _buildUpvoteButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final int upvotes = _report['upvotes'] is int
        ? _report['upvotes']
        : (int.tryParse(_report['upvotes']?.toString() ?? '0') ?? 0);
    final isResolved = _report['status'] == 'Resolved';

    final Color baseColor = isDark ? Colors.white : const Color(0xFF2B2B28);
    final Color inactiveColor = isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85);

    final Color glowColor = upvotes >= 5
        ? const Color(0xFFB45309)
        : upvotes >= 2
            ? const Color(0xFF6B7B8C)
            : baseColor;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: isResolved
          ? const SizedBox.shrink()
          : TextButton.icon(
              onPressed: _isLoadingAction
                  ? null
                  : () async {
                      setState(() => _isLoadingAction = true);
                      try {
                        final res = await ApiService.upvoteReport(_report['id']);
                        if (res.statusCode == 200) {
                          final data = jsonDecode(res.body);
                          _showSnackBar(tr('detail_upvote_recorded'), PixelTheme.accentGreen);
                          setState(() {
                            final newCount = data['upvotes'] ?? (upvotes + 1);
                            _report['upvotes'] = newCount;
                            
                            final desc = _report['description'] ?? "";
                            if (desc.contains('[Upvote count:')) {
                              _report['description'] = desc.replaceAll(
                                RegExp(r'\[Upvote count:\s*\d+\]'),
                                '[Upvote count: $newCount]',
                              );
                            } else {
                              _report['description'] = "$desc\n[Upvote count: $newCount]".trim();
                            }
                          });
                        } else {
                          _showSnackBar(tr('detail_upvote_failed'), PixelTheme.alertRed);
                        }
                      } catch (e) {
                        _showSnackBar('${tr('detail_connection_error_prefix')}$e', PixelTheme.alertRed);
                      } finally {
                        if (mounted) setState(() => _isLoadingAction = false);
                      }
                    },
              icon: Icon(
                Icons.thumb_up_alt_rounded,
                size: 14,
                color: upvotes > 0 ? glowColor : inactiveColor,
              ),
              label: Text(
                upvotes > 0 ? trCount('detail_upvotes_count', upvotes) : tr('detail_upvote'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: upvotes > 0 ? glowColor : inactiveColor,
                ),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                backgroundColor: upvotes > 0 
                    ? glowColor.withOpacity(0.12) 
                    : (isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: upvotes > 0 
                        ? glowColor.withOpacity(0.3) 
                        : (isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
                    width: 1.0,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildImageHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasImage = _report['image_path'] != null && _report['image_path'].toString().isNotEmpty;
    final imageUrl = hasImage ? '${ApiService.baseUrl}/${_report['image_path'].toString().replaceFirst(RegExp(r'^/'), '')}' : '';

    return Container(
      width: double.infinity,
      height: 240,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1EDE4),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildFallbackImageHeader(isDark),
              )
            else
              _buildFallbackImageHeader(isDark),
            
            // Gradient Overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.1),
                    Colors.black.withOpacity(0.6),
                  ],
                ),
              ),
            ),
            
            // Tap viewer overlay if has image
            if (hasImage)
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FullScreenImageViewer(imageUrl: imageUrl),
                        ),
                      );
                    },
                  ),
                ),
              ),
              
            // Floating tag on the image
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (hasImage)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            tr('detail_tap_to_view_photo'),
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(),
                  
                  if (_report['ai_prediction'] != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_awesome, color: Color(0xFF2B2B28), size: 10),
                          const SizedBox(width: 4),
                          Text(
                            tr('detail_ai_scanned'),
                            style: const TextStyle(color: Color(0xFF2B2B28), fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
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

  Widget _buildFallbackImageHeader(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF161616) : const Color(0xFFF1EDE4),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.1), 
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.image_not_supported_outlined, 
                color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85), 
                size: 36,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr('detail_no_media'),
              style: TextStyle(
                color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85), 
                fontSize: 13, 
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF2B2B28);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2, top: 10),
      child: Row(
        children: [
          Icon(icon, color: primaryTextColor, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: primaryTextColor,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAIBanner() {
    final double confidence = double.tryParse((_report['confidence'] ?? '0').replaceAll('%', '')) ?? 0.0;
    final String pred = _report['ai_prediction'] != null ? _report['ai_prediction'].toString() : tr('category_Normal');
    final bool isHighMatch = confidence >= 80;
    final Color matchColor = isHighMatch ? const Color(0xFF3F8F5E) : PixelTheme.accentOrange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PixelTheme.bgSurface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: PixelTheme.pixelShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: matchColor.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.auto_awesome, color: matchColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('detail_ai_assisted_diagnostics'),
                  style: PixelTheme.pixelCaption(fontSize: 11, color: matchColor),
                ),
                const SizedBox(height: 4),
                Text(
                  pred,
                  style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: confidence / 100.0,
                          backgroundColor: matchColor.withOpacity(0.15),
                          color: matchColor,
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "${confidence.toInt()}% ${tr('detail_match_suffix')}",
                      style: PixelTheme.pixelCaption(fontSize: 9, color: matchColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondaryColor = isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85);
    
    // Check if worker
    final userRole = UserSession.instance.role;
    final isWorker = userRole.toLowerCase().contains('worker');
    
    final lat = _report['latitude'] is double
        ? _report['latitude']
        : double.tryParse(_report['latitude']?.toString() ?? '');
    final lng = _report['longitude'] is double
        ? _report['longitude']
        : double.tryParse(_report['longitude']?.toString() ?? '');

    // For worker: render full map card instead of text details, with a Waze nav button
    if (isWorker && lat != null && lng != null) {
      return GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('detail_task_location'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.tealAccent : const Color(0xFFE08A5B),
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _report['address'] ?? _report['location'] ?? tr('common_location_unknown'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : const Color(0xFF2B2B28),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => _launchGoogleMaps(lat, lng),
                  icon: const Icon(Icons.directions_rounded, size: 16),
                  label: Text(tr('detail_directions'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4285F4), // Google blue
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 250,
                width: double.infinity,
                child: Stack(
                  children: [
                    FlutterMap(
                      options: MapOptions(
                        initialCenter: LatLng(lat, lng),
                        initialZoom: 14.0,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.smartcity',
                        ),
                        if (_routePoints.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _routePoints,
                                strokeWidth: 4.0,
                                color: Colors.indigo,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: LatLng(lat, lng),
                              width: 30,
                              height: 30,
                              child: const Icon(
                                Icons.location_on_rounded,
                                color: Colors.red,
                                size: 30,
                              ),
                            ),
                            if (_workerPosition != null)
                              Marker(
                                point: LatLng(_workerPosition!.latitude, _workerPosition!.longitude),
                                width: 30,
                                height: 30,
                                child: const Icon(
                                  Icons.my_location_rounded,
                                  color: Colors.blue,
                                  size: 26,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    if (_loadingRoute)
                      Container(
                        color: Colors.black26,
                        child: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                    if (_routeDistance.isNotEmpty && _routeDuration.isNotEmpty)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.75),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white24, width: 0.5),
                          ),
                          child: Text(
                            '🚗 $_routeDistance ($_routeDuration)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Standard fallback location details card for non-workers
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFE08A5B).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.location_on_rounded, 
                  color: isDark ? Colors.white : const Color(0xFFE08A5B), 
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _report['address'] ?? _report['location'] ?? tr('common_location_unknown'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : const Color(0xFF2B2B28),
                        height: 1.4,
                      ),
                    ),
                    if (lat != null && lng != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${tr('detail_gps_label')}: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: secondaryColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondaryTextColor = isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85);
    
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.05) : const Color(0xFF8A8A85).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.notes_rounded, color: secondaryTextColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _report['description'] ?? tr('detail_no_description'),
              style: TextStyle(
                fontSize: 14, 
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF2B2B28), 
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineCard() {
    final status = _report['status'] ?? ReportStatus.pending;
    
    if (status == ReportStatus.rejected) {
      return GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildTimelineStep(
              icon: Icons.add_alert_rounded,
              label: tr('detail_timeline_submitted'),
              time: _formatTime(_report['timestamp']),
              done: true,
              isActive: false,
            ),
            _buildTimelineStep(
              icon: Icons.cancel_outlined,
              label: tr('detail_timeline_rejected'),
              time: _formatTime(_report['reviewed_at'] ?? _report['updated_at']),
              done: true,
              isActive: true,
              customColor: Colors.redAccent,
              isLast: true,
            ),
          ],
        ),
      );
    }

    // Check points
    final s1Done = true;
    final s1Active = status == ReportStatus.pending;

    final s2Done = _report['reviewed_at'] != null || _report['forwarded_at'] != null;
    final s2Active = status == ReportStatus.inReview;

    final s3Done = _report['in_process_at'] != null;
    final s3Active = status == ReportStatus.inProcess;

    final s4Done = _report['in_maintenance_at'] != null;
    final s4Active = status == ReportStatus.inMaintenance;

    final s5Done = _report['resolved_at'] != null;
    final s5Active = status == ReportStatus.resolved;

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          _buildTimelineStep(
            icon: Icons.add_alert_rounded,
            label: tr('detail_timeline_submitted'),
            time: _formatTime(_report['timestamp']),
            done: s1Done,
            isActive: s1Active,
          ),
          _buildTimelineStep(
            icon: Icons.rate_review_rounded,
            label: _report['reviewed_at'] != null
                ? tr('detail_timeline_approved')
                : tr('detail_timeline_awaiting_review'),
            time: _formatTime(_report['reviewed_at'] ?? _report['forwarded_at']),
            done: s2Done,
            isActive: s2Active,
          ),
          _buildTimelineStep(
            icon: Icons.engineering_rounded,
            label: _report['in_process_at'] != null
                ? (UserSession.instance.role.toLowerCase() == 'citizen' ? tr('detail_timeline_assigned_citizen') : '${tr('detail_timeline_assigned_worker_prefix')}${_report['assigned_worker']}')
                : tr('detail_timeline_awaiting_assignment'),
            time: _formatTime(_report['in_process_at']),
            done: s3Done,
            isActive: s3Active,
          ),
          _buildTimelineStep(
            icon: Icons.construction_rounded,
            label: _report['completion_submitted_at'] != null
                ? tr('detail_timeline_maintenance_completed')
                : (_report['in_maintenance_at'] != null
                    ? tr('detail_timeline_maintenance_in_progress')
                    : tr('detail_timeline_awaiting_maintenance')),
            time: _formatTime(_report['completion_submitted_at'] ?? _report['in_maintenance_at']),
            done: s4Done,
            isActive: s4Active,
          ),
          _buildTimelineStep(
            icon: Icons.check_circle_rounded,
            label: _report['resolved_at'] != null
                ? tr('detail_timeline_resolved')
                : tr('detail_timeline_awaiting_verification'),
            time: _formatTime(_report['resolved_at']),
            done: s5Done,
            isActive: s5Active,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineStep({
    required IconData icon,
    required String label,
    required String time,
    required bool done,
    required bool isActive,
    Color? customColor,
    bool isLast = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color nodeColor;
    Color iconColor;
    Color labelColor;
    double borderWidth = 0;
    Color? borderColor;

    if (customColor != null) {
      nodeColor = isDark 
          ? customColor.withOpacity(0.15) 
          : customColor.withOpacity(0.1);
      iconColor = customColor;
      labelColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF2B2B28);
      if (isActive || done) {
        borderWidth = 1.5;
        borderColor = customColor;
      }
    } else if (done) {
      nodeColor = isDark 
          ? const Color(0xFF3F8F5E).withOpacity(0.15) 
          : const Color(0xFF3F8F5E).withOpacity(0.1);
      iconColor = isDark ? const Color(0xFF3F8F5E) : const Color(0xFF3F8F5E);
      labelColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF2B2B28);
    } else if (isActive) {
      final activeColor = isLast ? const Color(0xFF3F8F5E) : const Color(0xFFE08A5B);
      nodeColor = isDark 
          ? (isLast ? const Color(0xFF3F8F5E).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
          : activeColor.withOpacity(0.15);
      iconColor = isDark ? (isLast ? const Color(0xFF3F8F5E) : Colors.white) : activeColor;
      labelColor = isDark ? Colors.white : const Color(0xFF2B2B28);
      borderWidth = 1.5;
      borderColor = isDark ? (isLast ? const Color(0xFF3F8F5E) : Colors.white) : activeColor;
    } else {
      nodeColor = isDark 
          ? Colors.white.withOpacity(0.04) 
          : Colors.black.withOpacity(0.04);
      iconColor = isDark ? const Color(0xFF64748B) : const Color(0xFF8A8A85);
      labelColor = isDark ? const Color(0xFF64748B) : const Color(0xFF8A8A85);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: nodeColor,
                shape: BoxShape.circle,
                border: borderWidth > 0 ? Border.all(color: borderColor!, width: borderWidth) : null,
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: isDark 
                              ? (isLast ? const Color(0xFF3F8F5E).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
                              : (isLast ? const Color(0xFF3F8F5E).withOpacity(0.15) : const Color(0xFFE08A5B).withOpacity(0.15)),
                          blurRadius: 6,
                          spreadRadius: 1,
                        )
                      ]
                    : null,
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 30,
                color: done 
                    ? const Color(0xFF3F8F5E).withOpacity(0.3) 
                    : (isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
              ),
          ],
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8), // align text with the node circle center
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: (isActive || done) ? FontWeight.bold : FontWeight.w500,
                  color: labelColor,
                ),
              ),
              if (time != tr('common_unknown') && done) ...[
                const SizedBox(height: 4),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 11, 
                    color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85), 
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ] else if (isActive) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark 
                        ? (isLast ? const Color(0xFF3F8F5E).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
                        : (isLast ? const Color(0xFF3F8F5E).withOpacity(0.15) : const Color(0xFFE08A5B).withOpacity(0.15)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tr('detail_active_stage'),
                    style: TextStyle(
                      fontSize: 9, 
                      color: isDark 
                          ? (isLast ? const Color(0xFF3F8F5E) : Colors.white) 
                          : (isLast ? const Color(0xFF3F8F5E) : const Color(0xFFE08A5B)), 
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAuthorityNotesCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lines = (_report['authority_notes'] as String)
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();

    return GlassCard(
      child: Column(
        children: lines.map((line) {
          final isAuth = line.startsWith('[Authority]');
          final isAdmin = line.startsWith('[Admin]');
          
          String sender = tr('detail_sender_system');
          String content = line;
          Color bubbleColor;
          Color textColor;
          Color borderColor;
          CrossAxisAlignment align;
          BorderRadius radius;

          if (isAuth) {
            sender = tr('detail_sender_authority');
            content = line.replaceFirst('[Authority]', '').trim();
            bubbleColor = isDark 
                ? const Color(0xFF3F8F5E).withOpacity(0.15) 
                : const Color(0xFFF0FDF4);
            textColor = isDark ? const Color(0xFF3F8F5E) : const Color(0xFF05593F);
            borderColor = isDark 
                ? const Color(0xFF3F8F5E).withOpacity(0.3) 
                : const Color(0xFFA7F3D0);
            align = CrossAxisAlignment.end;
            radius = const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            );
          } else if (isAdmin) {
            sender = tr('detail_sender_admin');
            content = line.replaceFirst('[Admin]', '').trim();
            bubbleColor = isDark 
                ? const Color(0xFF6B7B8C).withOpacity(0.15) 
                : const Color(0xFFF1F5F9);
            textColor = isDark ? const Color(0xFF6B7B8C) : const Color(0xFF334155);
            borderColor = isDark 
                ? const Color(0xFF6B7B8C).withOpacity(0.3) 
                : const Color(0xFFE2E8F0);
            align = CrossAxisAlignment.start;
            radius = const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            );
          } else {
            sender = tr('detail_sender_system_log');
            bubbleColor = isDark 
                ? Colors.white.withOpacity(0.04) 
                : Colors.black.withOpacity(0.04);
            textColor = isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85);
            borderColor = isDark 
                ? Colors.white.withOpacity(0.08) 
                : Colors.black.withOpacity(0.08);
            align = CrossAxisAlignment.start;
            radius = BorderRadius.circular(16);
          }

          return Align(
            alignment: align == CrossAxisAlignment.start ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: radius,
                border: Border.all(color: borderColor, width: 1),
              ),
              child: Column(
                crossAxisAlignment: align,
                children: [
                  Text(
                    sender,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: textColor.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    content,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: textColor,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCompletionProofCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double completionConfidence = double.tryParse((_report['completion_confidence'] ?? '0').replaceAll('%', '')) ?? 0.0;
    final hasCompImg = _report['completion_image_path'] != null && _report['completion_image_path'].toString().isNotEmpty;
    final compImageUrl = hasCompImg ? '${ApiService.baseUrl}/${_report['completion_image_path'].toString().replaceFirst(RegExp(r'^/'), '')}' : '';

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasCompImg) ...[
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FullScreenImageViewer(imageUrl: compImageUrl),
                  ),
                );
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Image.network(
                      compImageUrl,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 100,
                        color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                        child: Center(
                          child: Icon(
                            Icons.broken_image_outlined, 
                            color: isDark ? Colors.grey : Colors.grey[600], 
                            size: 36,
                          ),
                        ),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 12),
                          const SizedBox(width: 4),
                          Text(tr('detail_view_full'), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],

          // AI Verification Banner for completion image
          if (_report['completion_ai_prediction'] != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFF6B7B8C).withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFF6B7B8C).withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : const Color(0xFF6B7B8C).withOpacity(0.1), 
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.auto_awesome, 
                      color: isDark ? Colors.white : const Color(0xFF6B7B8C), 
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('detail_ai_verification_prediction'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white70 : const Color(0xFF6B7B8C),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _report['completion_ai_prediction'] ?? '',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF2B2B28),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6B7B8C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${completionConfidence.toInt()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          Text(
            tr('detail_worker_notes'),
            style: TextStyle(
              fontSize: 11, 
              fontWeight: FontWeight.bold, 
              color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _report['completion_notes'] ?? tr('detail_no_completion_notes'),
            style: TextStyle(
              fontSize: 14, 
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF2B2B28), 
              height: 1.4,
            ),
          ),
          if (_report['completion_submitted_at'] != null) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(
                  Icons.check_circle_rounded, 
                  color: isDark ? const Color(0xFF3F8F5E) : const Color(0xFF3F8F5E), 
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  '${tr('detail_submitted_prefix')}${_formatTime(_report['completion_submitted_at'])}',
                  style: TextStyle(
                    fontSize: 11, 
                    color: isDark ? const Color(0xFF3F8F5E) : const Color(0xFF3F8F5E), 
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWorkerActionCard(String status) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (status == ReportStatus.inProcess) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark 
              ? Colors.white.withOpacity(0.05) 
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark 
                ? Colors.white.withOpacity(0.15) 
                : const Color(0xFFE7E1D5), 
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white10 : const Color(0xFFF1EDE4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.engineering_rounded, 
                color: isDark ? Colors.white : const Color(0xFF2B2B28), 
                size: 32,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              tr('detail_accept_start_maintenance'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF2B2B28),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('detail_accept_start_body'),
              style: TextStyle(
                fontSize: 13, 
                color: isDark ? Colors.white70 : const Color(0xFF8A8A85), 
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoadingAction ? null : _handleStartMaintenance,
                style: ElevatedButton.styleFrom(
                  backgroundColor: PixelTheme.accentOrange,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: PixelTheme.textMuted,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  elevation: 0,
                ),
                child: _isLoadingAction
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : Text(
                        tr('detail_accept_start_button'),
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    if (status == ReportStatus.inMaintenance) {
      final secondaryColor = isDark ? const Color(0xFF64748B) : const Color(0xFF8A8A85);

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark 
              ? Colors.white.withOpacity(0.05) 
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark 
                ? Colors.white.withOpacity(0.15) 
                : const Color(0xFFE7E1D5), 
            width: 1.5,
          ),
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.camera_alt_rounded, color: isDark ? Colors.white : const Color(0xFF2B2B28), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    tr('detail_submit_completion_proof'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF2B2B28),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Image Picker Area
              GestureDetector(
                onTap: () => _showImagePickerOptions(isDark),
                child: Container(
                  width: double.infinity,
                  height: 160,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.01),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark 
                          ? Colors.white.withOpacity(0.15) 
                          : const Color(0xFFE7E1D5), 
                      width: 1.5,
                    ),
                  ),
                  child: (_proofImageBytes != null || _proofImageFile != null)
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _proofImageBytes != null
                                  ? Image.memory(_proofImageBytes!, fit: BoxFit.cover)
                                  : const SizedBox.shrink(),
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.cached_rounded, color: Colors.white, size: 12),
                                      const SizedBox(width: 4),
                                      Text(tr('detail_change'), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white10 : const Color(0xFFF1EDE4),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.add_a_photo_rounded, color: isDark ? Colors.white : const Color(0xFF2B2B28), size: 28),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              tr('detail_tap_to_attach_photo'),
                              style: TextStyle(color: isDark ? Colors.white : const Color(0xFF2B2B28), fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              tr('detail_photo_format_hint'),
                              style: TextStyle(color: secondaryColor, fontSize: 11),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Notes text area
              Text(
                tr('detail_completion_notes'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : const Color(0xFF8A8A85)),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                style: TextStyle(fontSize: 14, color: isDark ? Colors.white : const Color(0xFF2B2B28)),
                decoration: InputDecoration(
                  hintText: tr('detail_completion_notes_hint'),
                  fillColor: isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.01),
                  filled: true,
                  hintStyle: TextStyle(color: secondaryColor, fontSize: 13),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFFE7E1D5),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFFE7E1D5),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: isDark ? Colors.white : Colors.black, width: 1.5),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return tr('detail_completion_notes_error');
                  }
                  return null;
                },
              ),
              const SizedBox(height: 18),

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoadingAction ? null : _handleCompleteTask,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: PixelTheme.accentOrange,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: PixelTheme.textMuted,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    elevation: 0,
                  ),
                  child: _isLoadingAction
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                        )
                      : Text(
                          tr('detail_submit_completion_proof'),
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return const SizedBox();
  }
}

/// Helper class to decode API StreamedResponses
class ResponseDecoder {
  static Future<http.Response> decode(http.StreamedResponse streamed) async {
    final bytes = await streamed.stream.toBytes();
    return http.Response.bytes(bytes, streamed.statusCode, headers: streamed.headers);
  }
}

