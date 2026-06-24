import 'dart:io';
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
  File? _proofImage;
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
          
          final List<LatLng> points = coordinates.map((c) => LatLng(c[1] as double, c[0] as double)).toList();
          
          final distanceMeters = route['distance'] as double;
          final durationSeconds = route['duration'] as double;
          
          setState(() {
            _routePoints = points;
            _routeDistance = distanceMeters >= 1000
                ? '${(distanceMeters / 1000).toStringAsFixed(1)} km'
                : '${distanceMeters.toStringAsFixed(0)} m';
            _routeDuration = '${(durationSeconds / 60).toStringAsFixed(0)} mins';
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
        _showSnackBar('Maintenance started successfully!', Colors.green);
        await _refreshReport();
      } else {
        final err = jsonDecode(res.body)['detail'] ?? 'Failed to update';
        _showSnackBar('Error: $err', Colors.redAccent);
      }
    } catch (e) {
      _showSnackBar('Connection failed. Please check network.', Colors.redAccent);
    } finally {
      if (mounted) setState(() => _isLoadingAction = false);
    }
  }

  // Action: Worker submits completion proof
  Future<void> _handleCompleteTask() async {
    if (!_formKey.currentState!.validate()) return;
    if (_proofImage == null) {
      _showSnackBar('Please select or capture a completion proof photo.', Colors.redAccent);
      return;
    }

    setState(() => _isLoadingAction = true);
    try {
      final streamedResponse = kIsWeb
          ? await ApiService.completeTaskBytes(
              _report['id'],
              _notesController.text.trim(),
              _proofImageBytes,
              _proofImageName,
            )
          : await ApiService.completeTask(
              _report['id'],
              _notesController.text.trim(),
              _proofImage!.path,
            );
      final response = await ResponseDecoder.decode(streamedResponse);
      if (response.statusCode == 200) {
        _showSnackBar('Completion proof submitted successfully!', Colors.green);
        _notesController.clear();
        setState(() {
          _proofImage = null;
          _proofImageBytes = null;
          _proofImageName = null;
        });
        await _refreshReport();
      } else {
        final err = jsonDecode(response.body)['detail'] ?? 'Failed to submit proof';
        _showSnackBar('Error: $err', Colors.redAccent);
      }
    } catch (e) {
      _showSnackBar('Connection failed. Please check network.', Colors.redAccent);
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
      _proofImage = File(picked.path);
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
                color: isDark ? Colors.white : const Color(0xFF0D9488),
              ),
              title: Text(
                'Choose from Gallery',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                color: isDark ? Colors.white : const Color(0xFF0D9488),
              ),
              title: Text(
                'Take a Photo',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF1C1917),
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
        content: Text(msg),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
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
            color: Color(0xFF0EA5E9),
            bg: Color(0xFFF0F9FF),
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

  String _formatTime(String? ts) {
    if (ts == null || ts.isEmpty) return 'Unknown';
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
    final cfg = _getStatusConfig(status);
    final userRole = UserSession.instance.role;
    final isWorker = userRole.toLowerCase().contains('worker');
    final isWorkerCompleted = _report['worker_completed'] == 1;

    final appBarColor = isDark ? Colors.white : const Color(0xFF1C1917);

    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            'Report Details',
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
              tooltip: 'Refresh',
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
                            _report['categories'] ?? 'Uncategorized',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                                cfg.label,
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
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), 
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Reported at: ${_formatTime(_report['timestamp'])}',
                              style: TextStyle(
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), 
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
                    _buildSectionHeader('Location Details', Icons.location_on_rounded),
                    _buildLocationCard(),

                    const SizedBox(height: 20),

                    // Description Card
                    _buildSectionHeader('Description', Icons.description_rounded),
                    _buildDescriptionCard(),

                    // Timeline / History Step progress
                    const SizedBox(height: 20),
                    _buildSectionHeader('Workflow Timeline', Icons.route_rounded),
                    _buildTimelineCard(),

                    // Communication Thread (if authority notes present)
                    if (userRole.toLowerCase() != 'citizen' &&
                        _report['authority_notes'] != null &&
                        (_report['authority_notes'] as String).trim().isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _buildSectionHeader('Communication Thread', Icons.forum_rounded),
                      _buildAuthorityNotesCard(),
                    ],

                    // Worker Completion Proof (if completed already)
                    if (isWorkerCompleted) ...[
                      const SizedBox(height: 20),
                      _buildSectionHeader('Completion Proof', Icons.task_alt_rounded),
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

    final Color baseColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final Color inactiveColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);

    final Color glowColor = upvotes >= 5
        ? const Color(0xFFF59E0B)
        : upvotes >= 2
            ? const Color(0xFFEC4899)
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
                          _showSnackBar('Upvote recorded! Thanks for supporting this report.', Colors.green);
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
                          _showSnackBar('Failed to upvote report.', Colors.redAccent);
                        }
                      } catch (e) {
                        _showSnackBar('Connection error: $e', Colors.redAccent);
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
                upvotes > 0 ? '$upvotes Upvotes' : 'Upvote',
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
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF5F5F4),
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
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'Tap to View Photo',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
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
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome, color: Color(0xFF1C1917), size: 10),
                          SizedBox(width: 4),
                          Text(
                            'AI Scanned',
                            style: TextStyle(color: Color(0xFF1C1917), fontSize: 10, fontWeight: FontWeight.bold),
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
      color: isDark ? const Color(0xFF161616) : const Color(0xFFF5F5F4),
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
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), 
                size: 36,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'No visual media attached',
              style: TextStyle(
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), 
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
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF1C1917);

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final double confidence = double.tryParse((_report['confidence'] ?? '0').replaceAll('%', '')) ?? 0.0;
    
    return GlassCard(
      borderColor: isDark ? Colors.white.withOpacity(0.2) : const Color(0xFF0D9488).withOpacity(0.3),
      color: isDark ? Colors.white.withOpacity(0.08) : const Color(0xFF0D9488).withOpacity(0.06),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : const Color(0xFF0D9488).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.auto_awesome, 
              color: isDark ? Colors.white : const Color(0xFF0D9488), 
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI ASSISTED DIAGNOSTICS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white70 : const Color(0xFF0D9488),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _report['ai_prediction'] ?? 'Unknown',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF1C1917),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: confidence / 100.0,
                          backgroundColor: isDark ? Colors.white.withOpacity(0.08) : const Color(0xFF0D9488).withOpacity(0.1),
                          color: isDark ? Colors.white : const Color(0xFF0D9488),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${confidence.toInt()}% Match',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0D9488),
                      ),
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
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    
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
                        'Task Location',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.tealAccent : const Color(0xFF0D9488),
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _report['address'] ?? _report['location'] ?? 'Location unknown',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                  label: const Text('Directions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                  color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFF0D9488).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.location_on_rounded, 
                  color: isDark ? Colors.white : const Color(0xFF0D9488), 
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _report['address'] ?? _report['location'] ?? 'Location unknown',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                        height: 1.4,
                      ),
                    ),
                    if (lat != null && lng != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'GPS: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
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
    final secondaryTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.05) : const Color(0xFF78716C).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.notes_rounded, color: secondaryTextColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _report['description'] ?? 'No description provided.',
              style: TextStyle(
                fontSize: 14, 
                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1C1917), 
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
              label: 'Report Submitted',
              time: _formatTime(_report['timestamp']),
              done: true,
              isActive: false,
            ),
            _buildTimelineStep(
              icon: Icons.cancel_outlined,
              label: 'Rejected by Admin',
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
            label: 'Report Submitted',
            time: _formatTime(_report['timestamp']),
            done: s1Done,
            isActive: s1Active,
          ),
          _buildTimelineStep(
            icon: Icons.rate_review_rounded,
            label: _report['reviewed_at'] != null
                ? 'Approved & Forwarded to Dept'
                : 'Awaiting Admin Review',
            time: _formatTime(_report['reviewed_at'] ?? _report['forwarded_at']),
            done: s2Done,
            isActive: s2Active,
          ),
          _buildTimelineStep(
            icon: Icons.engineering_rounded,
            label: _report['in_process_at'] != null
                ? (UserSession.instance.role.toLowerCase() == 'citizen' ? 'Task Assigned to Worker' : 'Assigned to Worker: ${_report['assigned_worker']}')
                : 'Awaiting Worker Assignment',
            time: _formatTime(_report['in_process_at']),
            done: s3Done,
            isActive: s3Active,
          ),
          _buildTimelineStep(
            icon: Icons.construction_rounded,
            label: _report['completion_submitted_at'] != null
                ? 'Maintenance Completed'
                : (_report['in_maintenance_at'] != null
                    ? 'Maintenance In Progress'
                    : 'Awaiting Maintenance'),
            time: _formatTime(_report['completion_submitted_at'] ?? _report['in_maintenance_at']),
            done: s4Done,
            isActive: s4Active,
          ),
          _buildTimelineStep(
            icon: Icons.check_circle_rounded,
            label: _report['resolved_at'] != null
                ? 'Resolved & Verified'
                : 'Awaiting Verification',
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
      labelColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1C1917);
      if (isActive || done) {
        borderWidth = 1.5;
        borderColor = customColor;
      }
    } else if (done) {
      nodeColor = isDark 
          ? const Color(0xFF059669).withOpacity(0.15) 
          : const Color(0xFF059669).withOpacity(0.1);
      iconColor = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
      labelColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1C1917);
    } else if (isActive) {
      final activeColor = isLast ? const Color(0xFF059669) : const Color(0xFF0D9488);
      nodeColor = isDark 
          ? (isLast ? const Color(0xFF34D399).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
          : activeColor.withOpacity(0.15);
      iconColor = isDark ? (isLast ? const Color(0xFF34D399) : Colors.white) : activeColor;
      labelColor = isDark ? Colors.white : const Color(0xFF1C1917);
      borderWidth = 1.5;
      borderColor = isDark ? (isLast ? const Color(0xFF34D399) : Colors.white) : activeColor;
    } else {
      nodeColor = isDark 
          ? Colors.white.withOpacity(0.04) 
          : Colors.black.withOpacity(0.04);
      iconColor = isDark ? const Color(0xFF64748B) : const Color(0xFF78716C);
      labelColor = isDark ? const Color(0xFF64748B) : const Color(0xFF78716C);
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
                              ? (isLast ? const Color(0xFF34D399).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
                              : (isLast ? const Color(0xFF059669).withOpacity(0.15) : const Color(0xFF0D9488).withOpacity(0.15)),
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
                    ? const Color(0xFF059669).withOpacity(0.3) 
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
              if (time != 'Unknown' && done) ...[
                const SizedBox(height: 4),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 11, 
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), 
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ] else if (isActive) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark 
                        ? (isLast ? const Color(0xFF34D399).withOpacity(0.15) : Colors.white.withOpacity(0.15)) 
                        : (isLast ? const Color(0xFF059669).withOpacity(0.15) : const Color(0xFF0D9488).withOpacity(0.15)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Active Stage',
                    style: TextStyle(
                      fontSize: 9, 
                      color: isDark 
                          ? (isLast ? const Color(0xFF34D399) : Colors.white) 
                          : (isLast ? const Color(0xFF059669) : const Color(0xFF0D9488)), 
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
          
          String sender = 'System';
          String content = line;
          Color bubbleColor;
          Color textColor;
          Color borderColor;
          CrossAxisAlignment align;
          BorderRadius radius;

          if (isAuth) {
            sender = 'Authority Dept';
            content = line.replaceFirst('[Authority]', '').trim();
            bubbleColor = isDark 
                ? const Color(0xFF059669).withOpacity(0.15) 
                : const Color(0xFFECFDF5);
            textColor = isDark ? const Color(0xFF34D399) : const Color(0xFF05593F);
            borderColor = isDark 
                ? const Color(0xFF059669).withOpacity(0.3) 
                : const Color(0xFFA7F3D0);
            align = CrossAxisAlignment.end;
            radius = const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            );
          } else if (isAdmin) {
            sender = 'City Admin';
            content = line.replaceFirst('[Admin]', '').trim();
            bubbleColor = isDark 
                ? const Color(0xFF2563EB).withOpacity(0.15) 
                : const Color(0xFFEFF6FF);
            textColor = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1E40AF);
            borderColor = isDark 
                ? const Color(0xFF2563EB).withOpacity(0.3) 
                : const Color(0xFFBFDBFE);
            align = CrossAxisAlignment.start;
            radius = const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            );
          } else {
            sender = 'System Log';
            bubbleColor = isDark 
                ? Colors.white.withOpacity(0.04) 
                : Colors.black.withOpacity(0.04);
            textColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
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
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in_rounded, color: Colors.white, size: 12),
                          SizedBox(width: 4),
                          Text('View Full', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
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
                color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFF0EA5E9).withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFF0EA5E9).withOpacity(0.2),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white10 : const Color(0xFF0EA5E9).withOpacity(0.1), 
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.auto_awesome, 
                      color: isDark ? Colors.white : const Color(0xFF0EA5E9), 
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI Verification Prediction',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white70 : const Color(0xFF0EA5E9),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _report['completion_ai_prediction'] ?? '',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF1C1917),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9),
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
            'Worker Notes:',
            style: TextStyle(
              fontSize: 11, 
              fontWeight: FontWeight.bold, 
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _report['completion_notes'] ?? 'No completion notes provided.',
            style: TextStyle(
              fontSize: 14, 
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1C1917), 
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
                  color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669), 
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  'Submitted: ${_formatTime(_report['completion_submitted_at'])}',
                  style: TextStyle(
                    fontSize: 11, 
                    color: isDark ? const Color(0xFF34D399) : const Color(0xFF059669), 
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
                : const Color(0xFFE7E5E4), 
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.engineering_rounded, 
                color: isDark ? Colors.white : const Color(0xFF1C1917), 
                size: 32,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Accept & Start Maintenance',
              style: TextStyle(
                fontSize: 16, 
                fontWeight: FontWeight.bold, 
                color: isDark ? Colors.white : const Color(0xFF1C1917),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Let the authority know that you have arrived and are starting work on this task.',
              style: TextStyle(
                fontSize: 13, 
                color: isDark ? Colors.white70 : const Color(0xFF78716C), 
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
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.white.withOpacity(0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  side: isDark ? null : BorderSide(color: Colors.black.withOpacity(0.15), width: 1.2),
                  elevation: 0,
                ),
                child: _isLoadingAction
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5),
                      )
                    : const Text(
                        'Accept & Start Work',
                        style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    if (status == ReportStatus.inMaintenance) {
      final secondaryColor = isDark ? const Color(0xFF64748B) : const Color(0xFF78716C);

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
                : const Color(0xFFE7E5E4), 
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
                  Icon(Icons.camera_alt_rounded, color: isDark ? Colors.white : const Color(0xFF1C1917), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    'Submit Completion Proof',
                    style: TextStyle(
                      fontSize: 16, 
                      fontWeight: FontWeight.bold, 
                      color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                          : const Color(0xFFE7E5E4), 
                      width: 1.5,
                    ),
                  ),
                  child: _proofImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              kIsWeb
                                  ? Image.memory(_proofImageBytes!, fit: BoxFit.cover)
                                  : Image.file(_proofImage!, fit: BoxFit.cover),
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.6),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.cached_rounded, color: Colors.white, size: 12),
                                      SizedBox(width: 4),
                                      Text('Change', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
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
                                color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.add_a_photo_rounded, color: isDark ? Colors.white : const Color(0xFF1C1917), size: 28),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Tap to attach completion photo',
                              style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'JPG or PNG format, up to 10MB',
                              style: TextStyle(color: secondaryColor, fontSize: 11),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Notes text area
              Text(
                'Completion Notes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : const Color(0xFF78716C)),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                style: TextStyle(fontSize: 14, color: isDark ? Colors.white : const Color(0xFF1C1917)),
                decoration: InputDecoration(
                  hintText: 'Describe the maintenance work completed (e.g. patched potholes, replaced lightbulb)...',
                  fillColor: isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.01),
                  filled: true,
                  hintStyle: TextStyle(color: secondaryColor, fontSize: 13),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFFE7E5E4),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white.withOpacity(0.15) : const Color(0xFFE7E5E4),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: isDark ? Colors.white : Colors.black, width: 1.5),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter completion notes';
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
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white.withOpacity(0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: isDark ? null : BorderSide(color: Colors.black.withOpacity(0.15), width: 1.2),
                    elevation: 0,
                  ),
                  child: _isLoadingAction
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5),
                        )
                      : const Text(
                          'Submit Completion Proof',
                          style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.bold),
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

class _StatusConfig {
  final Color color;
  final Color bg;
  final IconData icon;
  final String label;
  const _StatusConfig({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
  });
}
