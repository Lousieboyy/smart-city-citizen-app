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
  String? _gradcamUrl;

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
      _gradcamUrl  = null;
    });

    await _classifyImage(picked);
  }

  void _showImageSourceDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final surfaceColor = isDark ? const Color(0xFF0F0F0F) : Colors.white;

    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: primaryColor),
              title: Text(
                'Choose from Gallery',
                style: TextStyle(color: primaryColor, fontWeight: FontWeight.w500),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickImageFrom(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Icon(Icons.camera_alt_outlined, color: primaryColor),
              title: Text(
                'Take a Photo',
                style: TextStyle(color: primaryColor, fontWeight: FontWeight.w500),
              ),
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
        
        setState(() {
          _confidence  = decoded['confidence'];
          _aiRawResult = decoded['issue_type'];
          _gradcamUrl  = decoded['gradcam_url'];
          _selectedCategories.clear();

          // 1. Process multi-label predictions if present
          if (decoded['predictions'] != null) {
            final preds = decoded['predictions'] as List<dynamic>;
            for (var pred in preds) {
              final String label = pred['issue_type'].toString().toLowerCase().trim().replaceAll('_', ' ');
              final double conf = double.tryParse(
                  pred['confidence'].toString().replaceAll('%', '')) ?? 0.0;

              // Only auto-select categories that cross our 35% threshold
              if (conf >= 35.0) {
                if (label.contains('pothole') || label.contains('sidewalk') ||
                    label.contains('fallen tree') || label.contains('road sign') ||
                    label.contains('vandalism') || label.contains('vegetation')) {
                  if (!_selectedCategories.contains('Road Damage')) {
                    _selectedCategories.add('Road Damage');
                  }
                }
                if (label.contains('drainage') || label.contains('water')) {
                  if (!_selectedCategories.contains('Drainage')) {
                    _selectedCategories.add('Drainage');
                  }
                }
                if (label.contains('dumping') || label.contains('burning') ||
                    label.contains('waste')) {
                  if (!_selectedCategories.contains('Waste Management')) {
                    _selectedCategories.add('Waste Management');
                  }
                }
                if (label.contains('street light')) {
                  if (!_selectedCategories.contains('Street Lighting')) {
                    _selectedCategories.add('Street Lighting');
                  }
                }
                if (label.contains('normal')) {
                  if (!_selectedCategories.contains('Normal')) {
                    _selectedCategories.add('Normal');
                  }
                }
              }
            }
          }

          // 2. Fallback to old single-label parsing if predictions list is missing
          // or if no predictions crossed the threshold
          if (_selectedCategories.isEmpty) {
            final raw = decoded['issue_type'].toString().toLowerCase().trim().replaceAll('_', ' ');
            final conf = double.tryParse(
                decoded['confidence'].toString().replaceAll('%', '')) ?? 0.0;

            if (conf > 50.0) {
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
            }
          }

          // 3. Default fallback if still empty
          if (_selectedCategories.isEmpty) {
            _selectedCategories.add('Other');
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        message,
        style: TextStyle(color: isDark && !isError ? Colors.black : Colors.white, fontWeight: FontWeight.w500),
      ),
      backgroundColor: isError ? const Color(0xFFEF4444) : (isDark ? Colors.white : const Color(0xFF0D9488)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    final borderColor = isDark ? Colors.white24 : const Color(0xFFE7E5E4);
    final surfaceColor = isDark ? const Color(0xFF0F0F0F) : Colors.white;

    return showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        bool upvoting = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: borderColor, width: 1.5),
              ),
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 24),
                  const SizedBox(width: 8),
                  Text(
                    "Nearby Report Found",
                    style: TextStyle(color: primaryColor, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Our system detected a similar issue already reported nearby:",
                    style: TextStyle(color: secondaryColor, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Location: $address",
                          style: TextStyle(color: primaryColor, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Distance: ${distance.toStringAsFixed(1)} meters away",
                          style: TextStyle(color: primaryColor, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    "Would you like to upvote the existing report to help prioritize it, or submit your report anyway?",
                    style: TextStyle(color: secondaryColor, fontSize: 13),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              actions: [
                TextButton(
                  onPressed: upvoting ? null : () => Navigator.pop(context, null),
                  child: Text("Cancel", style: TextStyle(color: secondaryColor)),
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
                    backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
                    foregroundColor: isDark ? Colors.black : Colors.white,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);

    return BackgroundDecorator(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          title: Text(
            "Report an Issue",
            style: TextStyle(
                color: primaryColor, fontWeight: FontWeight.bold, fontSize: 18),
          ),
          iconTheme: IconThemeData(color: primaryColor),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    final borderColor = isDark ? Colors.white24 : const Color(0xFFE7E5E4);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.06),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          child: Text(
            stepNumber,
            style: TextStyle(
              color: primaryColor,
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, size: 16, color: secondaryColor),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: secondaryColor,
              fontSize: 11,
              letterSpacing: 1.1),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);

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
                  children: [
                    Icon(Icons.add_a_photo_outlined, size: 40, color: primaryColor),
                    const SizedBox(height: 10),
                    Text("Tap to add evidence photo",
                        style: TextStyle(color: primaryColor, fontSize: 13, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Text("Supports camera & gallery",
                        style: TextStyle(color: secondaryColor, fontSize: 11)),
                  ],
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _gradcamUrl != null
                          ? Image.network(
                              '${ApiService.baseUrl}${_gradcamUrl!.startsWith('/') ? _gradcamUrl! : '/$_gradcamUrl'}',
                              fit: BoxFit.cover,
                            )
                          : (kIsWeb
                              ? Image.memory(_imageBytes!, fit: BoxFit.cover)
                              : Image.file(_image!, fit: BoxFit.cover)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isNormal = _selectedCategories.contains('Normal');
    final activeColor = isNormal
        ? (isDark ? const Color(0xFF34D399) : const Color(0xFF059669))
        : (isDark ? Colors.white : const Color(0xFF0D9488));

    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    final dividerColor = isDark ? Colors.white12 : Colors.black12;

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
                      children: [
                        Text(
                          "AI COMPUTER VISION SCANNING",
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              color: primaryColor,
                              letterSpacing: 1.0),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          "Analyzing image features & infrastructure hazards...",
                          style: TextStyle(
                              color: secondaryColor,
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
                      Text(
                        "AI COMPUTER VISION SCAN",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: primaryColor,
                            letterSpacing: 1.0),
                      ),
                      const Spacer(),
                      if (_confidence != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.black : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: isDark ? Colors.white24 : const Color(0xFFE7E5E4),
                                width: 1.5),
                          ),
                          child: Text(
                            "$_confidence MATCH",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 10,
                                color: primaryColor,
                                letterSpacing: 0.8),
                          ),
                        ),
                    ],
                  ),
                  Divider(height: 24, color: dividerColor),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        "Detected Issue:  ",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: secondaryColor),
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
                      Text(
                        "Auto-selected Category:  ",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: secondaryColor),
                      ),
                      Text(
                        _selectedCategories.isEmpty ? 'Manual Selection' : _selectedCategories.join(', '),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: primaryColor),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    final borderUnselectedColor = isDark ? Colors.white24 : const Color(0xFFE7E5E4);
    final surfaceUnselectedColor = isDark ? const Color(0xFF0F0F0F) : Colors.white;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate exact width for two columns including spacing (12) and card decorations (31)
        final cardSizedBoxWidth = (constraints.maxWidth - 12) / 2 - 31;

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
                borderColor: isSelected ? iconColor : borderUnselectedColor,
                color: isSelected ? iconColor.withOpacity(isDark ? 0.1 : 0.15) : surfaceUnselectedColor,
                child: SizedBox(
                  width: cardSizedBoxWidth,
                  child: Row(
                    children: [
                      Icon(cat['icon'] as IconData, color: iconColor, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          cat['name'] as String,
                          style: TextStyle(
                              fontSize: 12,
                              color: isSelected ? primaryColor : secondaryColor,
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
      },
    );
  }

  Widget _buildDescriptionField() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
    final borderColor = isDark ? Colors.white24 : const Color(0xFFE7E5E4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "DESCRIPTION",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: secondaryColor,
                letterSpacing: 0.8,
              ),
            ),
            if (_image != null && !_isAnalyzing && _aiRawResult != null)
              TextButton.icon(
                onPressed: _enhanceDescription,
                icon: Icon(Icons.auto_awesome, size: 14, color: isDark ? Colors.white : const Color(0xFF0D9488)),
                label: Text(
                  "AI Enhance",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF0D9488),
                  ),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  backgroundColor: isDark ? Colors.white.withOpacity(0.12) : const Color(0xFF0D9488).withOpacity(0.12),
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
          style: TextStyle(fontSize: 14, color: primaryColor),
          decoration: InputDecoration(
            hintText: "Describe the issue in detail (e.g. size, exact spot, hazard level)…",
            hintStyle: TextStyle(color: secondaryColor.withOpacity(0.7)),
            filled: true,
            fillColor: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: borderColor, width: 1.0),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: borderColor, width: 1.0),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: isDark ? Colors.white : const Color(0xFF0D9488), width: 1.5),
            ),
            counterStyle: TextStyle(fontSize: 11, color: secondaryColor),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : const Color(0xFF1C1917);
    final secondaryColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.12) : const Color(0xFF0D9488).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.location_on, color: isDark ? Colors.white : const Color(0xFF0D9488), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _address ?? 'Fetching address…',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: primaryColor),
                ),
                const SizedBox(height: 4),
                if (_locationDisplay.isNotEmpty &&
                    _locationDisplay != 'Fetching location…')
                  Text(_locationDisplay,
                      style: TextStyle(
                          fontSize: 12, color: secondaryColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isDark ? Colors.white : const Color(0xFF0D9488),
          foregroundColor: isDark ? Colors.black : Colors.white,
          disabledBackgroundColor: isDark ? Colors.white38 : const Color(0xFF0D9488).withOpacity(0.5),
          disabledForegroundColor: isDark ? Colors.black54 : Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _isAnalyzing || _isSubmitting ? null : _submitReport,
        child: _isSubmitting
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    color: isDark ? Colors.black : Colors.white, strokeWidth: 2.5))
            : const Text("SUBMIT REPORT",
                style: TextStyle(
                    fontSize: 15,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.bold)),
      ),
    );
  }
}