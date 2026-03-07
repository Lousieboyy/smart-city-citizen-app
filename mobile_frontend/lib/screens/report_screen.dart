import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';

class CitizenReportScreen extends StatefulWidget {
  const CitizenReportScreen({super.key});

  @override
  State<CitizenReportScreen> createState() => _CitizenReportScreenState();
}

class _CitizenReportScreenState extends State<CitizenReportScreen> {
  File? _image;
  final picker = ImagePicker();
  bool _isLoading = false;
  String? _selectedCategory;
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController(text: "Fetching location...");

  final List<Map<String, dynamic>> _categories = [
    {'name': 'Road Damage', 'icon': Icons.construction, 'color': Color(0xFFFFEBEE), 'iconColor': Colors.red},
    {'name': 'Street Lighting', 'icon': Icons.lightbulb_outline, 'color': Color(0xFFFFF3E0), 'iconColor': Colors.orange},
    {'name': 'Waste Management', 'icon': Icons.delete_outline, 'color': Color(0xFFE8F5E9), 'iconColor': Colors.green},
    {'name': 'Drainage', 'icon': Icons.water_drop_outlined, 'color': Color(0xFFE3F2FD), 'iconColor': Colors.blue},
    {'name': 'Noise Disturbance', 'icon': Icons.volume_up_outlined, 'color': Color(0xFFF5F5F5), 'iconColor': Colors.grey},
  ];

  @override
  void initState() {
    super.initState();
    _fetchLocation();
  }

  Future<void> _fetchLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _locationController.text = "Jalan Ampang, KL (${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)})";
      });
    } catch (e) {
      setState(() => _locationController.text = "Location unavailable");
    }
  }

  Future<void> _pickImage() async {
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _isLoading = true;
      });
      await _sendToAI(_image!);
    }
  }

  Future<void> _sendToAI(File imageFile) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse('http://10.0.2.2:8000/predict'));
      request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var decoded = jsonDecode(responseData);
        setState(() => _selectedCategory = decoded['issue_type']);
      }
    } catch (e) {
      debugPrint("AI Connection Failed: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text("Report an Issue", 
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle("CATEGORY"),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _categories.map((cat) => _buildCategoryCard(cat)).toList(),
            ),
            const SizedBox(height: 25),
            _buildSectionTitle("DESCRIPTION"),
            const SizedBox(height: 10),
            TextField(
              controller: _descriptionController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: "Describe the issue in detail...",
                hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(15),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
              ),
            ),
            const SizedBox(height: 25),
            _buildSectionTitle("PHOTO EVIDENCE"),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                height: 100,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.blue.shade50, width: 2),
                  color: Colors.blue.withOpacity(0.02),
                ),
                child: _image == null 
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.camera_alt_outlined, color: Colors.grey),
                        SizedBox(width: 8),
                        Text("Upload Photo", style: TextStyle(color: Colors.grey)),
                      ],
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Image.file(_image!, fit: BoxFit.cover),
                    ),
              ),
            ),
            const SizedBox(height: 25),
            _buildSectionTitle("LOCATION"),
            const SizedBox(height: 10),
            _buildLocationPreview(),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context), 
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xffa8cfcd),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  elevation: 0,
                ),
                child: const Text("Submit Report", 
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(title, 
      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12, letterSpacing: 1.1));
  }

  Widget _buildLocationPreview() {
    return Container(
      decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          const SizedBox(
            height: 60, 
            child: Center(
              child: Icon(Icons.map_outlined, color: Colors.blueGrey, size: 30)
            )
          ),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: const BoxDecoration(
              color: Colors.white, 
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(15))
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_outlined, color: Colors.teal, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(_locationController.text, style: const TextStyle(fontSize: 13))),
                const Icon(Icons.chevron_right, color: Colors.grey),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildCategoryCard(Map<String, dynamic> cat) {
    bool isSelected = _selectedCategory == cat['name'];
    return GestureDetector(
      onTap: () => setState(() => _selectedCategory = cat['name']),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        width: (MediaQuery.of(context).size.width - 52) / 2,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? const Color(0xFF005F52) : Colors.transparent, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: cat['color'], borderRadius: BorderRadius.circular(8)),
              child: Icon(cat['icon'], color: cat['iconColor'], size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(cat['name'], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
          ],
        ),
      ),
    );
  }
}