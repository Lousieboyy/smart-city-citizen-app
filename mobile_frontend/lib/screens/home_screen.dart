import 'package:flutter/material.dart';
import 'report_screen.dart'; // Import the file we just created

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: HomeScreen(),
));

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Smart City Dashboard"),
        backgroundColor: Colors.blueAccent,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_city, size: 100, color: Colors.blueAccent),
            const SizedBox(height: 20),
            const Text(
              "Welcome, Citizen!",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Padding(
              padding: EdgeInsets.all(20.0),
              child: Text(
                "Help us keep our city safe. Report issues like potholes or broken lights directly to the council.",
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 40),
            
            // THE BUTTON: This connects to your reporting function/screen
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const CitizenReportScreen()),
                );
              },
              icon: const Icon(Icons.report_problem),
              label: const Text("Report an Issue"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}