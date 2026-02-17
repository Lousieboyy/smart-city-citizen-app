import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

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
  String _status = "Take a photo to report an urban issue";
  bool _isLoading = false;

  // Function to capture photo using Pixel's camera
  Future<void> _captureAndReport() async {
    final pickedFile = await picker.pickImage(source: ImageSource.camera);

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _isLoading = true;
        _status = "AI is analyzing the image...";
      });
      _sendToAI(_image!);
    }
  }

  // Function to send image to FastAPI
  Future<void> _sendToAI(File imageFile) async {
    try {
      var request = http.MultipartRequest(
        'POST', 
        Uri.parse('http://10.0.2.2:8000/predict') // Emulator shortcut to Laptop
      );
      
      request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));
      
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var decoded = jsonDecode(responseData);

        setState(() {
          _status = "Issue: ${decoded['issue_type']}\nConfidence: ${decoded['confidence']}";
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
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Image Preview Area
              Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: _image == null
                    ? const Icon(Icons.camera_enhance, size: 80, color: Colors.grey)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.file(_image!, fit: BoxFit.cover),
                      ),
              ),
              const SizedBox(height: 30),
              
              // Status & Results
              if (_isLoading) const CircularProgressIndicator(),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              
              const SizedBox(height: 40),
              
              // Action Button
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _captureAndReport,
                icon: const Icon(Icons.camera_alt),
                label: const Text("Capture Issue"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}