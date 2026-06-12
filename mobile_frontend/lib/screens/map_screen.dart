import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import 'package:latlong2/latlong.dart';
import '../widgets/glass_card.dart';
import 'report_detail_screen.dart';

class MapViewScreen extends StatefulWidget {
  const MapViewScreen({super.key});

  @override
  State<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends State<MapViewScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  // ── flutter_map controller ────────────────────────────────────────────
  final MapController _mapController = MapController();

  // ── Location state ────────────────────────────────────────────────────
  Position? _currentPosition;
  bool _locationLoading = true;
  String? _locationError;

  // Default center (Melaka, Malaysia) — shown briefly while GPS loads
  LatLng _mapCenter = const LatLng(2.1896, 102.2501);
  double _mapZoom = 14.0;

  // ── Address geocoding state ───────────────────────────────────────────
  String _currentAddressName = "Melaka City, Malaysia";

  // ── UI Visibility state ───────────────────────────────────────────────
  bool _showLegend = false;

  // ── Map style state ───────────────────────────────────────────────────
  String _mapStyle = 'Muted Light';

  // ── Category filter ───────────────────────────────────────────────────
  final List<String> _categories = ["All", "Road", "Lighting", "Waste", "Drainage"];
  int _selectedCategory = 0;

  // ── Issue data ────────────────────────────────────────────────────────
  List<_IssueMarker> _issues = [];
  bool _showHeatmap = false;

  // ── Resolved & Status filter ──────────────────────────────────────────
  bool _showResolvedOnly = false;
  String _statusFilter = 'All';
  final List<String> _statusOptions = [
    'All', 'Pending', 'In Review', 'In Process', 'In Maintenance', 'Resolved',
  ];

  // ── Lifecycle ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _requestLocationAndLoad();
  }

  @override
  void dispose() {
    _mapController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── GPS Logic ─────────────────────────────────────────────────────────
  Future<void> _requestLocationAndLoad() async {
    if (!mounted) return;
    setState(() {
      _locationLoading = true;
      _locationError = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() {
          _locationError = 'Location services are disabled.\nPlease enable GPS in device settings.';
          _locationLoading = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (!mounted) return;
          setState(() {
            _locationError = 'Location permission denied.\nPlease allow location access.';
            _locationLoading = false;
          });
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _locationError =
              'Location permission permanently denied.\nOpen app settings to grant access.';
          _locationLoading = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );

      if (!mounted) return;
      final userLatLng = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentPosition = position;
        _mapCenter = userLatLng;
        _mapZoom = 15.5;
        _locationLoading = true; // keep loading while we fetch reports
      });

      _mapController.move(userLatLng, 15.5);

      // Fetch human-readable address in the background
      _reverseGeocode(position.latitude, position.longitude);

      await _fetchReports();

      if (!mounted) return;
      setState(() {
        _locationLoading = false;
      });

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = 'Could not get location:\n${e.toString()}';
        _locationLoading = false;
      });
    }
  }

  Future<void> _fetchReports() async {
    try {
      final response = await ApiService.getReports();
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        List<_IssueMarker> fetchedIssues = [];
        for (var report in data) {
          if (report['latitude'] != null && report['longitude'] != null) {
            String cat = (report['categories'] ?? 'Unknown').toString();
            String status = (report['status'] ?? 'Pending').toString();
            
            String priority;
            Color mapColor;

            if (status == 'Resolved') {
              priority = 'Resolved';
              mapColor = const Color(0xFF2196F3); // Blue for resolved
            } else if (cat.contains('Damage') || cat.contains('Drainage') || cat.contains('Tree')) {
              priority = 'High';
              mapColor = Colors.red;
            } else {
              priority = 'Medium';
              mapColor = Colors.orange;
            }
            
            fetchedIssues.add(_IssueMarker(
              id: (report['id'] ?? report.hashCode).toString(),
              label: cat,
              position: LatLng(report['latitude'], report['longitude']),
              priority: priority,
              color: mapColor,
              rawData: report as Map<String, dynamic>,
            ));
          }
        }
        setState(() {
          _issues = fetchedIssues;
        });
      }
    } catch (e) {
      debugPrint("Error fetching map reports: $e");
    }
  }

  List<_IssueMarker> get _filteredIssues {
    List<_IssueMarker> filtered = List.from(_issues);

    // Category filter
    if (_selectedCategory != 0) {
      final cat = _categories[_selectedCategory].toLowerCase();
      filtered = filtered.where((m) => m.label.toLowerCase().contains(cat)).toList();
    }

    // Resolved-only toggle
    if (_showResolvedOnly) {
      filtered = filtered.where((m) => m.rawData['status'] == 'Resolved').toList();
    }

    // Status dropdown filter
    if (_statusFilter != 'All') {
      filtered = filtered.where((m) => m.rawData['status'] == _statusFilter).toList();
    }

    return filtered;
  }

  /// Groups overlapping pins into clover-shaped clusters when zoomed out,
  /// designating a leader pin to render the clover and translating member pins to converge.
  List<_IssueMarker> _getAdjustedMarkers() {
    final original = _filteredIssues;
    if (original.isEmpty) return [];

    final List<_IssueMarker> adjusted = [];
    final int n = original.length;
    final List<bool> grouped = List.filled(n, false);

    // Calculate scale factor using degrees-to-pixel approximation at current zoom:
    // scale = 0.71 * 2^Z
    final double scale = 0.71 * math.pow(2.0, _mapZoom);
    
    // Clustering is enabled when zoom is less than 16.0
    final bool enableClustering = _mapZoom < 16.0;
    const double thresholdPixels = 50.0; // Overlap grouping threshold in screen pixels

    for (int i = 0; i < n; i++) {
      if (grouped[i]) continue;

      final List<int> groupIndices = [i];
      grouped[i] = true;
      final LatLng pStart = original[i].position;

      if (enableClustering) {
        for (int j = i + 1; j < n; j++) {
          if (grouped[j]) continue;
          final LatLng pCheck = original[j].position;

          // Calculate approximate distance in pixels
          final double dx = (pCheck.longitude - pStart.longitude) * scale;
          final double dy = (pCheck.latitude - pStart.latitude) * scale;
          final double dist = math.sqrt(dx * dx + dy * dy);

          if (dist < thresholdPixels) {
            groupIndices.add(j);
            grouped[j] = true;
          }
        }
      }

      final int groupSize = groupIndices.length;
      if (groupSize == 1) {
        // Keep original pin location with zero translation offset
        final originalMarker = original[i];
        adjusted.add(_IssueMarker(
          id: originalMarker.id,
          label: originalMarker.label,
          position: originalMarker.position,
          priority: originalMarker.priority,
          color: originalMarker.color,
          rawData: originalMarker.rawData,
          translationOffset: Offset.zero,
          isClusterLeader: false,
          isClusterMember: false,
          clusterSize: 1,
        ));
      } else {
        // Find center coordinate of the overlapping group
        double sumLat = 0.0;
        double sumLng = 0.0;
        for (int idx in groupIndices) {
          sumLat += original[idx].position.latitude;
          sumLng += original[idx].position.longitude;
        }
        final double centerLat = sumLat / groupSize;
        final double centerLng = sumLng / groupSize;
        final LatLng centerLatLng = LatLng(centerLat, centerLng);

        // Find leader index (prioritize High > Medium > others)
        int leaderIdx = groupIndices[0];
        for (int idx in groupIndices) {
          final priority = original[idx].priority;
          final currentPriority = original[leaderIdx].priority;
          if (priority == 'High' && currentPriority != 'High') {
            leaderIdx = idx;
          } else if (priority == 'Medium' && currentPriority != 'High' && currentPriority != 'Medium') {
            leaderIdx = idx;
          }
        }

        for (int idx in groupIndices) {
          final isLeader = (idx == leaderIdx);
          final originalMarker = original[idx];
          
          // Calculate screen pixel translation from the original true location to the group center:
          final double transX = (centerLng - originalMarker.position.longitude) * scale;
          final double transY = (originalMarker.position.latitude - centerLat) * scale;

          adjusted.add(_IssueMarker(
            id: originalMarker.id,
            label: originalMarker.label,
            position: originalMarker.position, // Maintain original position for map placement
            priority: originalMarker.priority,
            color: originalMarker.color,
            rawData: originalMarker.rawData,
            translationOffset: Offset(transX, transY),
            isClusterLeader: isLeader,
            isClusterMember: !isLeader,
            clusterSize: groupSize,
            clusterCenter: centerLatLng,
          ));
        }
      }
    }

    return adjusted;
  }

  /// Map report categories to specific intuitive symbols/icons
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

  /// Builds a single high-contrast capsule pin marker representation styled like the navbar (dark frosted glass + indigo outline).
  Widget _buildSinglePin(_IssueMarker issue) {
    final status = (issue.rawData['status'] ?? 'Pending').toString();
    final int upvotes = issue.rawData['upvotes'] is int
        ? issue.rawData['upvotes']
        : (int.tryParse(issue.rawData['upvotes']?.toString() ?? '0') ?? 0);
    
    Color statusColor;
    bool shouldPulse = false;

    if (status == 'Pending') {
      statusColor = const Color(0xFFEF4444); // Alert red
      shouldPulse = true;
    } else if (status == 'In Maintenance' || status == 'In Process' || status == 'In Patching') {
      statusColor = const Color(0xFF3B82F6); // Maintenance blue
    } else if (status == 'In Review') {
      statusColor = const Color(0xFFF59E0B); // Attention amber
    } else {
      statusColor = const Color(0xFF10B981); // Resolved emerald
    }

    final double sizeMultiplier = 1.0 + math.min(upvotes * 0.15, 0.60);
    final double baseWidth = 24.0 * sizeMultiplier;
    final double baseHeight = 24.0 * sizeMultiplier;
    
    final Color glowColor = upvotes >= 5
        ? const Color(0xFFF59E0B) // Amber gold for high votes
        : upvotes >= 2
            ? const Color(0xFFEC4899) // Hot pink for trending votes
            : const Color(0xFFA5B4FC); // Standard Indigo

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final double pulseVal = _pulseController.value;
        final double statusOpacity = shouldPulse 
            ? 0.3 + 0.7 * math.sin(pulseVal * math.pi)
            : 1.0;

        final double floatVal = math.sin(pulseVal * math.pi);
        final double translationY = -3.0 * floatVal;
        final double shadowOpacity = (0.4 - 0.25 * floatVal) * sizeMultiplier;
        final double shadowScale = (1.0 - 0.3 * floatVal) * sizeMultiplier;

        return SizedBox(
          key: ValueKey('pin_${issue.id}'),
          width: 42 * sizeMultiplier,
          height: 58 * sizeMultiplier,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              // 1. Shadow Dot (ground level)
              Positioned(
                bottom: 4,
                child: Transform.scale(
                  scale: shadowScale,
                  child: Opacity(
                    opacity: math.min(shadowOpacity, 1.0),
                    child: Container(
                      width: 14,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: const BorderRadius.all(Radius.elliptical(7, 2)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.6),
                            blurRadius: 3 * sizeMultiplier,
                            spreadRadius: 1 * sizeMultiplier,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // 2. Teardrop Pin (floating)
              Positioned(
                top: 4,
                child: Transform.translate(
                  offset: Offset(0, translationY),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // The Teardrop container
                      Transform.rotate(
                        angle: math.pi / 4,
                        child: Container(
                          width: baseWidth,
                          height: baseHeight,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.85),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                              bottomLeft: Radius.circular(12),
                              bottomRight: Radius.zero,
                            ),
                            border: Border.all(
                              color: glowColor,
                              width: 1.5 + (upvotes * 0.4).clamp(0.0, 2.5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: glowColor.withOpacity(0.35 + (upvotes * 0.05).clamp(0.0, 0.4)),
                                blurRadius: 5 + upvotes * 3.0,
                                spreadRadius: 0.5 + upvotes * 0.5,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Category Icon (rotated back)
                      Positioned.fill(
                        child: Center(
                          child: Transform.rotate(
                            angle: -math.pi / 4,
                            child: Icon(
                              _getCategoryIcon(issue.label),
                              color: Colors.white,
                              size: 13 * sizeMultiplier,
                            ),
                          ),
                        ),
                      ),
                      // 3. Status Alert Dot
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          width: 8 * sizeMultiplier,
                          height: 8 * sizeMultiplier,
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(statusOpacity),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black, width: 1.0),
                            boxShadow: [
                              BoxShadow(
                                color: statusColor.withOpacity(0.5),
                                blurRadius: 3,
                                spreadRadius: 0.5,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 4. Upvotes Count Pill Badge (displayed on bottom right of the pin if upvotes > 0)
                      if (upvotes > 0)
                        Positioned(
                          bottom: -4,
                          right: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: glowColor,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.black, width: 1.0),
                              boxShadow: [
                                BoxShadow(
                                  color: glowColor.withOpacity(0.4),
                                  blurRadius: 3,
                                  spreadRadius: 0.5,
                                ),
                              ],
                            ),
                            child: Text(
                              "+$upvotes",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
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
      },
    );
  }

  /// Builds a unified clover/cloud cluster representation consisting of
  /// three overlapping circles styled like the navbar with count badge.
  Widget _buildCloverCluster(_IssueMarker issue) {
    return SizedBox(
      key: ValueKey('clover_${issue.id}'),
      width: 56,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. Top circle
          Positioned(
            left: 16,
            top: 4,
            child: _buildClusterCircle(issue),
          ),
          // 2. Bottom-left circle
          Positioned(
            left: 6,
            top: 18,
            child: _buildClusterCircle(issue),
          ),
          // 3. Bottom-right circle
          Positioned(
            left: 26,
            top: 18,
            child: _buildClusterCircle(issue),
          ),
          // 4. Red badge on top right
          Positioned(
            right: 4,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 1.5),
                  ),
                ],
              ),
              constraints: const BoxConstraints(
                minWidth: 18,
                minHeight: 18,
              ),
              child: Center(
                child: Text(
                  '${issue.clusterSize}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClusterCircle(_IssueMarker issue) {
    return Stack(
      children: [
        Transform.rotate(
          angle: math.pi / 4,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85), // Dark glassmorphic core matching single pins
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.zero, // Pointy tip pointing bottom-right (down when rotated)
              ),
              border: Border.all(color: const Color(0xFFA5B4FC), width: 1.5), // Glowing indigo border
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFA5B4FC).withOpacity(0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 1.0),
                ),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Transform.rotate(
              angle: -math.pi / 4, // Counter-rotate icon back upright
              child: Icon(
                _getCategoryIcon(issue.label),
                color: Colors.white,
                size: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  int _getStatusStep(String status) {
    switch (status) {
      case 'Pending':
        return 0;
      case 'In Review':
        return 1;
      case 'In Process':
        return 2;
      case 'In Maintenance':
        return 3;
      case 'Resolved':
        return 4;
      default:
        return 0;
    }
  }

  Widget _buildHorizontalProgress(String status) {
    final currentStep = _getStatusStep(status);
    final steps = ['Submitted', 'Reviewed', 'Assigned', 'Maintenance', 'Resolved'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REPORT PROGRESS',
            style: TextStyle(
              color: Color(0xFFCBD5E1),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(5, (index) {
              final bool isDone = index <= currentStep;
              final bool isActive = index == currentStep && status != 'Resolved';
              
              Color stepColor;
              if (isActive) {
                stepColor = const Color(0xFFA5B4FC); // Glowing navbar indigo
              } else if (isDone) {
                stepColor = const Color(0xFF10B981); // Emerald green for completed
              } else {
                stepColor = Colors.white.withOpacity(0.2); // Grey for future
              }

              return Expanded(
                child: Row(
                  children: [
                    // Node
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: isActive ? Colors.transparent : stepColor,
                        shape: BoxShape.circle,
                        border: isActive 
                            ? Border.all(color: stepColor, width: 3.5)
                            : Border.all(color: Colors.white.withOpacity(0.15), width: 1.0),
                        boxShadow: [
                          if (isDone)
                            BoxShadow(
                              color: stepColor.withOpacity(0.3),
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                      child: isActive 
                          ? null 
                          : (isDone 
                              ? const Center(
                                  child: Icon(Icons.check_rounded, color: Colors.white, size: 8),
                                )
                              : null),
                    ),
                    // Connector line
                    if (index < 4)
                      Expanded(
                        child: Container(
                          height: 2,
                          color: (index < currentStep) 
                              ? const Color(0xFF10B981) 
                              : Colors.white.withOpacity(0.12),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          // Labels row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(5, (index) {
              final bool isActive = index == currentStep && status != 'Resolved';
              final bool isDone = index <= currentStep;
              
              return Expanded(
                child: Text(
                  steps[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                     fontSize: 9.5,
                     fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                     color: isActive 
                         ? const Color(0xFF818CF8) 
                         : (isDone ? Colors.white.withOpacity(0.85) : Colors.white.withOpacity(0.4)),
                  ),
                ),
               );
             }),
           ),
        ],
      ),
    );
  }

  Future<void> _goToMyLocation() async {
    if (_currentPosition == null) {
      await _requestLocationAndLoad();
      return;
    }
    final latLng = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    _mapController.move(latLng, 15.5);
    _reverseGeocode(latLng.latitude, latLng.longitude);
  }

  Future<void> _reverseGeocode(double lat, double lon) async {
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
            if (shortAddress.length < 18 && parts.length > 2) {
              shortAddress += ", ${parts[2].trim()}";
            }
          } else {
            shortAddress = address.toString();
          }
          setState(() {
            _currentAddressName = shortAddress;
          });
        }
      }
    } catch (e) {
      debugPrint("Error in reverse geocoding: $e");
      if (mounted) {
        setState(() {
          _currentAddressName = "${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}";
        });
      }
    }
  }

  // ── Before/After Marker Details Bottom Sheet ──────────────────────────
  void _showMarkerDetails(_IssueMarker marker) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final data = marker.rawData;
        final isResolved = data['status'] == 'Resolved';
        final int upvotes = data['upvotes'] is int
            ? data['upvotes']
            : (int.tryParse(data['upvotes']?.toString() ?? '0') ?? 0);
        final hasBeforeImage = data['image_path'] != null;
        final hasAfterImage = data['completion_image_path'] != null;
        final hasBeforeAfter = isResolved && hasBeforeImage && hasAfterImage;

        String? beforeImageUrl;
        if (hasBeforeImage) {
          beforeImageUrl = '${ApiService.baseUrl}${data['image_path']}';
        }
        String? afterImageUrl;
        if (hasAfterImage) {
          afterImageUrl = '${ApiService.baseUrl}${data['completion_image_path']}';
        }

        // Local state for before/after toggle (captured by StatefulBuilder closure)
        bool showAfter = true;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            // Determine current display image
            String? displayImage;
            if (hasBeforeAfter) {
              displayImage = showAfter ? afterImageUrl : beforeImageUrl;
            } else if (isResolved && hasAfterImage) {
              displayImage = afterImageUrl;
            } else if (hasBeforeImage) {
              displayImage = beforeImageUrl;
            }

            // Status tag mapping
            Color statusTextCol;
            Color statusBgCol;
            if (isResolved) {
              statusTextCol = const Color(0xFF34D399); // Emerald
              statusBgCol = const Color(0xFF34D399).withOpacity(0.15);
            } else if (data['status'] == 'Pending') {
              statusTextCol = const Color(0xFFFBBF24); // Amber
              statusBgCol = const Color(0xFFFBBF24).withOpacity(0.15);
            } else {
              statusTextCol = const Color(0xFF60A5FA); // Blue
              statusBgCol = const Color(0xFF60A5FA).withOpacity(0.15);
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65), // dark glassmorphic overlay
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.12),
                      width: 1.2,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Pull handler for sheet
                      Center(
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          width: 36,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // ── Header ──
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: marker.color.withOpacity(0.15),
                            child: Icon(Icons.location_on, color: marker.color, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  marker.label,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    CircleAvatar(radius: 4, backgroundColor: marker.color),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${marker.priority} Priority',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white.withOpacity(0.6),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: statusBgCol,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: statusTextCol.withOpacity(0.3), width: 1.0),
                                ),
                                child: Text(
                                  data['status'] ?? 'Pending',
                                  style: TextStyle(
                                    color: statusTextCol,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              if (upvotes > 0) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEC4899).withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: const Color(0xFFEC4899).withOpacity(0.3), width: 1.0),
                                  ),
                                  child: Text(
                                    '▲ $upvotes',
                                    style: const TextStyle(
                                      color: Color(0xFFEC4899),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Image with Before/After toggle & RESOLVED badge ──
                      if (displayImage != null)
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.network(
                                displayImage,
                                height: 200,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (ctx, err, stack) => Container(
                                  height: 200,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.06),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                                  ),
                                  child: Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      size: 48,
                                      color: Colors.white.withOpacity(0.4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // RESOLVED badge overlay
                            if (isResolved)
                              Positioned(
                                top: 10,
                                left: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF059669),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 6,
                                      )
                                    ],
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.verified_rounded, color: Colors.white, size: 13),
                                      SizedBox(width: 4),
                                      Text(
                                        'RESOLVED',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            // Before / After toggle tabs
                            if (hasBeforeAfter)
                              Positioned(
                                bottom: 10,
                                right: 10,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.75),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        onTap: () => setSheetState(() => showAfter = false),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: !showAfter ? Colors.white.withOpacity(0.2) : Colors.transparent,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'Before',
                                            style: TextStyle(
                                              color: !showAfter ? Colors.white : Colors.white70,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => setSheetState(() => showAfter = true),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: showAfter ? const Color(0xFF6366F1) : Colors.transparent,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'After',
                                            style: TextStyle(
                                              color: showAfter ? Colors.white : Colors.white70,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
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
                      if (displayImage != null) const SizedBox(height: 16),

                      // ── AI Prediction ──
                      if (data['ai_prediction'] != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6366F1).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF6366F1).withOpacity(0.3), width: 1.0),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.auto_awesome, color: Color(0xFF818CF8), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "AI Prediction Match: ${data['ai_prediction']} (${data['confidence'] ?? ''})",
                                  style: const TextStyle(
                                    color: Color(0xFF818CF8),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // ── Resolved info card ──
                      if (isResolved && data['resolved_at'] != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF059669).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF059669).withOpacity(0.3), width: 1.0),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.verified_user_rounded, color: Color(0xFF34D399), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Resolved on ${data['resolved_at']}',
                                  style: const TextStyle(
                                    color: Color(0xFF34D399),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // ── Progress Bar ──
                      _buildHorizontalProgress(data['status'] ?? 'Pending'),

                      // ── Address & Date ──
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.08)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.map_outlined, size: 16, color: Colors.white.withOpacity(0.5)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data['address'] ?? 'Unknown location',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.8),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.access_time_rounded, size: 16, color: Colors.white.withOpacity(0.5)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data['timestamp'] ?? 'Unknown time',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.8),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReportDetailScreen(report: data),
                              ),
                            ).then((_) => _fetchMapReports());
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'View Full Details',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final bottomOffset = safeBottom > 0 ? safeBottom + 80.0 : 100.0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 1. OPENSTREETMAP
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: _mapZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onPositionChanged: (camera, hasGesture) {
                if (camera.zoom != _mapZoom) {
                  setState(() {
                    _mapZoom = camera.zoom;
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _mapStyle == 'Dark Mode'
                    ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
                    : (_mapStyle == 'Muted Light'
                        ? 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png'
                        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
                subdomains: _mapStyle == 'Standard' ? const [] : const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.smartcity',
                maxZoom: 19,
              ),

              // ── User location dot — always visible ──
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF818CF8), // indigo glow
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF818CF8).withOpacity(0.6),
                              blurRadius: 10,
                              spreadRadius: 3,
                            )
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

              // ── Issue visualisation: Heatmap OR Markers ──
              if (_showHeatmap)
                HeatMapLayer(
                  heatMapDataSource: InMemoryHeatMapDataSource(
                    data: _filteredIssues
                        .map((e) => WeightedLatLng(e.position, 1.0))
                        .toList(),
                  ),
                  heatMapOptions: HeatMapOptions(
                    gradient: {
                      0.25: Colors.blue,
                      0.55: Colors.green,
                      0.85: Colors.yellow,
                      1.0: Colors.red,
                    },
                    minOpacity: 0.1,
                    radius: 30,
                  ),
                )
              else
                MarkerLayer(
                  markers: _getAdjustedMarkers().map((issue) {
                    final double correctionY = issue.isClusterLeader ? 0.0 : -18.0;
                    return Marker(
                      key: ValueKey('marker_${issue.id}'),
                      point: issue.position, // True geographical coordinates
                      width: 120, // Expanded boundaries to allow translation without clipping
                      height: 130,
                      alignment: Alignment.center,
                      child: AnimatedContainer(
                        key: ValueKey('container_${issue.id}'),
                        duration: const Duration(milliseconds: 700), // Slower, cinematic flight transition (700ms)
                        curve: Curves.easeInOutCubic, // Silky smooth acceleration/deceleration curve
                        transform: Matrix4.translationValues(
                          issue.translationOffset.dx,
                          issue.translationOffset.dy + correctionY,
                          0.0,
                        ),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 600), // Slower fade transition (600ms)
                          curve: Curves.easeInOut,
                          opacity: issue.isClusterMember ? 0.0 : 1.0,
                          child: IgnorePointer(
                            ignoring: issue.isClusterMember,
                            child: Center(
                              child: GestureDetector(
                                onTap: () {
                                  if (issue.isClusterLeader) {
                                    final double targetZoom = _mapZoom + 1.5;
                                    _mapController.move(
                                      issue.clusterCenter ?? issue.position,
                                      targetZoom,
                                    );
                                  } else {
                                    _showMarkerDetails(issue);
                                  }
                                },
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 550), // Slower child cross-fade transition (550ms)
                                  child: issue.isClusterLeader
                                      ? _buildCloverCluster(issue)
                                      : _buildSinglePin(issue),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),

          // 2. LOADING OVERLAY
          if (_locationLoading)
            Container(
              color: Colors.black.withOpacity(0.75),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF818CF8)),
                    SizedBox(height: 16),
                    Text(
                      'Getting your location…',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 3. ERROR OVERLAY
          if (_locationError != null)
            Container(
              color: Colors.black.withOpacity(0.85),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_off_outlined, size: 64, color: Color(0xFFEF4444)),
                      const SizedBox(height: 16),
                      Text(
                        _locationError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.white.withOpacity(0.9),
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF6366F1).withOpacity(0.3),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _requestLocationAndLoad,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text(
                            'Try Again',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            // 4. FLOATING SEARCH BAR
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 0,
              right: 0,
              child: _buildSearchBar(),
            ),

            // 5. FLOATING LOCATE BUTTON
            Positioned(
              bottom: _showLegend ? bottomOffset + 115 : bottomOffset, // Dynamically positioned to avoid legend overlap
              right: 20,
              child: SizedBox(
                width: 40,
                height: 40,
                child: GlassCard(
                  color: Colors.black.withOpacity(0.88), // High contrast dark frosted glass for locate button
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(20),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _goToMyLocation,
                    icon: const Icon(Icons.my_location_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),

            // 6. PRIORITY LEGEND OR COLLAPSED LEGEND TOGGLE
            Positioned(
              bottom: bottomOffset, // Positioned above bottom navigation bar to prevent overflow
              left: 20,
              right: _showLegend ? 20 : null,
              child: _showLegend ? _buildPriorityLegend() : _buildCollapsedLegendButton(),
            ),
        ],
      ),
    );
  }
               // ══════════════════════════════════════════════════════════════════════
  //  WIDGETS
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildSearchBar() {
    final hasActiveFilter = _selectedCategory != 0 || _statusFilter != 'All' || _showHeatmap || _showResolvedOnly;
    return GlassCard(
      color: Colors.black.withOpacity(0.88), // Higher contrast dark frosted glass for search bar
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          const Icon(Icons.location_on_rounded, color: Color(0xFFA5B4FC), size: 22), // Lighter indigo for contrast
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _currentPosition != null ? _currentAddressName : 'Smart City Map Monitor',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: Colors.white.withOpacity(0.25), // Higher contrast divider
            margin: const EdgeInsets.symmetric(horizontal: 8),
          ),
          InkWell(
            onTap: _showFiltersBottomSheet,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.tune_rounded,
                    color: hasActiveFilter ? const Color(0xFFA5B4FC) : Colors.white.withOpacity(0.9), // Brighter filter icon
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _selectedCategory != 0
                        ? _categories[_selectedCategory]
                        : (_statusFilter != 'All' ? _statusFilter : 'Filters'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: hasActiveFilter ? const Color(0xFFA5B4FC) : Colors.white.withOpacity(0.9), // Brighter text
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

  void _showFiltersBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.88), // High contrast backdrop for sheet
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.15), // Slightly brighter border
                      width: 1.2,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Pull handler
                      Center(
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Map Filters',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, color: Colors.white), // Brighter close button
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Categories Section ──
                      const Text(
                        'CATEGORY',
                        style: TextStyle(
                          color: Color(0xFFCBD5E1), // Slate-300 for maximum readability
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List.generate(_categories.length, (index) {
                          final isSelected = index == _selectedCategory;
                          return GestureDetector(
                            onTap: () {
                              setSheetState(() => _selectedCategory = index);
                              setState(() => _selectedCategory = index);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFF818CF8).withOpacity(0.3)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFFA5B4FC) // Lighter indigo border
                                      : Colors.white.withOpacity(0.18), // High contrast unselected border
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                _categories[index],
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white.withOpacity(0.85), // Brighter unselected text
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 24),

                      // ── Status Section ──
                      const Text(
                        'REPORT STATUS',
                        style: TextStyle(
                          color: Color(0xFFCBD5E1), // Slate-300
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white.withOpacity(0.15)), // High contrast border
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _statusFilter,
                            dropdownColor: const Color(0xFF0F172A), // Slate-900 dropdown background
                            icon: const Icon(Icons.arrow_drop_down_rounded, color: Colors.white),
                            isExpanded: true,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            items: _statusOptions.map((s) {
                              return DropdownMenuItem(
                                value: s,
                                child: Text(s),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setSheetState(() => _statusFilter = val);
                                setState(() => _statusFilter = val);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Map Style Section ──
                      const Text(
                        'MAP STYLE',
                        style: TextStyle(
                          color: Color(0xFFCBD5E1), // Slate-300
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ['Muted Light', 'Dark Mode', 'Standard'].map((style) {
                          final isSelected = style == _mapStyle;
                          return GestureDetector(
                            onTap: () {
                              setSheetState(() => _mapStyle = style);
                              setState(() => _mapStyle = style);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? const Color(0xFF818CF8).withOpacity(0.3)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFFA5B4FC) // Lighter indigo border
                                      : Colors.white.withOpacity(0.18), // High contrast border
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                style,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white.withOpacity(0.85), // Brighter unselected text
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),

                      // ── Toggles ──
                      const Text(
                        'VISUAL OPTIONS',
                        style: TextStyle(
                          color: Color(0xFFCBD5E1), // Slate-300
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Heatmap switch
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Show Heatmap',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        subtitle: const Text(
                          'Highlight issue density hotspots',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                        activeColor: const Color(0xFFA5B4FC), // Lighter indigo switch
                        value: _showHeatmap,
                        onChanged: (val) {
                          setSheetState(() => _showHeatmap = val);
                          setState(() => _showHeatmap = val);
                        },
                      ),
                      const Divider(color: Colors.white10),
                      // Resolved only switch
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Resolved Only',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        subtitle: const Text(
                          'Show only completed maintenance tasks',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                        activeColor: const Color(0xFF34D399), // Emerald switch
                        value: _showResolvedOnly,
                        onChanged: (val) {
                          setSheetState(() => _showResolvedOnly = val);
                          setState(() => _showResolvedOnly = val);
                        },
                      ),
                      const SizedBox(height: 24),

                      // ── Actions ──
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(color: Colors.white.withOpacity(0.35)), // Brighter border
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: () {
                                setSheetState(() {
                                  _selectedCategory = 0;
                                  _statusFilter = 'All';
                                  _showHeatmap = false;
                                  _showResolvedOnly = false;
                                  _mapStyle = 'Muted Light';
                                });
                                setState(() {
                                  _selectedCategory = 0;
                                  _statusFilter = 'All';
                                  _showHeatmap = false;
                                  _showResolvedOnly = false;
                                  _mapStyle = 'Muted Light';
                                });
                              },
                              child: const Text('Reset', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }


  Widget _buildPriorityLegend() {
    final count = _filteredIssues.length;
    return GlassCard(
      color: Colors.black.withOpacity(0.88), // High contrast dark frosted glass for legend
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'MAP LEGEND',
                style: TextStyle(
                  color: Color(0xFFCBD5E1), // Slate-300 for readability
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              Row(
                children: [
                  Text(
                    '$count ${count == 1 ? 'issue' : 'issues'} shown',
                    style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _showLegend = false),
                    child: Icon(
                      Icons.close_rounded,
                      color: Colors.white.withOpacity(0.85), // Higher contrast close icon
                      size: 16,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Row 1: Base pin indicator matching the new capsule/navbar theme
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: Center(
                  child: Transform.rotate(
                    angle: math.pi / 4,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.8),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4.5),
                          topRight: Radius.circular(4.5),
                          bottomLeft: Radius.circular(4.5),
                          bottomRight: Radius.zero,
                        ),
                        border: Border.all(color: const Color(0xFFA5B4FC), width: 1.0),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Citizen Report Marker',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: Status dots part 1
          Row(
            children: [
              Expanded(child: _legendItem(const Color(0xFFEF4444), 'Pending Alert')),
              Expanded(child: _legendItem(const Color(0xFFF59E0B), 'In Review')),
            ],
          ),
          const SizedBox(height: 8),
          // Row 3: Status dots part 2
          Row(
            children: [
              Expanded(child: _legendItem(const Color(0xFF3B82F6), 'In Maintenance')),
              Expanded(child: _legendItem(const Color(0xFF10B981), 'Resolved')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedLegendButton() {
    return SizedBox(
      height: 40,
      child: GlassCard(
        color: Colors.black.withOpacity(0.88), // High contrast dark frosted glass for collapsed pill
        padding: const EdgeInsets.symmetric(horizontal: 14),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: () => setState(() => _showLegend = true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline_rounded, color: Color(0xFFA5B4FC), size: 18), // Lighter indigo for maximum contrast
              const SizedBox(width: 8),
              Text(
                'Show Legend',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.4),
                blurRadius: 4,
                spreadRadius: 1,
              )
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _IssueMarker {
  final String id;
  final String label;
  final LatLng position;
  final String priority;
  final Color color;
  final Map<String, dynamic> rawData;
  final Offset translationOffset; // Offset for implicit translation animations
  final bool isClusterLeader;
  final bool isClusterMember;
  final int clusterSize;
  final LatLng? clusterCenter;

  const _IssueMarker({
    required this.id,
    required this.label,
    required this.position,
    required this.priority,
    required this.color,
    required this.rawData,
    this.translationOffset = Offset.zero,
    this.isClusterLeader = false,
    this.isClusterMember = false,
    this.clusterSize = 1,
    this.clusterCenter,
  });
}