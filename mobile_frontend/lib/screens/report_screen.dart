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
  String _status = "Select a photo to report an urban issue";
  bool _isLoading = false;
  Color _resultColor = Colors.grey;
  final TextEditingController _locationController = TextEditingController();

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _fetchLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _locationController.text = "Please enable GPS services.");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _locationController.text = "Location permissions denied.");
        return;
      }
    }

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
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
        _locationController.text = "Fetching GPS...";
      });
      _fetchLocation();
      _sendToAI(_image!);
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
        String issueType = decoded['issue_type'].toString();
        setState(() {
          _status = "Issue: $issueType\nConfidence: ${decoded['confidence']}";
          _resultColor = issueType.toLowerCase() == 'normal' ? Colors.green : (issueType.toLowerCase() == 'other' ? Colors.orange : Colors.red);
        });
      } else {
        setState(() => _status = "Server Error: ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _status = "Connection Failed! Check Python server.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("File a Report"), backgroundColor: Colors.blueAccent),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Container(
              width: 300, height: 300,
              decoration: BoxDecoration(border: Border.all(color: _resultColor, width: 5), borderRadius: BorderRadius.circular(15)),
              child: _image == null ? const Icon(Icons.image_search, size: 80) : Image.file(_image!, fit: BoxFit.cover),
            ),
            const SizedBox(height: 20),
            TextField(controller: _locationController, decoration: const InputDecoration(labelText: "Location", border: OutlineInputBorder())),
            const SizedBox(height: 20),
            Text(_status, style: TextStyle(fontSize: 18, color: _resultColor)),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(onPressed: () => _pickAndReportImage(ImageSource.camera), icon: const Icon(Icons.camera), label: const Text("Camera")),
                ElevatedButton.icon(onPressed: () => _pickAndReportImage(ImageSource.gallery), icon: const Icon(Icons.photo), label: const Text("Gallery")),
              ],
            )
          ],
        ),
      ),
    );
  }
}