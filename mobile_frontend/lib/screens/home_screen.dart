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
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(120),
        child: AppBar(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(80),
              bottomRight: Radius.circular(80)
            ),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
                const Text("Welcome Back,", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400,)),
                const Text("User", style: TextStyle(fontSize: 18,fontWeight: FontWeight.bold )),
            ], 
          ),
        actions: [
          IconButton(
            icon: const Badge(
              label: Text("3"),
              child: Icon(Icons.notifications_none),
            ),
            onPressed: (){},
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: (){},
          ),
          const SizedBox(width: 10),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 15,left: 50, right: 50),
            child: SizedBox(
              width: double.infinity,
              height: 40,
              child: TextButton.icon(
                onPressed: (){}, 
                icon: const Icon(Icons.add, size: 20),
                label: const Text("Report an Issue"),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white24,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5)
                  )                ),
              ),
            ),
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
      ),
    ),

      body: Center(
        child: GridView.count(
          crossAxisCount:2,
          crossAxisSpacing: 15,
          mainAxisSpacing: 15,
          shrinkWrap: true,
          childAspectRatio: 0.8,
          padding: EdgeInsets.all(50),
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
            ),
            _buildMenuCard(
              context,
              "Placeholder", 
              Icons.alarm, 
              Colors.blue, 
              const Placeholder()
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
            Text(title)
          ],
        ),
      ),
    );
  }
}