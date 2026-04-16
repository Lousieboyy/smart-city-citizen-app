import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import 'package:latlong2/latlong.dart';

class MapViewScreen extends StatefulWidget {
  const MapViewScreen({super.key});

  @override
  State<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends State<MapViewScreen> {
  // ── flutter_map controller ────────────────────────────────────────────────────
  final MapController _mapController = MapController();

  // ── Location state ────────────────────────────────────────────────────────────
  Position? _currentPosition;
  bool _locationLoading = true;
  String? _locationError;

  // Default center (Singapore) — shown briefly while GPS loads
  LatLng _mapCenter = const LatLng(1.3521, 103.8198);
  double _mapZoom = 14.0;

  // ── Category filter ───────────────────────────────────────────────────────────
  final List<String> _categories = ["All", "Road", "Lighting", "Waste", "Drainage", "Noise"];
  int _selectedCategory = 0;

  // ── Issue data ────────────────────────────────────────────────────────────────
  List<_IssueMarker> _issues = [];

  // ── Lifecycle ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _requestLocationAndLoad();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  // ── GPS Logic ─────────────────────────────────────────────────────────────────
  Future<void> _requestLocationAndLoad() async {
    setState(() {
      _locationLoading = true;
      _locationError = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
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
          setState(() {
            _locationError = 'Location permission denied.\nPlease allow location access.';
            _locationLoading = false;
          });
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _locationError =
              'Location permission permanently denied.\nOpen app settings to grant access.';
          _locationLoading = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final userLatLng = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentPosition = position;
        _mapCenter = userLatLng;
        _mapZoom = 15.5;
        _locationLoading = true; // keep loading while we fetch reports
      });

      _mapController.move(userLatLng, 15.5);
      
      await _fetchReports();
      
      setState(() {
        _locationLoading = false;
      });
      
    } catch (e) {
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
            
            String priority = status == 'Resolved' ? 'Low' : 'Medium';
            if (cat.contains('Damage') || cat.contains('Drainage') || cat.contains('Tree')) {
              priority = status == 'Resolved' ? 'Low' : 'High';
            }
            Color mapColor = priority == 'High' ? Colors.red : (priority == 'Medium' ? Colors.orange : Colors.green);
            
            // For filter mapping ('All', 'Road', 'Lighting', 'Waste', 'Drainage', 'Noise')
            String filterId = cat.toLowerCase();

            fetchedIssues.add(_IssueMarker(
              id: filterId,
              label: cat,
              position: LatLng(report['latitude'], report['longitude']),
              priority: priority,
              color: mapColor,
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
    if (_selectedCategory == 0) return _issues;
    final cat = _categories[_selectedCategory].toLowerCase();
    return _issues.where((m) => m.id.startsWith(cat)).toList();
  }

  Future<void> _goToMyLocation() async {
    if (_currentPosition == null) {
      await _requestLocationAndLoad();
      return;
    }
    _mapController.move(
      LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      15.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Stack(
        children: [
          // 1. OPENSTREETMAP — free, no API key
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: _mapZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.smartcity',
                maxZoom: 19,
              ),

              // User location dot
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      width: 24,
                      height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF147460),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF147460).withOpacity(0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

              // Issue markers
              MarkerLayer(
                markers: _filteredIssues.map((issue) {
                  return Marker(
                    point: issue.position,
                    width: 40,
                    height: 50,
                    alignment: Alignment.topCenter,
                    child: GestureDetector(
                      onTap: () => _showIssuePopup(issue),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: issue.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: issue.color.withOpacity(0.5),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                )
                              ],
                            ),
                            child: const Icon(Icons.location_on, color: Colors.white, size: 18),
                          ),
                          Container(width: 2, height: 8, color: issue.color),
                        ],
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
              color: Colors.white.withOpacity(0.85),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF147460)),
                    SizedBox(height: 16),
                    Text(
                      'Getting your location…',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF01262E)),
                    ),
                  ],
                ),
              ),
            ),

          // 3. ERROR OVERLAY
          if (_locationError != null)
            Container(
              color: Colors.white.withOpacity(0.92),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_off_outlined, size: 64, color: Color(0xFFD32F2F)),
                      const SizedBox(height: 16),
                      Text(
                        _locationError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, color: Color(0xFF01262E), height: 1.5),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF147460),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _requestLocationAndLoad,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 4. TOP OVERLAY
          SafeArea(
            child: Column(
              children: [
                _buildSearchBar(),
                _buildCategoryFilters(),
              ],
            ),
          ),

          // 5. BOTTOM LEGEND CARD
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: _buildPriorityLegend(),
          ),

          // 6. MY LOCATION FAB
          Positioned(
            bottom: 160,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF147460),
              elevation: 4,
              onPressed: _goToMyLocation,
              tooltip: 'My Location',
              child: const Icon(Icons.my_location),
            ),
          ),
        ],
      ),
    );
  }

  void _showIssuePopup(_IssueMarker issue) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: issue.color.withOpacity(0.15),
              radius: 26,
              child: Icon(Icons.location_on, color: issue.color, size: 28),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(issue.label,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF01262E))),
                const SizedBox(height: 4),
                Row(
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: issue.color),
                    const SizedBox(width: 6),
                    Text('${issue.priority} Priority',
                        style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        height: 55,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [const BoxShadow(color: Colors.black12, blurRadius: 10)],
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on_outlined, color: Color(0xFF005F52)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _currentPosition != null
                    ? '${_currentPosition!.latitude.toStringAsFixed(4)}, ${_currentPosition!.longitude.toStringAsFixed(4)}'
                    : 'Smart City Map View',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF01262E)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(onPressed: () {}, icon: const Icon(Icons.tune_rounded)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.layers_outlined)),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryFilters() {
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final isSelected = index == _selectedCategory;
          return GestureDetector(
            onTap: () => setState(() => _selectedCategory = index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF147460) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isSelected ? Colors.transparent : Colors.black12),
                boxShadow: isSelected
                    ? [BoxShadow(color: const Color(0xFF147460).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))]
                    : [],
              ),
              child: Center(
                child: Text(
                  _categories[index],
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey[700],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPriorityLegend() {
    final count = _filteredIssues.length;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [const BoxShadow(color: Colors.black12, blurRadius: 15)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Priority Legend', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              _legendItem(Colors.red, 'High'),
              const SizedBox(width: 15),
              _legendItem(Colors.orange, 'Medium'),
              const SizedBox(width: 15),
              _legendItem(Colors.green, 'Low'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$count ${count == 1 ? 'issue' : 'issues'} displayed',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      children: [
        CircleAvatar(radius: 6, backgroundColor: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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

  const _IssueMarker({
    required this.id,
    required this.label,
    required this.position,
    required this.priority,
    required this.color,
  });
}