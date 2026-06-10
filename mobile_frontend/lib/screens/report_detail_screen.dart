import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import '../app_config.dart';
import '../user_session.dart';
import 'history_screen.dart'; // For FullScreenImageViewer reference
import 'package:http/http.dart' as http;
import '../widgets/glass_card.dart';
import '../widgets/background_decorator.dart';

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
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _notesController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _report = widget.report;
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
      final streamedResponse = await ApiService.completeTask(
        _report['id'],
        _notesController.text.trim(),
        _proofImage!.path,
      );
      final response = await ResponseDecoder.decode(streamedResponse);
      if (response.statusCode == 200) {
        _showSnackBar('Completion proof submitted successfully!', Colors.green);
        _notesController.clear();
        setState(() => _proofImage = null);
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
    setState(() {
      _proofImage = File(picked.path);
    });
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: Color(0xFF818CF8)),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: Color(0xFF818CF8)),
              title: const Text('Take a Photo'),
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
    final status = _report['status'] ?? ReportStatus.pending;
    final cfg = _getStatusConfig(status);
    final userRole = UserSession.instance.role;
    final isWorker = userRole.toLowerCase().contains('worker');
    final isWorkerCompleted = _report['worker_completed'] == 1;

    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text(
            'Report Details',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF818CF8)),
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
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
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
                    
                    // Reported At timestamp
                    Row(
                      children: [
                        const Icon(Icons.access_time_rounded, color: Color(0xFF94A3B8), size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'Reported at: ${_formatTime(_report['timestamp'])}',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w400),
                        ),
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
                    if (_report['authority_notes'] != null &&
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

  Widget _buildImageHeader() {
    final hasImage = _report['image_path'] != null && _report['image_path'].toString().isNotEmpty;
    final imageUrl = hasImage ? '${ApiService.baseUrl}${_report['image_path']}' : '';

    return Container(
      width: double.infinity,
      height: 240,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
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
                errorBuilder: (_, __, ___) => _buildFallbackImageHeader(),
              )
            else
              _buildFallbackImageHeader(),
            
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
                        color: const Color(0xFF818CF8).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome, color: Colors.white, size: 10),
                          SizedBox(width: 4),
                          Text(
                            'AI Scanned',
                            style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
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

  Widget _buildFallbackImageHeader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.1), width: 1.5),
              ),
              child: const Icon(Icons.image_not_supported_outlined, color: Color(0xFF94A3B8), size: 36),
            ),
            const SizedBox(height: 12),
            const Text(
              'No visual media attached',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2, top: 10),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF818CF8), size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAIBanner() {
    final double confidence = double.tryParse((_report['confidence'] ?? '0').replaceAll('%', '')) ?? 0.0;
    return GlassCard(
      borderColor: const Color(0xFF818CF8).withOpacity(0.25),
      color: const Color(0xFF818CF8).withOpacity(0.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome, color: Color(0xFF818CF8), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI ASSISTED DIAGNOSTICS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF818CF8),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _report['ai_prediction'] ?? 'Unknown',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
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
                          backgroundColor: Colors.white.withOpacity(0.08),
                          color: const Color(0xFF818CF8),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${confidence.toInt()}% Match',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF818CF8),
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
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF818CF8).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.location_on_rounded, color: Color(0xFF818CF8), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _report['address'] ?? _report['location'] ?? 'Location unknown',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
                if (_report['latitude'] != null && _report['longitude'] != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'GPS: ${_report['latitude'].toStringAsFixed(6)}, ${_report['longitude'].toStringAsFixed(6)}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard() {
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.notes_rounded, color: Color(0xFF94A3B8), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _report['description'] ?? 'No description provided.',
              style: const TextStyle(fontSize: 14, color: Color(0xFFE2E8F0), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineCard() {
    final status = _report['status'] ?? ReportStatus.pending;
    
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
                ? 'Assigned to Worker: ${_report['assigned_worker']}'
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
    bool isLast = false,
  }) {
    Color nodeColor;
    Color iconColor;
    Color labelColor;
    double borderWidth = 0;
    Color? borderColor;

    if (done) {
      nodeColor = const Color(0xFF059669).withOpacity(0.15); // light green
      iconColor = const Color(0xFF34D399); // emerald-400
      labelColor = const Color(0xFFE2E8F0);
    } else if (isActive) {
      nodeColor = const Color(0xFF818CF8).withOpacity(0.15); // light indigo
      iconColor = const Color(0xFF818CF8); // indigo
      labelColor = Colors.white;
      borderWidth = 1.5;
      borderColor = const Color(0xFF818CF8);
    } else {
      nodeColor = Colors.white.withOpacity(0.04);
      iconColor = const Color(0xFF64748B);
      labelColor = const Color(0xFF64748B);
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
                          color: const Color(0xFF818CF8).withOpacity(0.15),
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
                color: done ? const Color(0xFF059669).withOpacity(0.3) : Colors.white.withOpacity(0.08),
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
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w400),
                ),
              ] else if (isActive) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF818CF8).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Active Stage',
                    style: TextStyle(fontSize: 9, color: Color(0xFF818CF8), fontWeight: FontWeight.bold),
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
            bubbleColor = const Color(0xFF059669).withOpacity(0.15); // emerald-50
            textColor = const Color(0xFF34D399); // emerald-400
            borderColor = const Color(0xFF059669).withOpacity(0.3); // emerald-100
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
            bubbleColor = const Color(0xFF2563EB).withOpacity(0.15); // blue-50
            textColor = const Color(0xFF60A5FA); // blue-400
            borderColor = const Color(0xFF2563EB).withOpacity(0.3); // blue-100
            align = CrossAxisAlignment.start;
            radius = const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            );
          } else {
            sender = 'System Log';
            bubbleColor = Colors.white.withOpacity(0.04);
            textColor = const Color(0xFF94A3B8);
            borderColor = Colors.white.withOpacity(0.08);
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
    final double completionConfidence = double.tryParse((_report['completion_confidence'] ?? '0').replaceAll('%', '')) ?? 0.0;
    final hasCompImg = _report['completion_image_path'] != null && _report['completion_image_path'].toString().isNotEmpty;
    final compImageUrl = hasCompImg ? '${ApiService.baseUrl}${_report['completion_image_path']}' : '';

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
                        color: Colors.white.withOpacity(0.04),
                        child: const Center(
                          child: Icon(Icons.broken_image_outlined, color: Colors.grey, size: 36),
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
                color: const Color(0xFF7E22CE).withOpacity(0.1), // purple-50
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF7E22CE).withOpacity(0.25)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle),
                    child: const Icon(Icons.auto_awesome, color: Color(0xFFC084FC), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI Verification Prediction',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFC084FC),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _report['completion_ai_prediction'] ?? '',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7E22CE),
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

          const Text(
            'Worker Notes:',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 4),
          Text(
            _report['completion_notes'] ?? 'No completion notes provided.',
            style: const TextStyle(fontSize: 14, color: Color(0xFFE2E8F0), height: 1.4),
          ),
          if (_report['completion_submitted_at'] != null) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF34D399), size: 14),
                const SizedBox(width: 4),
                Text(
                  'Submitted: ${_formatTime(_report['completion_submitted_at'])}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF34D399), fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWorkerActionCard(String status) {
    if (status == ReportStatus.inProcess) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF0284C7).withOpacity(0.08), // light sky blue
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.white10,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.engineering_rounded, color: Color(0xFF38BDF8), size: 32),
            ),
            const SizedBox(height: 14),
            const Text(
              'Accept & Start Maintenance',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'Let the authority know that you have arrived and are starting work on this task.',
              style: TextStyle(fontSize: 13, color: Color(0xFF38BDF8), height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isLoadingAction ? null : _handleStartMaintenance,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF0284C7).withOpacity(0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _isLoadingAction
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text(
                        'Accept & Start Work',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    if (status == ReportStatus.inMaintenance) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF7E22CE).withOpacity(0.08), // light purple
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF7E22CE).withOpacity(0.3), width: 1.5),
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.camera_alt_rounded, color: Color(0xFFC084FC), size: 22),
                  SizedBox(width: 8),
                  Text(
                    'Submit Completion Proof',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Image Picker Area
              GestureDetector(
                onTap: _showImagePickerOptions,
                child: Container(
                  width: double.infinity,
                  height: 160,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF7E22CE).withOpacity(0.25), width: 1.5),
                  ),
                  child: _proofImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(_proofImage!, fit: BoxFit.cover),
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
                              decoration: const BoxDecoration(
                                color: Colors.white10,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.add_a_photo_rounded, color: Color(0xFFC084FC), size: 28),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Tap to attach completion photo',
                              style: TextStyle(color: Color(0xFFC084FC), fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'JPG or PNG format, up to 10MB',
                              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Notes text area
              const Text(
                'Completion Notes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFC084FC)),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                style: const TextStyle(fontSize: 14, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Describe the maintenance work completed (e.g. patched potholes, replaced lightbulb)...',
                  fillColor: Colors.white.withOpacity(0.04),
                  filled: true,
                  hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: const Color(0xFF7E22CE).withOpacity(0.25)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: const Color(0xFF7E22CE).withOpacity(0.25)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFC084FC), width: 1.5),
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
                    backgroundColor: const Color(0xFF7E22CE),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF7E22CE).withOpacity(0.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _isLoadingAction
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                        )
                      : const Text(
                          'Submit Completion Proof',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
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
