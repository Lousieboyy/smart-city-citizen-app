import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart'; 

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: CitizenReportScreen())
);

class CitizenReportScreen extends StatefulWidget {
  const CitizenReportScreen({super.key});
  @override
  State<CitizenReportScreen> createState() => _CitizenReportScreenState();
}

class _CitizenReportScreenState extends State<CitizenReportScreen> {
  File? _image;
  final picker = ImagePicker();
  String _status = "Select a photo to report an urban issue";
  bool _isLoading = false;
  Color _resultColor = Colors.grey; 
  
  // The text box controller
  final TextEditingController _locationController = TextEditingController();

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  // Fetch the GPS and automatically type it into the text box
  Future<void> _fetchLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _locationController.text = "Please enable GPS services.");
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _locationController.text = "Location permissions denied.");
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      setState(() => _locationController.text = "Location permissions permanently denied.");
      return;
    }

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    
    // THE MAGIC: Automatically fill the text box with the GPS data!
    setState(() {
      _locationController.text = "${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}";
    });
  }

  Future<void> _pickAndReportImage(ImageSource source) async {
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _isLoading = true;
        _status = "AI is analyzing the image...";
        _resultColor = Colors.grey;
        _locationController.text = "Fetching GPS..."; // Show loading in the text box
      });
      
      // Run both tasks at the same time
      _fetchLocation();
      _sendToAI(_image!);
    }
  }

  Future<void> _sendToAI(File imageFile) async {
    try {
      var request = http.MultipartRequest(
        'POST', 
        Uri.parse('http://10.0.2.2:8000/predict')
      );
      
      request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));
      
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var decoded = jsonDecode(responseData);
        
        String issueType = decoded['issue_type'].toString();

        setState(() {
          _status = "Issue: $issueType\nConfidence: ${decoded['confidence']}";
          
          if (issueType.toLowerCase() == 'normal') {
            _resultColor = Colors.green;
          } else if (issueType.toLowerCase() == 'other') {
            _resultColor = Colors.orange;
          } else {
            _resultColor = Colors.red;
          }
        });
      } else {
        setState(() => _status = "Server Error: ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _status = "Connection Failed! Ensure Python server is running.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Citizen Reporter"),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  border: Border.all(color: _resultColor, width: 5),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: _image == null
                    ? const Icon(Icons.image_search, size: 80, color: Colors.grey)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(_image!, fit: BoxFit.cover),
                      ),
              ),
              const SizedBox(height: 20),
              
              // The hybrid text box!
              TextField(
                controller: _locationController,
                decoration: InputDecoration(
                  labelText: "Issue Location",
                  hintText: "GPS coordinates or manual address",
                  prefixIcon: const Icon(Icons.location_on, color: Colors.blueAccent),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                  ),
                ),
              ),
              
              const SizedBox(height: 20),
              
              if (_isLoading) const CircularProgressIndicator(),
              const SizedBox(height: 10),
              
              Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18, 
                  fontWeight: FontWeight.bold,
                  color: _resultColor == Colors.grey ? Colors.black : _resultColor
                ),
              ),
              
              const SizedBox(height: 30),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _pickAndReportImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text("Camera"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _pickAndReportImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text("Gallery"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}