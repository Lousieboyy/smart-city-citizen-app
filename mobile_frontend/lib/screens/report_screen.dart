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
import '../pixel_theme.dart';
import '../widgets/pixel_widgets.dart';
import '../localization/app_strings.dart';

/// Citizen report submission screen.
class CitizenReportScreen extends StatefulWidget {
  const CitizenReportScreen({super.key});

  @override
  State<CitizenReportScreen> createState() => _CitizenReportScreenState();
}

class _CitizenReportScreenState extends State<CitizenReportScreen> {
  // ── Image state ──────────────────────────────────────────────────────────
  XFile?     _pickedFile;
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
  String _locationDisplay = 'Fetching location…'; // internal sentinel — see _locationLine for display text

  // Display text for _locationDisplay/_address — these fields hold English
  // sentinel values used for internal state comparisons (e.g. _step4Done),
  // so the sentinels themselves stay untranslated; only what's shown here
  // is localized.
  String get _locationLine {
    switch (_locationDisplay) {
      case 'Fetching location…':      return tr('report_fetching_location');
      case 'Location permission denied': return tr('report_location_permission_denied');
      case 'Location unavailable':    return tr('report_location_unavailable');
      default: return _locationDisplay;
    }
  }

  String get _addressLine {
    if (_address == null) return tr('report_fetching_address');
    if (_address == 'Unknown location') return tr('report_address_unknown');
    return _address!;
  }

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
    // Keeps the step-progress tracker accurate as the user types.
    _descriptionController.addListener(_onDescriptionChanged);
  }

  void _onDescriptionChanged() => setState(() {});

  @override
  void dispose() {
    _descriptionController.removeListener(_onDescriptionChanged);
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

      final gpsString = '${tr('report_lat_label')}: ${pos.latitude.toStringAsFixed(4)}, '
          '${tr('report_lon_label')}: ${pos.longitude.toStringAsFixed(4)}';
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
      _pickedFile  = picked;
      _imageBytes  = bytes;
      _isAnalyzing = true;
      _selectedCategories.clear();
      _confidence  = null;
      _aiRawResult = null;
      _gradcamUrl  = null;
    });

    await _classifyImage(picked);
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: PixelTheme.primaryGreen),
              title: Text(
                tr('report_choose_gallery'),
                style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickImageFrom(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: PixelTheme.primaryGreen),
              title: Text(
                tr('report_take_photo'),
                style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
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
      } else if (response.statusCode == 401) {
        debugPrint('[AI] Classification failed: session expired (401)');
        if (mounted) {
          _showSnack(tr('report_session_expired'), isError: true);
        }
      } else {
        final body = await response.stream.bytesToString();
        debugPrint('[AI] Classification failed: ${response.statusCode} $body');
        if (mounted) {
          _showSnack(tr('report_ai_scan_failed').replaceAll('{code}', response.statusCode.toString()), isError: true);
        }
      }
    } catch (e) {
      debugPrint('[AI] Classification error: $e');
      if (mounted) {
        _showSnack(tr('report_ai_unreachable'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  // ── Submission ────────────────────────────────────────────────────────────
  Future<void> _submitReport() async {
    if (_imageBytes == null && _pickedFile == null) {
      _showSnack(tr('report_error_no_image'), isError: true);
      return;
    }
    if (_isAnalyzing) {
      _showSnack(tr('report_error_analyzing'), isError: true);
      return;
    }
    if (_selectedCategories.isEmpty) {
      _showSnack(tr('report_error_no_category'), isError: true);
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
            final String dupAddress = duplicateReport['address'] ?? tr('report_nearby_location');
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

      final imageName = _pickedFile?.name ?? 'upload.jpg';
      final response = (_imageBytes != null)
          ? await ApiService.submitReportBytes(fields, _imageBytes!, imageName)
          : await ApiService.submitReport(fields, _pickedFile!.path);

      if (response.statusCode == 200) {
        if (mounted) {
          _showSnack(tr('report_submit_success'), isError: false);
          Navigator.pop(context, true);
        }
      } else {
        if (mounted) _showSnack(tr('report_submit_failed'), isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack('${tr('report_error_prefix')}$e', isError: true);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        message,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      backgroundColor: isError ? PixelTheme.alertRed : PixelTheme.accentGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ));
  }

  void _enhanceDescription() {
    if (_aiRawResult == null || _aiRawResult!.isEmpty) {
      _showSnack(tr('report_enhance_needs_scan'), isError: true);
      return;
    }

    final issue = _aiRawResult!.toLowerCase();
    String enhanced = '';

    if (issue.contains('pothole')) {
      enhanced = tr('report_enhance_pothole');
    } else if (issue.contains('street light') || issue.contains('lamp')) {
      enhanced = tr('report_enhance_street_light');
    } else if (issue.contains('waste') || issue.contains('dumping') || issue.contains('garbage')) {
      enhanced = tr('report_enhance_waste');
    } else if (issue.contains('drainage') || issue.contains('clog') || issue.contains('water')) {
      enhanced = tr('report_enhance_drainage');
    } else if (issue.contains('construction') || issue.contains('road work')) {
      enhanced = tr('report_enhance_construction');
    } else if (issue.contains('tree') || issue.contains('vegetation')) {
      enhanced = tr('report_enhance_vegetation');
    } else {
      enhanced = tr('report_enhance_generic').replaceAll('{issue}', _aiRawResult!);
    }

    setState(() {
      _descriptionController.text = enhanced;
    });

    _showSnack(tr('report_enhance_success'), isError: false);
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
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: PixelTheme.accentYellow, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    tr('report_duplicate_title'),
                    style: PixelTheme.pixelHeading(fontSize: 17, color: PixelTheme.textPrimary),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('report_duplicate_body').replaceAll('{distance}', distance.toStringAsFixed(0)),
                    style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: PixelTheme.bgInput,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${tr('report_duplicate_existing_prefix')}$address',
                          style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textPrimary, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          tr('report_duplicate_distance').replaceAll('{distance}', distance.toStringAsFixed(1)),
                          style: PixelTheme.pixelBody(fontSize: 12, color: PixelTheme.textPrimary, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              actions: [
                TextButton(
                  onPressed: upvoting ? null : () => Navigator.pop(context, null),
                  child: Text(tr('common_cancel'), style: PixelTheme.pixelBody(color: PixelTheme.textSecondary, fontSize: 14)),
                ),
                OutlinedButton(
                  onPressed: upvoting ? null : () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PixelTheme.textSecondary,
                    side: const BorderSide(color: PixelTheme.bgBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: Text(tr('report_duplicate_separately'), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                ElevatedButton(
                  onPressed: upvoting
                      ? null
                      : () async {
                          setDialogState(() => upvoting = true);
                          try {
                            final upRes = await ApiService.upvoteReport(duplicateId);
                            if (upRes.statusCode == 200) {
                              _showSnack(tr('report_duplicate_confirmed'), isError: false);
                              if (context.mounted) {
                                Navigator.pop(context, true);
                              }
                            } else {
                              _showSnack(tr('report_duplicate_confirm_failed'), isError: true);
                            }
                          } catch (e) {
                            _showSnack('${tr('report_duplicate_confirm_error_prefix')}$e', isError: true);
                          } finally {
                            setDialogState(() => upvoting = false);
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: PixelTheme.accentOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: upvoting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(tr('report_duplicate_confirm_button'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Step-progress tracker ────────────────────────────────────────────────
  // Real fill-state, not a fake step count — reflects what's actually done.
  bool get _step1Done => _imageBytes != null || _pickedFile != null;
  bool get _step2Done => _selectedCategories.isNotEmpty;
  bool get _step3Done => _descriptionController.text.trim().isNotEmpty;
  bool get _step4Done => _address != null && _address != 'Unknown location';

  Widget _buildStepTracker() {
    final steps = [_step1Done, _step2Done, _step3Done, _step4Done];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: List.generate(steps.length * 2 - 1, (i) {
          if (i.isOdd) {
            final leftDone = steps[(i - 1) ~/ 2];
            return Expanded(
              child: Container(
                height: 3,
                color: leftDone ? PixelTheme.accentGreen : PixelTheme.bgBorder,
              ),
            );
          }
          final done = steps[i ~/ 2];
          return Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: done ? PixelTheme.accentGreen : PixelTheme.bgSurface,
              shape: BoxShape.circle,
              border: Border.all(color: done ? PixelTheme.accentGreen : PixelTheme.bgBorder, width: 2),
            ),
            child: done
                ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                : Text('${i ~/ 2 + 1}', style: PixelTheme.pixelCaption(fontSize: 8, color: PixelTheme.textMuted)),
          );
        }),
      ),
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
          title: Text(
            tr('report_title'),
            style: PixelTheme.pixelHeading(fontSize: 17, color: PixelTheme.primaryGreen),
          ),
          iconTheme: const IconThemeData(color: PixelTheme.primaryGreen),
        ),
        body: Form(
          key: _formKey,
          child: Column(
            children: [
              _buildStepTracker(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSectionHeader(tr('report_step_evidence'), Icons.photo_library_outlined, "1"),
                      const SizedBox(height: 12),
                      _buildImagePicker(),
                      _buildAIAnalysisCard(),
                      const SizedBox(height: 28),
                      _buildSectionHeader(tr('report_step_category'), Icons.auto_awesome_outlined, "2"),
                      const SizedBox(height: 12),
                      _buildCategoryGrid(),
                      const SizedBox(height: 28),
                      _buildSectionHeader(tr('report_step_description'), Icons.edit_note, "3"),
                      const SizedBox(height: 12),
                      _buildDescriptionField(),
                      const SizedBox(height: 28),
                      _buildSectionHeader(tr('report_step_location'), Icons.map_outlined, "4"),
                      const SizedBox(height: 12),
                      _buildLocationPreview(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Sticky footer — the primary action stays reachable without
        // scrolling all the way through a 4-step form.
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: PixelTheme.pixelShadow,
            ),
            child: _buildSubmitButton(),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, String stepNumber) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: PixelTheme.accentOrange,
            shape: BoxShape.circle,
          ),
          child: Text(
            stepNumber,
            style: PixelTheme.pixelCaption(fontSize: 11, color: Colors.white),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, size: 17, color: PixelTheme.textSecondary),
        const SizedBox(width: 6),
        Text(
          title,
          style: PixelTheme.pixelHeading(fontSize: 15, color: PixelTheme.textPrimary),
        ),
      ],
    );
  }

  Widget _buildImagePicker() {
    return GestureDetector(
      onTap: _showImageSourceDialog,
      child: GlassCard(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          height: 140,
          alignment: Alignment.center,
          child: (_imageBytes == null && _pickedFile == null)
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: PixelTheme.accentOrange.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add_a_photo_outlined, size: 22, color: PixelTheme.accentOrange),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('report_tap_to_add_photo'),
                            style: PixelTheme.pixelBody(color: PixelTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 2),
                        Text(tr('report_supports_camera_gallery'),
                            style: PixelTheme.pixelBody(color: PixelTheme.textSecondary, fontSize: 13)),
                      ],
                    ),
                  ],
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _gradcamUrl != null
                          ? Image.network(
                              '${ApiService.baseUrl}${_gradcamUrl!.startsWith('/') ? _gradcamUrl! : '/$_gradcamUrl'}',
                              fit: BoxFit.cover,
                            )
                          : (_imageBytes != null
                              ? Image.memory(_imageBytes!, fit: BoxFit.cover)
                              : const SizedBox.shrink()),
                      if (_isAnalyzing)
                        Container(
                          color: Colors.black45,
                          child: const Center(
                            child: CircularProgressIndicator(color: PixelTheme.accentOrange),
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
    if (_imageBytes == null && _pickedFile == null) return const SizedBox.shrink();
    final isNormal = _selectedCategories.contains('Normal');
    final activeColor = isNormal ? PixelTheme.accentGreen : PixelTheme.accentOrange;

    return GlassCard(
      margin: const EdgeInsets.only(top: 20),
      borderRadius: BorderRadius.circular(22),
      color: activeColor.withOpacity(0.06),
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
                        tr('report_ai_scanning'),
                        style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr('report_ai_scanning_body'),
                        style: PixelTheme.pixelBody(color: PixelTheme.textSecondary, fontSize: 13),
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
                    Expanded(
                      child: Text(
                        tr('report_ai_vision_scan'),
                        style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textPrimary),
                      ),
                    ),
                    if (_confidence != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: PixelTheme.pixelShadow,
                        ),
                        child: Text(
                          '$_confidence ${tr('common_match')}',
                          style: PixelTheme.pixelCaption(fontSize: 11, color: PixelTheme.textPrimary),
                        ),
                      ),
                  ],
                ),
                const Divider(height: 24, color: PixelTheme.bgBorder),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      tr('report_detected_issue'),
                      style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textSecondary),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: activeColor.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        (_aiRawResult ?? tr('common_none')),
                        style: PixelTheme.pixelBody(fontSize: 14, fontWeight: FontWeight.bold, color: activeColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      tr('report_auto_selected_category'),
                      style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textSecondary),
                    ),
                    Expanded(
                      child: Text(
                        _selectedCategories.isEmpty
                            ? tr('report_manual_selection')
                            : _selectedCategories.map(trCategory).join(', '),
                        style: PixelTheme.pixelBody(fontSize: 15, fontWeight: FontWeight.bold, color: PixelTheme.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 14, color: activeColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('report_ai_preselected_note'),
                        style: PixelTheme.pixelBody(fontSize: 13, color: activeColor, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildCategoryGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 58,
      ),
      itemCount: _categories.length,
      itemBuilder: (context, index) {
        final cat = _categories[index];
        final isSelected = _selectedCategories.contains(cat['name'] as String);
        final iconColor = cat['iconColor'] as Color;
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
          child: PixelCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            borderRadius: 18,
            borderWidth: 2.0,
            borderColor: isSelected ? iconColor : null,
            // Selection is carried by the border color and the checkmark,
            // never by a translucent colour wash, so the label stays
            // legible no matter what.
            color: PixelTheme.bgSurface,
            child: Row(
              children: [
                Icon(cat['icon'] as IconData, color: iconColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    trCategory(cat['name'] as String),
                    style: PixelTheme.pixelBody(
                      fontSize: 14,
                      color: PixelTheme.textPrimary,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle_rounded, color: iconColor, size: 18)
                else
                  const Icon(Icons.circle_outlined, color: PixelTheme.textMuted, size: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDescriptionField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              tr('report_step_description'),
              style: PixelTheme.pixelCaption(fontSize: 12, color: PixelTheme.textSecondary),
            ),
            if ((_imageBytes != null || _pickedFile != null) && !_isAnalyzing && _aiRawResult != null)
              TextButton.icon(
                onPressed: _enhanceDescription,
                icon: const Icon(Icons.auto_awesome, size: 14, color: PixelTheme.accentOrange),
                label: Text(
                  tr('report_ai_enhance'),
                  style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.accentOrange, fontWeight: FontWeight.bold),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  backgroundColor: PixelTheme.accentOrange.withOpacity(0.12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _descriptionController,
          maxLines: 4,
          maxLength: 500,
          style: PixelTheme.pixelBody(fontSize: 15, color: PixelTheme.textPrimary),
          decoration: InputDecoration(
            hintText: tr('report_description_hint'),
            hintStyle: PixelTheme.pixelBody(color: PixelTheme.textMuted, fontSize: 15),
            filled: true,
            fillColor: PixelTheme.bgInput,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: PixelTheme.accentOrange, width: 1.5),
            ),
            counterStyle: PixelTheme.pixelBody(fontSize: 12, color: PixelTheme.textSecondary),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return tr('report_description_error');
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
      borderRadius: BorderRadius.circular(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: PixelTheme.accentOrange.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.location_on, color: PixelTheme.accentOrange, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _addressLine,
                  style: PixelTheme.pixelBody(fontWeight: FontWeight.bold, fontSize: 15, color: PixelTheme.textPrimary),
                ),
                const SizedBox(height: 4),
                if (_locationDisplay.isNotEmpty &&
                    _locationDisplay != 'Fetching location…')
                  Text(_locationLine,
                      style: PixelTheme.pixelBody(fontSize: 13, color: PixelTheme.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return PixelButton(
      text: tr('report_submit_button'),
      color: PixelTheme.accentOrange,
      height: 54,
      isLoading: _isSubmitting,
      onPressed: (_isAnalyzing || _isSubmitting) ? null : _submitReport,
    );
  }
}