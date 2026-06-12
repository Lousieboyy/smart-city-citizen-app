import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../user_session.dart';
import 'login_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import '../widgets/glass_card.dart';
import '../widgets/background_decorator.dart';

/// Citizen report submission screen.
class CitizenReportScreen extends StatefulWidget {
  const CitizenReportScreen({super.key});

  @override
  State<CitizenReportScreen> createState() => _CitizenReportScreenState();
}

class _CitizenReportScreenState extends State<CitizenReportScreen> {
  // ── Image state ──────────────────────────────────────────────────────────
  File?      _image;
  Uint8List? _imageBytes;
  final ImagePicker _picker = ImagePicker();

  // ── UI state ─────────────────────────────────────────────────────────────
  bool _isAnalyzing  = false;
  bool _isSubmitting = false;

  // ── Category state ────────────────────────────────────────────────────────
  final List<String> _selectedCategories = [];

  // ── AI result ─────────────────────────────────────────────────────────────
  String? _confidence;
  String? _aiRawResult;

  // ── Form ──────────────────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _descriptionController = TextEditingController();

  // ── Location ──────────────────────────────────────────────────────────────
  String? _address;
  double? _latitude;
  double? _longitude;
  String _locationDisplay = 'Fetching location…';

  // ── Category definitions ──────────────────────────────────────────────────
  static const _categories = [
    {'name': 'Drainage',         'icon': Icons.water_drop_outlined,  'color': Color(0xFFE3F2FD), 'iconColor': Colors.blue},
    {'name': 'Normal',           'icon': Icons.check_circle_outline, 'color': Color(0xFFE8F5E9), 'iconColor': Colors.green},
    {'name': 'Street Lighting',  'icon': Icons.lightbulb_outline,    'color': Color(0xFFFFF9C4), 'iconColor': Colors.orangeAccent},
    {'name': 'Road Damage',      'icon': Icons.construction,         'color': Color(0xFFFFEBEE), 'iconColor': Colors.red},
    {'name': 'Waste Management', 'icon': Icons.delete_outline,       'color': Color(0xFFFFF3E0), 'iconColor': Colors.orange},
    {'name': 'Other',            'icon': Icons.more_horiz,           'color': Color(0xFFF5F5F5), 'iconColor': Colors.grey},
  ];

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  // ── Location ──────────────────────────────────────────────────────────────
  Future<void> _initLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() => _locationDisplay = 'Location permission denied');
        _address = 'Unknown location';
      }
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      _latitude  = pos.latitude;
      _longitude = pos.longitude;

      final gpsString = 'Lat: ${pos.latitude.toStringAsFixed(4)}, '
          'Lon: ${pos.longitude.toStringAsFixed(4)}';
      String resolved = gpsString;

      try {
        final marks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final p = marks[0];
          resolved = '${p.street}, ${p.locality}, ${p.country}';
        }
      } catch (_) {
        // Fallback: Use platform-independent Nominatim API (works on Windows too!)
        try {
          final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${pos.latitude}&lon=${pos.longitude}');
          final res = await http.get(url, headers: {'User-Agent': 'SmartCityCitizenReportingApp/1.0'});
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            final addressName = data['display_name'] ?? data['name'];
            if (addressName != null) {
              final parts = addressName.toString().split(',');
              if (parts.length > 2) {
                resolved = "${parts[0].trim()}, ${parts[1].trim()}, ${parts[2].trim()}";
              } else {
                resolved = addressName.toString();
              }
            }
          }
        } catch (e) {
          debugPrint("Nominatim geocoding fallback failed: $e");
        }
      }

      if (mounted) {
        setState(() {
          _locationDisplay = gpsString;
          _address = resolved;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _locationDisplay = 'Location unavailable');
        _address = 'Unknown location';
      }
    }
  }

  // ── Image picking ──────────────────────────────────────────────────────────
  Future<void> _pickImageFrom(ImageSource source) async {
    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 80,
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();

    setState(() {
      _image      = File(picked.path);
      _imageBytes = bytes;
      _isAnalyzing = true;
      _selectedCategories.clear();
      _confidence  = null;
      _aiRawResult = null;
    });

    await _classifyImage(picked);
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF818CF8)),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImageFrom(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFF818CF8)),
              title: const Text('Take a Photo'),
              onTap: () {
                Navigator.pop(context);
                _pickImageFrom(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── AI classification ───────────────────────────────────────────────────
  Future<void> _classifyImage(XFile imageFile) async {
    try {
      final isWeb = kIsWeb;
      if (isWeb && _imageBytes == null) {
        debugPrint('[AI] imageBytes is null on web — skipping classification');
        return;
      }

      final response = isWeb
          ? await ApiService.predictBytes(_imageBytes!, imageFile.name)
          : await ApiService.predict(imageFile.path);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(await response.stream.bytesToString());
        final raw = decoded['issue_type'].toString().toLowerCase().trim().replaceAll('_', ' ');
        final conf = double.tryParse(
            decoded['confidence'].toString().replaceAll('%', '')) ?? 0.0;

        setState(() {
          _confidence  = decoded['confidence'];
          _aiRawResult = decoded['issue_type'];
          _selectedCategories.clear();

          if (conf > 70.0) {
            if (raw.contains('pothole') || raw.contains('sidewalk') ||
                raw.contains('fallen tree') || raw.contains('road sign') ||
                raw.contains('vandalism') || raw.contains('vegetation')) {
              _selectedCategories.add('Road Damage');
            }
            if (raw.contains('drainage') || raw.contains('water')) {
              _selectedCategories.add('Drainage');
            }
            if (raw.contains('dumping') || raw.contains('burning') ||
                raw.contains('waste')) {
              _selectedCategories.add('Waste Management');
            }
            if (raw.contains('street light')) {
              _selectedCategories.add('Street Lighting');
            }
            if (raw.contains('normal')) {
              _selectedCategories.add('Normal');
            }
            if (raw.contains('other') || _selectedCategories.isEmpty) {
              if (!_selectedCategories.contains('Other')) {
                _selectedCategories.add('Other');
              }
            }
          }
        });
      }
    } catch (e) {
      debugPrint('[AI] Classification error: $e');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  // ── Submission ────────────────────────────────────────────────────────────
  Future<void> _submitReport() async {
    if (_image == null) {
      _showSnack('Please select an image first.', isError: true);
      return;
    }
    if (_isAnalyzing) {
      _showSnack('Please wait for AI analysis to finish.', isError: true);
      return;
    }
    if (_selectedCategories.isEmpty) {
      _showSnack('Please select at least one category.', isError: true);
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    final session = UserSession.instance;
    if (!session.isLoggedIn) {
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
      return;
    }

    // Option 3: Location-Aware Duplicate Checker
    if (_latitude != null && _longitude != null) {
      setState(() => _isSubmitting = true);
      try {
        final checkRes = await ApiService.checkDuplicate(
          _latitude!,
          _longitude!,
          _selectedCategories.join(', '),
        );
        setState(() => _isSubmitting = false);
        
        if (checkRes.statusCode == 200) {
          final data = jsonDecode(checkRes.body);
          if (data['duplicate'] == true && data['matches'] != null && (data['matches'] as List).isNotEmpty) {
            final duplicateReport = data['matches'][0];
            final int duplicateId = duplicateReport['id'];
            final String dupAddress = duplicateReport['address'] ?? 'Nearby location';
            final double dupDist = (duplicateReport['distance_meters'] as num?)?.toDouble() ?? 0.0;
            
            final bool? upvoteResult = await _showDuplicateWarningDialog(dupAddress, dupDist, duplicateId);
            if (upvoteResult == true) {
              if (mounted) {
                Navigator.pop(context, true);
              }
              return; // Upvoted and exited
            } else if (upvoteResult == null) {
              return; // User canceled submission
            }
            // If upvoteResult is false, user chose "Submit anyway". We fall through and submit!
          }
        }
      } catch (e) {
        debugPrint('[Duplicate Check] error: $e');
        setState(() => _isSubmitting = false);
      }
    }

    setState(() => _isSubmitting = true);

    try {
      final fields = <String, String>{
        'user_id':       session.userId!.toString(),
        'description':   _descriptionController.text.trim(),
        'location':      _locationDisplay,
        'address':       _address ?? 'Unknown location',
        'categories':    _selectedCategories.join(', '),
        'ai_prediction': _aiRawResult ?? 'None',
        'confidence':    _confidence  ?? '0%',
        if (_latitude  != null) 'latitude':  _latitude!.toString(),
        if (_longitude != null) 'longitude': _longitude!.toString(),
      };

      final response = kIsWeb
          ? await ApiService.submitReportBytes(
              fields, _imageBytes!, _image!.path.split('/').last)
          : await ApiService.submitReport(fields, _image!.path);

      if (response.statusCode == 200) {
        if (mounted) {
          _showSnack('Report submitted successfully!', isError: false);
          Navigator.pop(context, true);
        }
      } else {
        if (mounted) _showSnack('Failed to submit report.', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.redAccent : Colors.green,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _enhanceDescription() {
    if (_aiRawResult == null || _aiRawResult!.isEmpty) {
      _showSnack('Please upload an image and run AI scan first.', isError: true);
      return;
    }
    
    final issue = _aiRawResult!.toLowerCase();
    String enhanced = '';
    
    if (issue.contains('pothole')) {
      enhanced = 'A pothole has been detected in the road. The asphalt has eroded, creating a deep depression that presents a hazard to passing traffic and local drivers.';
    } else if (issue.contains('street light') || issue.contains('lamp')) {
      enhanced = 'A street light malfunction has been identified. The area is dark at night, causing safety concerns for pedestrians and reducing visibility for drivers.';
    } else if (issue.contains('waste') || issue.contains('dumping') || issue.contains('garbage')) {
      enhanced = 'Illegal dumping/waste accumulation has been spotted. There is piled garbage that requires urgent removal to prevent sanitation issues and blockages.';
    } else if (issue.contains('drainage') || issue.contains('clog') || issue.contains('water')) {
      enhanced = 'A drainage block or overflow has been detected. Water is pooling, which could lead to flooding and local road hazards.';
    } else if (issue.contains('construction') || issue.contains('road work')) {
      enhanced = 'Road construction or maintenance work is blocking traffic flow without proper warning signs or safety indicators.';
    } else if (issue.contains('tree') || issue.contains('vegetation')) {
      enhanced = 'Overgrown vegetation or a fallen branch is obstructing the road/sidewalk path, making it difficult for vehicles and pedestrians to pass.';
    } else {
      enhanced = 'An issue regarding $_aiRawResult has been detected at this location. Needs municipal attention for maintenance and restoration.';
    }
    
    setState(() {
      _descriptionController.text = enhanced;
    });
    
    _showSnack('AI description generated!', isError: false);
  }

  Future<bool?> _showDuplicateWarningDialog(String address, double distance, int duplicateId) {
    return showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        bool upvoting = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1B4B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: const Color(0xFF818CF8).withOpacity(0.35), width: 1.5),
              ),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 24),
                  SizedBox(width: 8),
                  Text(
                    "Nearby Report Found",
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Our system detected a similar issue already reported nearby:",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Location: $address",
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Distance: ${distance.toStringAsFixed(1)} meters away",
                          style: const TextStyle(color: Color(0xFFA5B4FC), fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    "Would you like to upvote the existing report to help prioritize it, or submit your report anyway?",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              actions: [
                TextButton(
                  onPressed: upvoting ? null : () => Navigator.pop(context, null),
                  child: const Text("Cancel", style: TextStyle(color: Color(0xFF94A3B8))),
                ),
                TextButton(
                  onPressed: upvoting ? null : () => Navigator.pop(context, false),
                  child: const Text("Submit anyway", style: TextStyle(color: Color(0xFFEF4444))),
                ),
                ElevatedButton(
                  onPressed: upvoting
                      ? null
                      : () async {
                          setDialogState(() => upvoting = true);
                          try {
                            final upRes = await ApiService.upvoteReport(duplicateId);
                            if (upRes.statusCode == 200) {
                              _showSnack('Upvote recorded! Thanks for keeping the reports clean.', isError: false);
                              if (context.mounted) {
                                Navigator.pop(context, true);
                              }
                            } else {
                              _showSnack('Failed to record upvote.', isError: true);
                            }
                          } catch (e) {
                            _showSnack('Error upvoting: $e', isError: true);
                          } finally {
                            setDialogState(() => upvoting = false);
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: upvoting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Upvote Existing", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          title: const Text(
            "Report an Issue",
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSectionHeader("EVIDENCE", Icons.photo_library_outlined, "STEP 1"),
                const SizedBox(height: 12),
                _buildImagePicker(),
                _buildAIAnalysisCard(),
                const SizedBox(height: 28),
                _buildSectionHeader("CATEGORY SELECTION", Icons.auto_awesome_outlined, "STEP 2"),
                const SizedBox(height: 12),
                _buildCategoryGrid(),
                const SizedBox(height: 28),
                _buildSectionHeader("DESCRIPTION", Icons.edit_note, "STEP 3"),
                const SizedBox(height: 12),
                _buildDescriptionField(),
                const SizedBox(height: 28),
                _buildSectionHeader("LOCATION", Icons.map_outlined, "STEP 4"),
                const SizedBox(height: 12),
                _buildLocationPreview(),
                const SizedBox(height: 36),
                _buildSubmitButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, String stepNumber) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF818CF8).withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF818CF8).withOpacity(0.25)),
          ),
          child: Text(
            stepNumber,
            style: const TextStyle(
              color: Color(0xFF818CF8),
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, size: 16, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
              fontSize: 11,
              letterSpacing: 1.1),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: GlassCard(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 180,
          alignment: Alignment.center,
          child: _image == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.add_a_photo_outlined, size: 40, color: Color(0xFF818CF8)),
                    SizedBox(height: 10),
                    Text("Tap to add evidence photo",
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    SizedBox(height: 4),
                    Text("Supports camera & gallery",
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                  ],
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      kIsWeb
                          ? Image.memory(_imageBytes!, fit: BoxFit.cover)
                          : Image.file(_image!, fit: BoxFit.cover),
                      if (_isAnalyzing)
                        Container(
                          color: Colors.black45,
                          child: const Center(
                            child: CircularProgressIndicator(color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildAIAnalysisCard() {
    if (_image == null) return const SizedBox.shrink();
    final isNormal = _selectedCategories.contains('Normal');
    final activeColor = isNormal ? const Color(0xFF34D399) : const Color(0xFF818CF8);

    return GlassCard(
      margin: const EdgeInsets.only(top: 20),
      borderColor: activeColor.withOpacity(0.35),
      color: activeColor.withOpacity(0.06),
      child: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: activeColor.withOpacity(0.04),
              blurRadius: 20,
              spreadRadius: 2,
            )
          ],
        ),
        child: _isAnalyzing
            ? Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: activeColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          "AI COMPUTER VISION SCANNING",
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              color: Color(0xFFA5B4FC),
                              letterSpacing: 1.0),
                        ),
                        SizedBox(height: 3),
                        Text(
                          "Analyzing image features & infrastructure hazards...",
                          style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              fontWeight: FontWeight.w400),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                          isNormal
                              ? Icons.verified_rounded
                              : Icons.auto_awesome_rounded,
                          color: activeColor,
                          size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        "AI COMPUTER VISION SCAN",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: Colors.white,
                            letterSpacing: 1.0),
                      ),
                      const Spacer(),
                      if (_confidence != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [activeColor, activeColor.withOpacity(0.7)],
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: activeColor.withOpacity(0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              )
                            ],
                          ),
                          child: Text(
                            "$_confidence MATCH",
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 10,
                                color: Colors.white,
                                letterSpacing: 0.8),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 24, color: Colors.white12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        "Detected Issue:  ",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF94A3B8)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: activeColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: activeColor.withOpacity(0.25), width: 1.0),
                        ),
                        child: Text(
                          (_aiRawResult ?? 'None').toUpperCase(),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: activeColor,
                              letterSpacing: 0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        "Auto-selected Category:  ",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF94A3B8)),
                      ),
                      Text(
                        _selectedCategories.isEmpty ? 'Manual Selection' : _selectedCategories.join(', '),
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 14, color: activeColor),
                      const SizedBox(width: 6),
                      Text(
                        "Categories pre-selected based on AI confidence.",
                        style: TextStyle(
                            fontSize: 11,
                            color: activeColor.withOpacity(0.85),
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildCategoryGrid() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: _categories.map((cat) {
        final isSelected = _selectedCategories.contains(cat['name'] as String);
        final iconColor  = cat['iconColor'] as Color;
        return GestureDetector(
          onTap: () {
            setState(() {
              final name = cat['name'] as String;
              if (_selectedCategories.contains(name)) {
                _selectedCategories.remove(name);
              } else {
                _selectedCategories.add(name);
              }
            });
          },
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            borderRadius: BorderRadius.circular(14),
            borderColor: isSelected ? iconColor : Colors.white.withOpacity(0.12),
            color: isSelected ? iconColor.withOpacity(0.1) : Colors.white.withOpacity(0.05),
            child: SizedBox(
              width: (MediaQuery.of(context).size.width - 92) / 2,
              child: Row(
                children: [
                  Icon(cat['icon'] as IconData, color: iconColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cat['name'] as String,
                      style: TextStyle(
                          fontSize: 12,
                          color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500),
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle_rounded, color: iconColor, size: 14),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDescriptionField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "DESCRIPTION",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8),
                letterSpacing: 0.8,
              ),
            ),
            if (_image != null && !_isAnalyzing && _aiRawResult != null)
              TextButton.icon(
                onPressed: _enhanceDescription,
                icon: const Icon(Icons.auto_awesome, size: 14, color: Color(0xFFA5B4FC)),
                label: const Text(
                  "AI Enhance",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFA5B4FC),
                  ),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  backgroundColor: const Color(0xFF818CF8).withOpacity(0.12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _descriptionController,
          maxLines: 4,
          maxLength: 500,
          style: const TextStyle(fontSize: 14, color: Colors.white),
          decoration: InputDecoration(
            hintText: "Describe the issue in detail (e.g. size, exact spot, hazard level)…",
            filled: true,
            fillColor: Colors.white.withOpacity(0.04),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.12), width: 1.0),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.12), width: 1.0),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF818CF8), width: 1.5),
            ),
            counterStyle: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Please add a brief description of the issue.';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildLocationPreview() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0EA5E9).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.location_on, color: Color(0xFF0EA5E9), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _address ?? 'Fetching address…',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                ),
                const SizedBox(height: 4),
                if (_locationDisplay.isNotEmpty &&
                    _locationDisplay != 'Fetching location…')
                  Text(_locationDisplay,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      height: 54,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: ElevatedButton(
          onPressed: _isAnalyzing || _isSubmitting ? null : _submitReport,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          child: _isSubmitting
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : const Text("SUBMIT REPORT",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}