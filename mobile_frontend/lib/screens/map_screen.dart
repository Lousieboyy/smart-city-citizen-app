import 'dart:async';
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
import '../services/notification_service.dart';

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
  String _mapStyle = 'Standard';
  Brightness? _lastBrightness;

  // ── Category filter ───────────────────────────────────────────────────
  final List<String> _categories = ["All", "Road", "Lighting", "Waste", "Drainage"];
  int _selectedCategory = 0;

  // ── Issue data ────────────────────────────────────────────────────────
  List<_IssueMarker> _issues = [];
  bool _showHeatmap = false;

  // ── Cache for optimized map markers ──────────────────────────────────
  List<_IssueMarker> _cachedMarkers = [];
  double _lastCachedZoom = 0.0;
  int _lastCachedIssuesCount = 0;
  int _lastSelectedCategory = 0;
  bool _lastShowResolvedOnly = false;
  String _lastStatusFilter = 'All';

  // ── Resolved & Status filter ──────────────────────────────────────────
  bool _showResolvedOnly = false;
  String _statusFilter = 'All';
  final List<String> _statusOptions = [
    'All', 'Pending', 'In Review', 'In Process', 'In Maintenance', 'Resolved',
  ];

  // ── Proximity Alert state ──────────────────────────────────────────────
  StreamSubscription<Position>? _positionStreamSub;
  final Set<String> _alertedReportIds = {};
  _IssueMarker? _activeProximityAlertIssue;
  double? _activeProximityDistance;
  Timer? _proximityDismissTimer;

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
    _positionStreamSub?.cancel();
    _proximityDismissTimer?.cancel();
    _mapController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _requestLocationAndLoad() async {
    if (!mounted) return;
    setState(() {
      _locationLoading = true;
      _locationError = null;
    });

    try {
      bool useRealGPS = false;
      LocationPermission permission = LocationPermission.denied;

      try {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (serviceEnabled) {
          permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
            useRealGPS = true;
          }
        }
      } catch (e) {
        debugPrint("Geolocator check failed, falling back to mock: $e");
      }

      Position position;
      if (useRealGPS) {
        try {
          // Attempt instant load from cache
          final lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            position = lastKnown;
          } else {
            position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
              timeLimit: const Duration(seconds: 3),
            );
          }
        } catch (e) {
          debugPrint("High accuracy GPS timed out, trying low accuracy: $e");
          try {
            position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.low,
              timeLimit: const Duration(seconds: 2),
            );
          } catch (_) {
            // Final fallback to Melaka Center
            position = Position(
              latitude: 2.1896,
              longitude: 102.2501,
              timestamp: DateTime.now(),
              accuracy: 0.0,
              altitude: 0.0,
              heading: 0.0,
              speed: 0.0,
              speedAccuracy: 0.0,
              altitudeAccuracy: 0.0,
              headingAccuracy: 0.0,
            );
          }
        }
      } else {
        // Fallback to default Melaka center (2.1896, 102.2501)
        position = Position(
          latitude: 2.1896,
          longitude: 102.2501,
          timestamp: DateTime.now(),
          accuracy: 0.0,
          altitude: 0.0,
          heading: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );
      }

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

      // Run initial check for proximity
      _checkProximityAlerts(position);

      if (useRealGPS) {
        // Setup real-time position stream subscription
        _positionStreamSub?.cancel();
        _positionStreamSub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5, // Check updates every 5 meters
          ),
        ).listen(
          (Position pos) {
            if (!mounted) return;
            setState(() {
              _currentPosition = pos;
            });
            _checkProximityAlerts(pos);
          },
          onError: (err) {
            debugPrint("GPS Stream error: $err");
          },
        );
      }

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

  void _checkProximityAlerts(Position position) {
    if (_issues.isEmpty) return;

    // Filter to candidate unresolved issues that have not been alerted yet
    final candidates = _issues.where((issue) {
      final status = issue.rawData['status'] ?? 'Pending';
      final isResolved = status == 'Resolved';
      final alreadyAlerted = _alertedReportIds.contains(issue.id);
      return !isResolved && !alreadyAlerted;
    }).toList();

    if (candidates.isEmpty) return;

    // Calculate distances
    final List<MapEntry<_IssueMarker, double>> distanceList = [];
    for (var issue in candidates) {
      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        issue.position.latitude,
        issue.position.longitude,
      );
      distanceList.add(MapEntry(issue, distance));
    }

    // Sort by distance ascending
    distanceList.sort((a, b) => a.value.compareTo(b.value));

    // Get closest one
    final closest = distanceList.first;
    if (closest.value <= 50.0) {
      final issue = closest.key;
      final distance = closest.value;

      _alertedReportIds.add(issue.id);
      
      setState(() {
        _activeProximityAlertIssue = issue;
        _activeProximityDistance = distance;
      });

      // Fire local system notification (rings & buzzes the phone)
      NotificationService.instance.fireProximityAlert(
        reportId: int.tryParse(issue.id) ?? 0,
        title: "PROXIMITY ALERT",
        body: "You are ${distance.toStringAsFixed(0)}m away from an active '${issue.label}' issue.",
      );

      // Auto-dismiss after 8 seconds
      _proximityDismissTimer?.cancel();
      _proximityDismissTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) {
          setState(() {
            _activeProximityAlertIssue = null;
            _activeProximityDistance = null;
          });
        }
      });
    }
  }

  Widget _buildProximityAlertBanner(bool isDark) {
    final issue = _activeProximityAlertIssue;
    final dist = _activeProximityDistance;
    if (issue == null) return const SizedBox.shrink();

    final cat = issue.label;
    final distanceText = dist != null ? '${dist.toStringAsFixed(0)}m' : 'nearby';

    return GlassCard(
      color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.9) : Colors.white.withOpacity(0.95),
      borderColor: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
      borderWidth: 1.5,
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Glowing Warning Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.25), width: 1),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFEF4444),
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          // Issue Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'PROXIMITY ALERT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : const Color(0xFFD6D3D1),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      distanceText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '$cat Detected',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF1C1917),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (issue.rawData['description'] != null && issue.rawData['description'].toString().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    issue.rawData['description'],
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Action Buttons: View Details & Dismiss
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444).withOpacity(0.1),
                  foregroundColor: const Color(0xFFEF4444),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: const Color(0xFFEF4444).withOpacity(0.25)),
                  ),
                ),
                onPressed: () {
                  setState(() {
                    _activeProximityAlertIssue = null;
                    _activeProximityDistance = null;
                  });
                  _proximityDismissTimer?.cancel();
                  // Move map to the issue position and zoom in
                  _mapController.move(issue.position, 17.0);
                  // Open issue details sheet
                  _showMarkerDetails(issue);
                },
                child: const Text(
                  'View',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _activeProximityAlertIssue = null;
                    _activeProximityDistance = null;
                  });
                  _proximityDismissTimer?.cancel();
                },
                icon: Icon(
                  Icons.close_rounded,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                  size: 20,
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
              mapColor = const Color(0xFF10B981); // Emerald green for resolved
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

  List<_IssueMarker> _getAdjustedMarkers() {
    final original = _filteredIssues;
    if (original.isEmpty) return [];

    final bool zoomChanged = (_mapZoom - _lastCachedZoom).abs() > 0.15;
    final bool dataChanged = original.length != _lastCachedIssuesCount ||
        _selectedCategory != _lastSelectedCategory ||
        _showResolvedOnly != _lastShowResolvedOnly ||
        _statusFilter != _lastStatusFilter;

    if (_cachedMarkers.isNotEmpty && !zoomChanged && !dataChanged) {
      return _cachedMarkers;
    }

    final List<_IssueMarker> adjusted = [];
    final int n = original.length;
    final List<bool> grouped = List.filled(n, false);

    // Calculate scale factor using degrees-to-pixel approximation at current zoom:
    // scale = 0.71 * math.pow(2.0, Z)
    final double scale = 0.71 * math.pow(2.0, _mapZoom);
    
    // Clustering is enabled when zoom is less than 16.0
    final bool enableClustering = _mapZoom < 16.0;
    const double clusterThresholdPixels = 50.0; // Overlap grouping threshold for clover clustering
    const double spiderfyThresholdPixels = 24.0; // Overlap threshold for separating individual pins

    for (int i = 0; i < n; i++) {
      if (grouped[i]) continue;

      final List<int> groupIndices = [i];
      grouped[i] = true;
      final LatLng pStart = original[i].position;

      if (enableClustering) {
        // ── Zoom < 16: Standard clover-shaped clustering ──
        for (int j = i + 1; j < n; j++) {
          if (grouped[j]) continue;
          final LatLng pCheck = original[j].position;

          // Calculate approximate distance in pixels
          final double dx = (pCheck.longitude - pStart.longitude) * scale;
          final double dy = (pCheck.latitude - pStart.latitude) * scale;
          final double dist = math.sqrt(dx * dx + dy * dy);

          if (dist < clusterThresholdPixels) {
            groupIndices.add(j);
            grouped[j] = true;
          }
        }

        final int groupSize = groupIndices.length;
        if (groupSize == 1) {
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
      } else {
        // ── Zoom >= 16: Spiderfy / Separate Overlapping Pins in a Circle ──
        for (int j = i + 1; j < n; j++) {
          if (grouped[j]) continue;
          final LatLng pCheck = original[j].position;

          // Calculate approximate distance in pixels
          final double dx = (pCheck.longitude - pStart.longitude) * scale;
          final double dy = (pCheck.latitude - pStart.latitude) * scale;
          final double dist = math.sqrt(dx * dx + dy * dy);

          if (dist < spiderfyThresholdPixels) {
            groupIndices.add(j);
            grouped[j] = true;
          }
        }

        final int groupSize = groupIndices.length;
        if (groupSize == 1) {
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

          // Radius of the circle in screen pixels.
          // Slightly expand radius for larger groups of overlapping pins.
          final double radius = 18.0 + (groupSize * 2.0).clamp(0.0, 10.0);

          for (int k = 0; k < groupSize; k++) {
            final idx = groupIndices[k];
            final originalMarker = original[idx];
            
            // Distribute points evenly along a circle
            final double angle = k * (2.0 * math.pi / groupSize);
            
            // Target offset from center of group
            final double spiderX = radius * math.cos(angle);
            final double spiderY = radius * math.sin(angle);

            // Screen translation from original marker coordinate to its spiderfied position
            final double transX = ((centerLng - originalMarker.position.longitude) * scale) + spiderX;
            final double transY = ((originalMarker.position.latitude - centerLat) * scale) - spiderY;

            adjusted.add(_IssueMarker(
              id: originalMarker.id,
              label: originalMarker.label,
              position: originalMarker.position, // Keep original coordinate for map layout
              priority: originalMarker.priority,
              color: originalMarker.color,
              rawData: originalMarker.rawData,
              translationOffset: Offset(transX, transY),
              isClusterLeader: false,
              isClusterMember: false,
              clusterSize: 1, // Draw all of them as separate, individual pins
            ));
          }
        }
      }
    }

    _cachedMarkers = adjusted;
    _lastCachedZoom = _mapZoom;
    _lastCachedIssuesCount = original.length;
    _lastSelectedCategory = _selectedCategory;
    _lastShowResolvedOnly = _showResolvedOnly;
    _lastStatusFilter = _statusFilter;

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

  /// Returns a neon accent color based on report category for pin borders/glow in dark mode
  Color _getCategoryNeonColor(String category) {
    final cat = category.toLowerCase();
    if (cat.contains('road') || cat.contains('damage')) {
      return const Color(0xFFFF6B35); // Neon orange — road/damage
    } else if (cat.contains('light') || cat.contains('lamp')) {
      return const Color(0xFFFFE135); // Neon yellow — lighting
    } else if (cat.contains('waste') || cat.contains('trash') || cat.contains('rubbish')) {
      return const Color(0xFF39FF14); // Neon green — waste
    } else if (cat.contains('drain') || cat.contains('water')) {
      return const Color(0xFF00CFFF); // Neon cyan — drainage/water
    } else if (cat.contains('noise')) {
      return const Color(0xFFDA00FF); // Neon purple — noise
    } else {
      return const Color(0xFFFF2D78); // Neon pink — other/general
    }
  }

  /// Builds a single high-contrast capsule pin marker representation styled like the navbar.
  Widget _buildSinglePin(_IssueMarker issue, bool isDark) {
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
            : (isDark ? Colors.black : Colors.white); // Standard Neon

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
                            color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                              bottomLeft: Radius.circular(12),
                              bottomRight: Radius.zero,
                            ),
                            border: Border.all(
                              color: isDark
                                  ? _getCategoryNeonColor(issue.label)
                                  : const Color(0xFF1C1917),
                              width: 1.5 + (upvotes * 0.4).clamp(0.0, 2.5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isDark
                                    ? _getCategoryNeonColor(issue.label).withOpacity(0.55)
                                    : const Color(0xFF1C1917).withOpacity(0.2),
                                blurRadius: 8 + upvotes * 3.0,
                                spreadRadius: 1.5 + upvotes * 0.5,
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
                              color: isDark
                                  ? _getCategoryNeonColor(issue.label)
                                  : const Color(0xFF1C1917),
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
                            border: Border.all(color: isDark ? Colors.white : Colors.black, width: 1.0),
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
                      // 4. Urgent Flags Count Pill Badge (displayed on bottom right of the pin if upvotes > 0)
                      if (upvotes > 0)
                        Positioned(
                          bottom: -4,
                          right: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: glowColor,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isDark ? Colors.white : Colors.black, width: 1.0),
                              boxShadow: [
                                BoxShadow(
                                  color: glowColor.withOpacity(0.4),
                                  blurRadius: 3,
                                  spreadRadius: 0.5,
                                ),
                              ],
                            ),
                            child: Text(
                              "⚠$upvotes",
                              style: TextStyle(
                                color: (glowColor == Colors.white) ? const Color(0xFF1C1917) : Colors.white,
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
  Widget _buildCloverCluster(_IssueMarker issue, bool isDark) {
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
            child: _buildClusterCircle(issue, isDark),
          ),
          // 2. Bottom-left circle
          Positioned(
            left: 6,
            top: 18,
            child: _buildClusterCircle(issue, isDark),
          ),
          // 3. Bottom-right circle
          Positioned(
            left: 26,
            top: 18,
            child: _buildClusterCircle(issue, isDark),
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

  Widget _buildClusterCircle(_IssueMarker issue, bool isDark) {
    return Stack(
      children: [
        Transform.rotate(
          angle: math.pi / 4,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F0F0F) : Colors.white, // Light/Dark core
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
                bottomLeft: Radius.circular(12),
                bottomRight: Radius.zero, // Pointy tip pointing bottom-right (down when rotated)
              ),
              border: Border.all(color: isDark ? Colors.white : const Color(0xFF1C1917), width: 1.5), // Slate border
              boxShadow: [
                BoxShadow(
                  color: isDark ? Colors.black.withOpacity(0.4) : const Color(0xFF1C1917).withOpacity(0.2),
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
                color: isDark ? Colors.white : const Color(0xFF1C1917),
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

  Widget _buildHorizontalProgress(String status, bool isDark) {
    final currentStep = _getStatusStep(status);
    final steps = ['Submitted', 'Reviewed', 'Assigned', 'Maintenance', 'Resolved'];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REPORT PROGRESS',
            style: TextStyle(
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
              final bool isActive = index == currentStep;
              
              Color stepColor;
              if (isActive) {
                stepColor = const Color(0xFF10B981); // Emerald green — matches the bar
              } else if (isDone) {
                stepColor = const Color(0xFF10B981); // Emerald green for completed
              } else {
                stepColor = isDark ? Colors.white38 : const Color(0xFFD6D3D1); // Grey for future
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
                            : Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4), width: 1.0),
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
                              : (isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
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
              final bool isActive = index == currentStep;
              final bool isDone = index <= currentStep;
              
              return Expanded(
                child: Text(
                  steps[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                     fontSize: 9.5,
                     fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                     color: isActive 
                         ? const Color(0xFF10B981) 
                         : (isDone 
                             ? (isDark ? Colors.white : const Color(0xFF1C1917)) 
                             : (isDark ? const Color(0xFF94A3B8) : const Color(0xFFA8A29E))),
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
          final path = data['image_path'].toString();
          beforeImageUrl = '${ApiService.baseUrl}/${path.startsWith('/') ? path.substring(1) : path}';
        }
        String? afterImageUrl;
        if (hasAfterImage) {
          final path = data['completion_image_path'].toString();
          afterImageUrl = '${ApiService.baseUrl}/${path.startsWith('/') ? path.substring(1) : path}';
        }

        // Local state for before/after toggle (captured by StatefulBuilder closure)
        bool showAfter = true;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
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
            final String stat = data['status'] ?? 'Pending';
            if (stat == 'Resolved') {
              statusTextCol = isDark ? const Color(0xFF34D399) : const Color(0xFF059669);
              statusBgCol = statusTextCol.withOpacity(0.15);
            } else if (stat == 'Pending') {
              statusTextCol = const Color(0xFFEF4444); // Red
              statusBgCol = statusTextCol.withOpacity(0.15);
            } else if (stat == 'In Review') {
              statusTextCol = const Color(0xFFF59E0B); // Amber
              statusBgCol = statusTextCol.withOpacity(0.15);
            } else if (stat == 'In Maintenance' || stat == 'In Process') {
              statusTextCol = const Color(0xFF3B82F6); // Blue
              statusBgCol = statusTextCol.withOpacity(0.15);
            } else {
              statusTextCol = const Color(0xFF94A3B8); // Grey
              statusBgCol = statusTextCol.withOpacity(0.15);
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFAFAF9),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
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
                            color: isDark ? Colors.white30 : const Color(0xFFD6D3D1),
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
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                                    color: const Color(0xFFEF4444).withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3), width: 1.0),
                                  ),
                                  child: Text(
                                    '⚠ $upvotes',
                                    style: const TextStyle(
                                      color: Color(0xFFEF4444),
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
                                    color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                                  ),
                                  child: Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      size: 48,
                                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFFA8A29E),
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
                                    color: isDark ? Colors.white10 : const Color(0xFFE7E5E4),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFD6D3D1)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        onTap: () => setSheetState(() => showAfter = false),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: !showAfter ? (isDark ? Colors.white24 : Colors.white) : Colors.transparent,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'Before',
                                            style: TextStyle(
                                              color: !showAfter 
                                                  ? (isDark ? Colors.white : const Color(0xFF1C1917)) 
                                                  : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
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
                                            color: showAfter ? (isDark ? Colors.white24 : Colors.white) : Colors.transparent,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'After',
                                            style: TextStyle(
                                              color: showAfter 
                                                  ? (isDark ? Colors.white : const Color(0xFF1C1917)) 
                                                  : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
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
                            color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4), width: 1.0),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.auto_awesome, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "AI Prediction Match: ${data['ai_prediction']} (${data['confidence'] ?? ''})",
                                  style: TextStyle(
                                    color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                      _buildHorizontalProgress(data['status'] ?? 'Pending', isDark),

                      // ── Address & Date ──
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.map_outlined, size: 16, color: Color(0xFF78716C)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data['address'] ?? 'Unknown location',
                                    style: TextStyle(
                                      color: isDark ? Colors.white.withOpacity(0.9) : const Color(0xFF44403C),
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
                                const Icon(Icons.access_time_rounded, size: 16, color: Color(0xFF78716C)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data['timestamp'] ?? 'Unknown time',
                                    style: TextStyle(
                                      color: isDark ? Colors.white.withOpacity(0.9) : const Color(0xFF44403C),
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
                            ).then((_) => _fetchReports());
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                            foregroundColor: isDark ? Colors.black : Colors.white,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentBrightness = Theme.of(context).brightness;
    if (_lastBrightness != currentBrightness) {
      _lastBrightness = currentBrightness;
      _mapStyle = 'Standard';
    }

    final safeBottom = MediaQuery.of(context).padding.bottom;
    final bottomOffset = safeBottom > 0 ? safeBottom + 68.0 : 88.0;
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

              // ── Proximity Alert Radius Circle (50m) ──
              if (_currentPosition != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      radius: 50.0, // 50 meters
                      useRadiusInMeter: true,
                      color: isDark 
                          ? Colors.white.withOpacity(0.08)  // white/grey tint in dark mode
                          : const Color(0xFF0EA5E9).withOpacity(0.12), // blue tint in light mode
                      borderColor: isDark 
                          ? Colors.white.withOpacity(0.3) 
                          : const Color(0xFF0EA5E9).withOpacity(0.4),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
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
                          color: const Color(0xFF0EA5E9), // glowing blue/teal dot
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2), // white outline
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0EA5E9).withOpacity(0.6),
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
              if (_showHeatmap && _filteredIssues.isNotEmpty)
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
                                      ? _buildCloverCluster(issue, isDark)
                                      : _buildSinglePin(issue, isDark),
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
              color: isDark ? Colors.black.withOpacity(0.85) : Colors.black.withOpacity(0.75),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      'Getting your location…',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 3. ERROR OVERLAY
          if (_locationError != null)
            Container(
              color: isDark ? Colors.black.withOpacity(0.9) : Colors.black.withOpacity(0.85),
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
                      ElevatedButton.icon(
                        onPressed: _requestLocationAndLoad,
                        icon: const Icon(Icons.refresh_rounded, color: Colors.black),
                        label: const Text(
                          'Try Again',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
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
              child: _buildSearchBar(isDark),
            ),

            // 5. PROXIMITY ALERT FLOATING BANNER (Glassmorphic Notification Card)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              left: 20,
              right: 20,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, animation) {
                  final offsetAnimation = Tween<Offset>(
                    begin: const Offset(0, -0.3),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutBack,
                  ));
                  return SlideTransition(
                    position: offsetAnimation,
                    child: FadeTransition(
                      opacity: animation,
                      child: child,
                    ),
                  );
                },
                child: _activeProximityAlertIssue != null
                    ? _buildProximityAlertBanner(isDark)
                    : const SizedBox.shrink(),
              ),
            ),

            // 6. FLOATING LOCATE BUTTON
            Positioned(
              bottom: bottomOffset, // Stably aligned at the bottom offset
              right: 20,
              child: SizedBox(
                width: 44, // Slightly larger touch target
                height: 44,
                child: GlassCard(
                  color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.9) : Colors.white,
                  borderColor: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(22),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _goToMyLocation,
                    icon: Icon(Icons.my_location_rounded, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 20),
                  ),
                ),
              ),
            ),

            // 7. PRIORITY LEGEND OR COLLAPSED LEGEND TOGGLE
            Positioned(
              bottom: bottomOffset, // Positioned above bottom navigation bar to prevent overflow
              left: 20,
              right: _showLegend ? 76 : null, // Leaves 12px gap to locate button on the right when expanded
              child: _showLegend ? _buildPriorityLegend(isDark) : _buildCollapsedLegendButton(isDark),
            ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  WIDGETS
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildSearchBar(bool isDark) {
    return GlassCard(
      color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.9) : Colors.white.withOpacity(0.95),
      borderColor: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          Icon(Icons.location_on_rounded, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 22), // Location icon
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _currentPosition != null ? _currentAddressName : 'Smart City Map Monitor',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF1C1917),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: isDark ? Colors.white24 : const Color(0xFFE7E5E4), // Higher contrast divider
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
                    color: isDark ? Colors.white : const Color(0xFF0D9488), // Filter icon
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
                      color: isDark ? Colors.white : const Color(0xFF1C1917),
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
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFAFAF9), // Dynamic background
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border.all(
                      color: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
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
                            color: isDark ? Colors.white30 : const Color(0xFFD6D3D1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Map Filters',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : const Color(0xFF1C1917),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: Icon(Icons.close_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Categories Section ──
                      Text(
                        'CATEGORY',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                                    ? (isDark ? Colors.white : const Color(0xFF0D9488))
                                    : (isDark ? Colors.white10 : const Color(0xFFF5F5F4)),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? (isDark ? Colors.white : const Color(0xFF0D9488))
                                      : (isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                _categories[index],
                                style: TextStyle(
                                  color: isSelected ? (isDark ? Colors.black : Colors.white) : (isDark ? Colors.white : const Color(0xFF44403C)),
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
                      Text(
                        'REPORT STATUS',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : const Color(0xFFF5F5F4),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _statusFilter,
                            dropdownColor: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFAFAF9),
                            icon: Icon(Icons.arrow_drop_down_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                            isExpanded: true,
                            style: TextStyle(
                              color: isDark ? Colors.white : const Color(0xFF1C1917),
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
                      Text(
                        'MAP STYLE',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                                    ? (isDark ? Colors.white : const Color(0xFF0D9488))
                                    : (isDark ? Colors.white10 : const Color(0xFFF5F5F4)),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? (isDark ? Colors.white : const Color(0xFF0D9488))
                                      : (isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                style,
                                style: TextStyle(
                                  color: isSelected ? (isDark ? Colors.black : Colors.white) : (isDark ? Colors.white : const Color(0xFF44403C)),
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
                      Text(
                        'VISUAL OPTIONS',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Heatmap switch
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Show Heatmap',
                          style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          'Highlight issue density hotspots',
                          style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), fontSize: 11),
                        ),
                        activeColor: isDark ? Colors.white : const Color(0xFF0D9488),
                        value: _showHeatmap,
                        onChanged: (val) {
                          setSheetState(() => _showHeatmap = val);
                          setState(() => _showHeatmap = val);
                        },
                      ),
                      Divider(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                      // Resolved only switch
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Resolved Only',
                          style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1C1917), fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          'Show only completed maintenance tasks',
                          style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C), fontSize: 11),
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
                                foregroundColor: isDark ? Colors.white : const Color(0xFF44403C),
                                side: BorderSide(color: isDark ? Colors.white24 : const Color(0xFFE7E5E4)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: () {
                                setSheetState(() {
                                  _selectedCategory = 0;
                                  _statusFilter = 'All';
                                  _showHeatmap = false;
                                  _showResolvedOnly = false;
                                  _mapStyle = 'Standard';
                                });
                                setState(() {
                                  _selectedCategory = 0;
                                  _statusFilter = 'All';
                                  _showHeatmap = false;
                                  _showResolvedOnly = false;
                                  _mapStyle = 'Standard';
                                });
                              },
                              child: const Text('Reset', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                                foregroundColor: isDark ? Colors.black : Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 0,
                              ),
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
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

  Widget _buildPriorityLegend(bool isDark) {
    final count = _filteredIssues.length;
    return GlassCard(
      color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.95) : Colors.white.withOpacity(0.95),
      borderColor: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'MAP LEGEND',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              Row(
                children: [
                  Text(
                    "$count ${count == 1 ? 'issue' : 'issues'} shown",
                    style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF44403C), fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _showLegend = false),
                    child: Icon(
                      Icons.close_rounded,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                        color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4.5),
                          topRight: Radius.circular(4.5),
                          bottomLeft: Radius.circular(4.5),
                          bottomRight: Radius.zero,
                        ),
                        border: Border.all(color: isDark ? Colors.white : const Color(0xFF1C1917), width: 1.0),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Citizen Report Marker',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1C1917)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: Status dots part 1
          Row(
            children: [
              Expanded(child: _legendItem(const Color(0xFFEF4444), 'Pending Alert', isDark)),
              Expanded(child: _legendItem(const Color(0xFFF59E0B), 'In Review', isDark)),
            ],
          ),
          const SizedBox(height: 8),
          // Row 3: Status dots part 2
          Row(
            children: [
              Expanded(child: _legendItem(const Color(0xFF3B82F6), 'In Maintenance', isDark)),
              Expanded(child: _legendItem(const Color(0xFF10B981), 'Resolved', isDark)),
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: isDark ? Colors.white12 : const Color(0xFFE7E5E4), height: 1),
          const SizedBox(height: 10),
          Text(
            'CATEGORY COLORS',
            style: TextStyle(
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _legendNeonItem(const Color(0xFFFF6B35), 'Road/Damage', isDark)),
              Expanded(child: _legendNeonItem(const Color(0xFFFFE135), 'Lighting', isDark)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _legendNeonItem(const Color(0xFF39FF14), 'Waste', isDark)),
              Expanded(child: _legendNeonItem(const Color(0xFF00CFFF), 'Drainage', isDark)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _legendNeonItem(const Color(0xFFDA00FF), 'Noise', isDark)),
              Expanded(child: _legendNeonItem(const Color(0xFFFF2D78), 'Other', isDark)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedLegendButton(bool isDark) {
    return SizedBox(
      height: 40,
      child: GlassCard(
        color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.9) : Colors.white.withOpacity(0.95),
        borderColor: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: () => setState(() => _showLegend = true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline_rounded, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 18),
              const SizedBox(width: 8),
              Text(
                'Show Legend',
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF1C1917),
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

  Widget _legendItem(Color color, String label, bool isDark) {
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
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? Colors.white : const Color(0xFF1C1917)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _legendNeonItem(Color neonColor, String label, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F0F0F) : Colors.white,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: neonColor, width: 1.5),
            boxShadow: isDark ? [
              BoxShadow(
                color: neonColor.withOpacity(0.5),
                blurRadius: 4,
                spreadRadius: 0.5,
              )
            ] : [],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : const Color(0xFF44403C),
            ),
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