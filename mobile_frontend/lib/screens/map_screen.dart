import 'package:flutter/material.dart';

class MapViewScreen extends StatelessWidget {
  const MapViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Stack(
        children: [
          // 1. THE MAP BACKGROUND
          // In a real app, replace this Container with a GoogleMap() widget
          Container(
            width: double.infinity,
            height: double.infinity,
            color: const Color(0xFFE5E9F0), // Light grid-like background color
            child: CustomPaint(
              painter: GridPainter(), // Optional: adds a subtle grid look
            ),
          ),

          // 2. MAP PINS (Placeholders)
          const Positioned(
            top: 250,
            left: 180,
            child: Icon(Icons.location_on, color: Color(0xFFD32F2F), size: 40),
          ),
          const Positioned(
            top: 150,
            right: 100,
            child: Icon(Icons.location_on, color: Color(0xFFD32F2F), size: 40),
          ),

          // 3. TOP OVERLAY (Search & Filters)
          SafeArea(
            child: Column(
              children: [
                _buildSearchBar(),
                _buildCategoryFilters(),
              ],
            ),
          ),

          // 4. BOTTOM LEGEND CARD
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: _buildPriorityLegend(),
          ),
        ],
      ),
    );
  }

  // --- SEARCH BAR WIDGET ---
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        height: 55,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on_outlined, color: Color(0xFF005F52)),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Smart City Map View",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF01262E)),
              ),
            ),
            IconButton(onPressed: () {}, icon: const Icon(Icons.tune_rounded)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.layers_outlined)),
          ],
        ),
      ),
    );
  }

  // --- HORIZONTAL CATEGORY FILTERS ---
  Widget _buildCategoryFilters() {
    final categories = ["All", "Road", "Lighting", "Waste", "Drainage", "Noise"];
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          bool isSelected = index == 1; // "Road" is selected in your image
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF147460) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isSelected ? Colors.transparent : Colors.black12),
            ),
            child: Center(
              child: Text(
                categories[index],
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[700],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // --- PRIORITY LEGEND CARD ---
  Widget _buildPriorityLegend() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 15)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Priority Legend", style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              _legendItem(Colors.red, "High"),
              const SizedBox(width: 15),
              _legendItem(Colors.orange, "Medium"),
              const SizedBox(width: 15),
              _legendItem(Colors.green, "Low"),
            ],
          ),
          const SizedBox(height: 10),
          const Text("2 issues displayed", style: TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      children: [
        CircleAvatar(radius: 6, backgroundColor: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// Optional helper to draw the grid lines seen in your image
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()..color = Colors.black.withOpacity(0.05)..strokeWidth = 1;

    for (double i = 0; i < size.width; i += 40) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }

    for (double i = 0; i < size.height; i += 40) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}