import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CitizenReportScreen extends StatefulWidget {
  const CitizenReportScreen({super.key});

  @override
  State<CitizenReportScreen> createState() => _CitizenReportScreenState();
}

class _CitizenReportScreenState extends State<CitizenReportScreen> {
  File? _image;
  final ImagePicker _picker = ImagePicker();
  
  // States for UX
  bool _isAnalyzing = false; 
  bool _isSubmitting = false;
  List<String> _selectedCategories = [];
  String? _confidence; 
  String? _aiRawResult; 

  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController(text: "Fetching location...");

  // ADDED: "Street Lighting" to match scope item #9
  final List<Map<String, dynamic>> _categories = [
    {'name': 'Drainage', 'icon': Icons.water_drop_outlined, 'color': const Color(0xFFE3F2FD), 'iconColor': Colors.blue},
    {'name': 'Normal', 'icon': Icons.check_circle_outline, 'color': const Color(0xFFE8F5E9), 'iconColor': Colors.green},
    {'name': 'Street Lighting', 'icon': Icons.lightbulb_outline, 'color': const Color(0xFFFFF9C4), 'iconColor': Colors.orangeAccent},
    {'name': 'Road Damage', 'icon': Icons.construction, 'color': const Color(0xFFFFEBEE), 'iconColor': Colors.red},
    {'name': 'Waste Management', 'icon': Icons.delete_outline, 'color': const Color(0xFFFFF3E0), 'iconColor': Colors.orange},
    {'name': 'Other', 'icon': Icons.more_horiz, 'color': const Color(0xFFF5F5F5), 'iconColor': Colors.grey},
  ];

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  String? _address;
  double? _latitude;
  double? _longitude;

  Future<void> _initLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission != LocationPermission.deniedForever) {
      try {
        Position position = await Geolocator.getCurrentPosition();
        
        _latitude = position.latitude;
        _longitude = position.longitude;

        String locationText = "Lat: ${position.latitude.toStringAsFixed(4)}, Lon: ${position.longitude.toStringAsFixed(4)}";
        String resolvedAddress = locationText;

        try {
          List<Placemark> placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
          if (placemarks.isNotEmpty) {
            Placemark place = placemarks[0];
            resolvedAddress = "${place.street}, ${place.locality}, ${place.country}";
          }
        } catch (e) {
          debugPrint("Geocoding error: $e");
        }

        setState(() {
          _locationController.text = locationText;
          _address = resolvedAddress;
        });
      } catch (e) {
        setState(() => _locationController.text = "Location unavailable");
        _address = "Unknown location";
      }
    }
  }

  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80, 
    );

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _isAnalyzing = true; 
        _selectedCategories.clear(); 
        _confidence = null;
        _aiRawResult = null;
      });
      await _classifyImage(_image!);
    }
  }

  Future<void> _classifyImage(File imageFile) async {
    try {
      var response = await ApiService.predict(imageFile.path);
      
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var decoded = jsonDecode(responseData);
        
        String rawAIResult = decoded['issue_type'].toString().toLowerCase().trim().replaceAll('_', ' ');
        double confidenceNum = double.parse(decoded['confidence'].replaceAll('%', ''));

        setState(() {
          _confidence = decoded['confidence'];
          _aiRawResult = decoded['issue_type']; 
          _selectedCategories.clear(); 

          if (confidenceNum > 70.0) {
            // UPDATED: MAPPING LOGIC FOR ALL 12 SCOPE ITEMS
            
            // 1. Road Damage Group (Items 0, 2, 7, 8, 10, 6)
            if (rawAIResult.contains("pothole") || 
                rawAIResult.contains("sidewalk") || 
                rawAIResult.contains("fallen tree") || 
                rawAIResult.contains("road sign") || 
                rawAIResult.contains("vandalism") ||
                rawAIResult.contains("vegetation")) {
              _selectedCategories.add("Road Damage");
            }
            
            // 2. Drainage Group (Item 1)
            if (rawAIResult.contains("drainage") || rawAIResult.contains("water")) {
              _selectedCategories.add("Drainage");
            }
            
            // 3. Waste Management Group (Items 3, 5)
            if (rawAIResult.contains("dumping") || rawAIResult.contains("burning") || rawAIResult.contains("waste")) {
              _selectedCategories.add("Waste Management");
            }

            // 4. Street Lighting (Item 9)
            if (rawAIResult.contains("street light")) {
              _selectedCategories.add("Street Lighting");
            }
            
            // 5. Normal (Item 4)
            if (rawAIResult.contains("normal")) {
              _selectedCategories.add("Normal");
            }

            // 6. Other (Item 11)
            if (rawAIResult.contains("other") || _selectedCategories.isEmpty) {
              if (!_selectedCategories.contains("Other")) _selectedCategories.add("Other");
            }
          }
        });
      }
    } catch (e) {
      debugPrint("Error: $e");
    } finally {
      setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text("Report an Issue", 
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader("EVIDENCE", Icons.photo_library_outlined),
            const SizedBox(height: 12),
            _buildImagePicker(),
            _buildAIAnalysisCard(),
            const SizedBox(height: 25),
            _buildSectionHeader("CATEGORY SELECTION", Icons.auto_awesome_outlined),
            const SizedBox(height: 12),
            _buildCategoryGrid(),
            const SizedBox(height: 25),
            _buildSectionHeader("DESCRIPTION", Icons.edit_note),
            const SizedBox(height: 10),
            _buildDescriptionField(),
            const SizedBox(height: 25),
            _buildSectionHeader("LOCATION", Icons.map_outlined),
            const SizedBox(height: 10),
            _buildLocationPreview(),
            const SizedBox(height: 30),
            _buildSubmitButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildAIAnalysisCard() {
    if (_image == null) return const SizedBox.shrink();
    bool isNormal = _selectedCategories.contains("Normal");

    return Container(
      margin: const EdgeInsets.only(top: 15),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isAnalyzing ? Colors.grey.shade50 : (isNormal ? Colors.green.shade50 : const Color(0xFFE0F2F1)),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: _isAnalyzing ? Colors.grey.shade200 : (isNormal ? Colors.green : const Color(0xFF005F52)),
          width: 1.2,
        ),
      ),
      child: _isAnalyzing 
        ? Row(
            children: const [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey)),
              SizedBox(width: 12),
              Text("Analyzing details...", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isNormal ? Icons.check_circle : Icons.analytics_outlined, color: isNormal ? Colors.green : const Color(0xFF004D40), size: 18),
                  const SizedBox(width: 8),
                  const Text("AI CALCULATION", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
                  const Spacer(),
                  if (_confidence != null)
                    Text("$_confidence Match", style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const Divider(height: 20),
              Text(
                "AI Detection: ${_aiRawResult ?? 'Analyzing...'}", 
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 4),
              Text(
                "Category Suggestion: ${_selectedCategories.isEmpty ? 'Manual Selection' : _selectedCategories.join(', ')}",
                style: TextStyle(fontSize: 13, color: isNormal ? Colors.green.shade800 : Colors.teal.shade700),
              ),
            ],
          ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.blueGrey),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 11, letterSpacing: 1.1)),
      ],
    );
  }

  Widget _buildImagePicker() {
    return GestureDetector(
      onTap: _pickImage,
      child: Container(
        height: 180, width: double.infinity,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.grey.shade200), color: Colors.grey.shade50),
        child: _image == null 
          ? Column(mainAxisAlignment: MainAxisAlignment.center, children: const [Icon(Icons.add_a_photo, size: 40, color: Colors.grey), Text("Select Photo")])
          : ClipRRect(borderRadius: BorderRadius.circular(15), child: Stack(fit: StackFit.expand, children: [Image.file(_image!, fit: BoxFit.cover), if (_isAnalyzing) Container(color: Colors.black45, child: const Center(child: CircularProgressIndicator(color: Colors.white)))]))
      ),
    );
  }

  Widget _buildCategoryGrid() {
    return Wrap(
      spacing: 12, runSpacing: 12,
      children: _categories.map((cat) {
        bool isSelected = _selectedCategories.contains(cat['name']);
        return GestureDetector(
          onTap: () {
            setState(() {
              if (_selectedCategories.contains(cat['name'])) {
                _selectedCategories.remove(cat['name']);
              } else {
                _selectedCategories.add(cat['name']);
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            width: (MediaQuery.of(context).size.width - 52) / 2,
            decoration: BoxDecoration(
              color: isSelected ? cat['color'] : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isSelected ? cat['iconColor'] : Colors.grey.shade200, width: 2),
            ),
            child: Row(
              children: [
                Icon(cat['icon'], color: cat['iconColor'], size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(cat['name'], style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDescriptionField() {
    return TextField(
      controller: _descriptionController,
      maxLines: 3,
      decoration: InputDecoration(hintText: "Extra info...", filled: true, fillColor: Colors.grey.shade50, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
    );
  }

  Widget _buildLocationPreview() {
    return Container(
      padding: const EdgeInsets.all(15), 
      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12)), 
      child: Row(
        children: [
          const Icon(Icons.location_on, color: Colors.teal), 
          const SizedBox(width: 10), 
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_address ?? "Fetching address...", style: const TextStyle(fontWeight: FontWeight.bold)),
                if (_locationController.text.isNotEmpty && _locationController.text != "Fetching location...")
                  Text(_locationController.text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            )
          )
        ]
      )
    );
  }

  Future<void> _submitReport() async {
    if (_image == null || _isAnalyzing) return;
    
    setState(() => _isSubmitting = true);
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? 1;

      Map<String, String> fields = {
        'user_id': userId.toString(),
        'description': _descriptionController.text,
        'location': _locationController.text,
        'address': _address ?? 'Unknown location',
        'categories': _selectedCategories.join(', '),
        'ai_prediction': _aiRawResult ?? 'None',
        'confidence': _confidence ?? '0%',
      };
      if (_latitude != null) fields['latitude'] = _latitude.toString();
      if (_longitude != null) fields['longitude'] = _longitude.toString();
      
      var response = await ApiService.submitReport(fields, _image!.path);
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted successfully!'), backgroundColor: Colors.green));
          Navigator.pop(context, true);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to submit report.'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        onPressed: (_image == null || _isAnalyzing || _isSubmitting) ? null : _submitReport, 
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF005F52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: _isSubmitting
          ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : const Text("Submit Report", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}