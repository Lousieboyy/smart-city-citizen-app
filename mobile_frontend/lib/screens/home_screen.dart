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
        child: GridView.count(
          crossAxisCount:2,
          crossAxisSpacing: 15,
          mainAxisSpacing: 15,
          shrinkWrap: true,
          padding: EdgeInsets.all(20),
          children: [
            _buildMenuCard(
              context,
              "Report Issue",
              Icons.report_problem,
              Colors.redAccent,
              const CitizenReportScreen()
            ),
            _buildMenuCard(
              context,
              "Placeholder", 
              Icons.alarm, 
              Colors.blue, 
              const Placeholder()
              )
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCard(
    BuildContext context, 
    String title, 
    IconData, 
    Color color, 
    Widget screen)
    {
    return Card(
      child: InkWell(
        onTap: () => Navigator.push(
          context, 
          MaterialPageRoute(builder: (context) => screen)
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(IconData, color: color, size: 40),
            SizedBox(height: 10),
            Text(title),
          ],
        ),
      ),
    );
  }
}