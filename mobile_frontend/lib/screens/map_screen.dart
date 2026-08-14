import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import 'package:latlong2/latlong.dart';
import '../widgets/glass_card.dart';
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import 'report_detail_screen.dart';
import '../services/notification_service.dart';
import '../localization/app_strings.dart';

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
          final lastKnown = kIsWeb ? null : await Geolocator.getLastKnownPosition();
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
        _locationError = '${tr('map_location_error_prefix')}\n${e.toString()}';
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
        title: tr('map_proximity_alert'),
        body: tr('map_proximity_alert_body')
            .replaceAll('{distance}', distance.toStringAsFixed(0))
            .replaceAll('{issue}', trCategory(issue.label)),
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
    final distanceText = dist != null ? '${dist.toStringAsFixed(0)}m' : tr('map_nearby');

    return GlassCard(
      color: isDark ? const Color(0xFF0F0F0F).withOpacity(0.9) : Colors.white.withOpacity(0.95),
      borderColor: isDark ? Colors.white24 : const Color(0xFFE7E1D5),
      borderWidth: 1.5,
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Glowing Warning Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFD16256).withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFD16256).withOpacity(0.25), width: 1),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFD16256),
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
                    Text(
                      tr('map_proximity_alert'),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: Color(0xFFD16256),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : const Color(0xFFE7E1D5),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      distanceText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF2B2B28),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  tr('map_issue_detected').replaceAll('{issue}', trCategory(cat)),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF2B2B28),
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
                      color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85),
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
                  backgroundColor: const Color(0xFFD16256).withOpacity(0.1),
                  foregroundColor: const Color(0xFFD16256),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: const Color(0xFFD16256).withOpacity(0.25)),
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
                child: Text(
                  tr('map_view'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
                  color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85),
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
              mapColor = const Color(0xFF3F8F5E); // Emerald green for resolved
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

  /// Muted per-category accent for pin borders/glow — kept distinct (unlike
  /// status colors, which are now unified) because telling categories apart
  /// at a glance is the map's actual job. Deliberately not neon: same hues,
  /// toned down so the map doesn't compete with itself.
  Color _getCategoryNeonColor(String category) {
    final cat = category.toLowerCase();
    if (cat.contains('road') || cat.contains('damage')) {
      return const Color(0xFFC2410C); // Burnt orange — road/damage
    } else if (cat.contains('light') || cat.contains('lamp')) {
      return const Color(0xFFA16207); // Muted gold — lighting
    } else if (cat.contains('waste') || cat.contains('trash') || cat.contains('rubbish')) {
      return const Color(0xFF4D7C0F); // Olive green — waste
    } else if (cat.contains('drain') || cat.contains('water')) {
      return const Color(0xFF0E7490); // Muted teal — drainage/water
    } else if (cat.contains('noise')) {
      return const Color(0xFF7E22CE); // Muted purple — noise
    } else {
      return const Color(0xFFBE185D); // Muted rose — other/general
    }
  }

  /// Builds a single high-contrast capsule pin marker representation styled like the navbar.
  Widget _buildSinglePin(_IssueMarker issue, bool isDark) {
    final status = (issue.rawData['status'] ?? 'Pending').toString();
    final int upvotes = issue.rawData['upvotes'] is int
        ? issue.rawData['upvotes']
        : (int.tryParse(issue.rawData['upvotes']?.toString() ?? '0') ?? 0);
    
    final Color statusColor = getStatusConfig(status).color;
    final bool shouldPulse = status == 'Pending';

    final double sizeMultiplier = 1.0 + math.min(upvotes * 0.15, 0.60);
    final double baseWidth = 24.0 * sizeMultiplier;
    final double baseHeight = 24.0 * sizeMultiplier;
    
    final Color glowColor = upvotes >= 5
        ? const Color(0xFFD79A2C) // Amber gold for high votes
        : upvotes >= 2
            ? const Color(0xFF6B7B8C) // Hot pink for trending votes
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
                                  : const Color(0xFF2B2B28),
                              width: 1.5 + (upvotes * 0.4).clamp(0.0, 2.5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isDark
                                    ? _getCategoryNeonColor(issue.label).withOpacity(0.55)
                                    : const Color(0xFF2B2B28).withOpacity(0.2),
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
                                  : const Color(0xFF2B2B28),
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
                                color: (glowColor == Colors.white) ? const Color(0xFF2B2B28) : Colors.white,
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
                color: const Color(0xFFD16256),
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
              border: Border.all(color: isDark ? Colors.white : const Color(0xFF2B2B28), width: 1.5), // Slate border
              boxShadow: [
                BoxShadow(
                  color: isDark ? Colors.black.withOpacity(0.4) : const Color(0xFF2B2B28).withOpacity(0.2),
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
                color: isDark ? Colors.white : const Color(0xFF2B2B28),
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
    final steps = [
      tr('map_step_submitted'),
      tr('map_step_reviewed'),
      tr('map_step_assigned'),
      tr('map_step_maintenance'),
      tr('map_step_resolved'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF1EDE4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E1D5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('map_report_progress'),
            style: TextStyle(
              color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85),
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
                stepColor = const Color(0xFF3F8F5E); // Emerald green — matches the bar
              } else if (isDone) {
                stepColor = const Color(0xFF3F8F5E); // Emerald green for completed
              } else {
                stepColor = isDark ? Colors.white38 : const Color(0xFFE7E1D5); // Grey for future
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
                            : Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E1D5), width: 1.0),
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
                              ? const Color(0xFF3F8F5E) 
                              : (isDark ? Colors.white24 : const Color(0xFFE7E1D5)),
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
                         ? const Color(0xFF3F8F5E) 
                         : (isDone 
                             ? (isDark ? Colors.white : const Color(0xFF2B2B28)) 
                             : (isDark ? const Color(0xFFB7B3AC) : const Color(0xFFB7B3AC))),
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

            // Status tag mapping — shared with every other screen, not a
            // one-off local guess, so "Pending" can never render as red again.
            final String stat = data['status'] ?? 'Pending';
            final Color statusTextCol = getStatusConfig(stat).color;
            final Color statusBgCol = statusTextCol.withOpacity(0.15);

            return Container(
              decoration: BoxDecoration(
                color: PixelTheme.bgSurface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    offset: Offset(0, -8),
                    blurRadius: 24,
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Pull handler for sheet
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: PixelTheme.accentCyan,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  // ── Header ──
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: PixelTheme.accentOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.location_on_outlined, color: PixelTheme.accentOrange, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trCategory(marker.label),
                              style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(width: 6, height: 6, decoration: BoxDecoration(color: PixelTheme.accentYellow, shape: BoxShape.circle)),
                                const SizedBox(width: 6),
                                Text(
                                  '${tr('priority_${marker.priority}')} ${tr('map_priority_suffix')}',
                                  style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.accentYellow),
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
                          PixelBadge(
                            text: trStatus((data['status'] ?? 'Pending').toString()),
                            color: getStatusConfig((data['status'] ?? 'Pending').toString()).color,
                          ),
                          if (upvotes > 0) ...[
                            const SizedBox(width: 6),
                            PixelBadge(
                              text: '▲ $upvotes',
                              color: PixelTheme.accentOrange,
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
                                    color: isDark ? Colors.white10 : const Color(0xFFF1EDE4),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E1D5)),
                                  ),
                                  child: Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      size: 48,
                                      color: isDark ? const Color(0xFFB7B3AC) : const Color(0xFFB7B3AC),
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
                                    color: const Color(0xFF3F8F5E),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 6,
                                      )
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.verified_rounded, color: Colors.white, size: 13),
                                      const SizedBox(width: 4),
                                      Text(
                                        trStatus('Resolved'),
                                        style: const TextStyle(
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
                                    color: isDark ? Colors.white10 : const Color(0xFFE7E1D5),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: isDark ? Colors.white24 : const Color(0xFFE7E1D5)),
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
                                            tr('map_before'),
                                            style: TextStyle(
                                              color: !showAfter 
                                                  ? (isDark ? Colors.white : const Color(0xFF2B2B28)) 
                                                  : (isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85)),
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
                                            tr('map_after'),
                                            style: TextStyle(
                                              color: showAfter 
                                                  ? (isDark ? Colors.white : const Color(0xFF2B2B28)) 
                                                  : (isDark ? const Color(0xFFB7B3AC) : const Color(0xFF8A8A85)),
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

                      // ── AI Prediction Banner ──
                      if (data['ai_prediction'] != null || data['confidence'] != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: PixelTheme.bgSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: PixelTheme.accentOrange, width: 1.5),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.settings_outlined, color: PixelTheme.accentOrange, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "⚙ ${tr('map_ai_match_prefix')}${(data['ai_prediction']?.toString().toUpperCase() ?? tr('category_Normal').toUpperCase())} (${data['confidence'] ?? '15.39%'})",
                                  style: PixelTheme.pixelHeading(
                                    fontSize: 10,
                                    color: PixelTheme.accentOrange,
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
                            color: const Color(0xFF3F8F5E).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF3F8F5E).withOpacity(0.3), width: 1.0),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.verified_user_rounded, color: Color(0xFF3F8F5E), size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${tr('map_resolved_on_prefix')}${data['resolved_at']}',
                                  style: const TextStyle(
                                    color: Color(0xFF3F8F5E),
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
                          color: PixelTheme.bgSurface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: PixelTheme.accentCyan.withOpacity(0.5), width: 1.2),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.map_outlined, size: 16, color: PixelTheme.accentCyan),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    (data['address'] ?? tr('common_location_unknown')).toString().toUpperCase(),
                                    style: PixelTheme.pixelHeading(
                                      fontSize: 10,
                                      color: PixelTheme.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.access_time_rounded, size: 14, color: PixelTheme.accentYellow),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data['timestamp'] ?? '',
                                    style: PixelTheme.pixelCaption(
                                      fontSize: 9,
                                      color: PixelTheme.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      PixelButton(
                        text: tr('map_view_full_details'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ReportDetailScreen(report: data),
                            ),
                          ).then((_) => _fetchReports());
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
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
                          : const Color(0xFF6B7B8C).withOpacity(0.12), // blue tint in light mode
                      borderColor: isDark 
                          ? Colors.white.withOpacity(0.3) 
                          : const Color(0xFF6B7B8C).withOpacity(0.4),
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
                          color: const Color(0xFF6B7B8C), // glowing blue/teal dot
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2), // white outline
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF6B7B8C).withOpacity(0.6),
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
                      tr('map_getting_location'),
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
                      const Icon(Icons.location_off_outlined, size: 64, color: Color(0xFFD16256)),
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
                        label: Text(
                          tr('common_retry'),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
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
                  borderColor: isDark ? Colors.white24 : const Color(0xFFE7E1D5),
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(22),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _goToMyLocation,
                    icon: Icon(Icons.my_location_rounded, color: isDark ? Colors.white : const Color(0xFFE08A5B), size: 20),
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
      color: PixelTheme.bgSurface,
      borderColor: PixelTheme.bgBorder,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          const Icon(Icons.location_on_rounded, color: PixelTheme.accentOrange, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _currentPosition != null ? _currentAddressName : tr('map_monitor_title'),
              style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: PixelTheme.bgBorder,
            margin: const EdgeInsets.symmetric(horizontal: 8),
          ),
          InkWell(
            onTap: _showFiltersBottomSheet,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.tune_rounded,
                    color: PixelTheme.accentOrange,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _selectedCategory != 0
                        ? trCategory(_categories[_selectedCategory])
                        : (_statusFilter != 'All' ? trStatus(_statusFilter) : tr('map_filters')),
                    style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
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
            return Container(
              decoration: const BoxDecoration(
                color: PixelTheme.bgSurface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                        color: PixelTheme.bgBorder,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tr('map_filters_title'),
                        style: PixelTheme.pixelHeading(fontSize: 17, color: PixelTheme.primaryGreen),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, color: PixelTheme.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Categories Section ──
                  Text(
                    tr('map_category_label'),
                    style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
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
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: isSelected ? PixelTheme.accentOrange : PixelTheme.bgInput,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            trCategory(_categories[index]),
                            style: PixelTheme.pixelBody(
                              fontSize: 13,
                              color: isSelected ? Colors.white : PixelTheme.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),

                  // ── Status Section ──
                  Text(
                    tr('map_report_status_label'),
                    style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: PixelTheme.bgInput,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _statusFilter,
                        dropdownColor: PixelTheme.bgSurface,
                        borderRadius: BorderRadius.circular(18),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, color: PixelTheme.textSecondary),
                        isExpanded: true,
                        style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
                        items: _statusOptions.map((s) {
                          return DropdownMenuItem(
                            value: s,
                            child: Text(s == 'All' ? tr('category_All') : trStatus(s)),
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
                    tr('map_style_label'),
                    style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
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
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: isSelected ? PixelTheme.accentOrange : PixelTheme.bgInput,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            tr('mapstyle_$style'),
                            style: PixelTheme.pixelBody(
                              fontSize: 13,
                              color: isSelected ? Colors.white : PixelTheme.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  // ── Toggles ──
                  Text(
                    tr('map_visual_options'),
                    style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  // Heatmap switch
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      tr('map_show_heatmap'),
                      style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      tr('map_show_heatmap_subtitle'),
                      style: PixelTheme.pixelBody(fontSize: 12, color: PixelTheme.textSecondary),
                    ),
                    activeThumbColor: PixelTheme.accentOrange,
                    value: _showHeatmap,
                    onChanged: (val) {
                      setSheetState(() => _showHeatmap = val);
                      setState(() => _showHeatmap = val);
                    },
                  ),
                  const Divider(color: PixelTheme.bgBorder, height: 1),
                  // Resolved only switch
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      tr('map_resolved_only'),
                      style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      tr('map_resolved_only_subtitle'),
                      style: PixelTheme.pixelBody(fontSize: 12, color: PixelTheme.textSecondary),
                    ),
                    activeThumbColor: PixelTheme.accentGreen,
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
                        child: PixelButton(
                          text: tr('map_reset'),
                          color: PixelTheme.bgInput,
                          textColor: PixelTheme.textSecondary,
                          height: 48,
                          fontSize: 14,
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
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PixelButton(
                          text: tr('map_apply'),
                          color: PixelTheme.accentOrange,
                          height: 48,
                          fontSize: 14,
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ],
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
      color: PixelTheme.bgSurface,
      borderColor: PixelTheme.bgBorder,
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                tr('map_legend_title'),
                style: PixelTheme.pixelCaption(fontSize: 8, color: PixelTheme.textSecondary),
              ),
              Row(
                children: [
                  Text(
                    trCount('map_issues_shown', count),
                    style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _showLegend = false),
                    child: const Icon(
                      Icons.close_rounded,
                      color: PixelTheme.textSecondary,
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
                        color: PixelTheme.bgSurface,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4.5),
                          topRight: Radius.circular(4.5),
                          bottomLeft: Radius.circular(4.5),
                          bottomRight: Radius.zero,
                        ),
                        border: Border.all(color: PixelTheme.textPrimary, width: 1.0),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tr('map_citizen_report_marker'),
                style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: Status dots — matches the one shared status→color mapping
          // used everywhere else (map pins, dashboard, history, detail).
          Row(
            children: [
              Expanded(child: _legendItem(getStatusConfig('Pending').color, tr('map_legend_pending_alert'))),
              Expanded(child: _legendItem(getStatusConfig('In Review').color, tr('map_legend_in_progress'))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _legendItem(getStatusConfig('Resolved').color, trStatus('Resolved'))),
              Expanded(child: _legendItem(getStatusConfig('Rejected').color, trStatus('Rejected'))),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: PixelTheme.bgBorder, height: 1),
          const SizedBox(height: 10),
          Text(
            tr('map_category_colors'),
            style: PixelTheme.pixelCaption(fontSize: 7, color: PixelTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Road Damage'), tr('map_legend_road_damage'))),
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Street Lighting'), tr('map_legend_lighting'))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Waste Management'), tr('map_legend_waste'))),
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Drainage'), trCategory('Drainage'))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Noise'), tr('map_legend_noise'))),
              Expanded(child: _legendNeonItem(_getCategoryNeonColor('Other'), trCategory('Other'))),
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
        color: PixelTheme.bgSurface,
        borderColor: PixelTheme.bgBorder,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () => setState(() => _showLegend = true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline_rounded, color: PixelTheme.accentOrange, size: 18),
              const SizedBox(width: 8),
              Text(
                tr('map_show_legend'),
                style: PixelTheme.pixelBody(fontSize: 14, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
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
            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _legendNeonItem(Color neonColor, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: PixelTheme.bgSurface,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: neonColor, width: 1.5),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary, fontWeight: FontWeight.w600),
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