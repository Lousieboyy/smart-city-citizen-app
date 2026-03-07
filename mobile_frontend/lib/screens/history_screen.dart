import 'package:flutter/material.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // This list can be replaced with data from your database later
    final List<Map<String, dynamic>> notifications = [
      {
        "title": "Issue Resolved",
        "desc": "Illegal dumping near Sungai Besi has been resolved.",
        "time": "1h ago",
        "icon": Icons.check_circle_outline,
        "color": Colors.green,
        "isNew": true,
      },
      {
        "title": "Status Update",
        "desc": "Pothole on Jalan Ampang is now being repaired.",
        "time": "3h ago",
        "icon": Icons.access_time,
        "color": Colors.orange,
        "isNew": true,
      },
      {
        "title": "Authority Feedback",
        "desc": "DBKL has responded to your streetlight report.",
        "time": "5h ago",
        "icon": Icons.chat_bubble_outline,
        "color": Colors.blue,
        "isNew": false,
      },
      {
        "title": "High Priority Alert",
        "desc": "Multiple road damage reports in your area.",
        "time": "1d ago",
        "icon": Icons.warning_amber_rounded,
        "color": Colors.red,
        "isNew": false,
      },
      {
        "title": "Issue Resolved",
        "desc": "Drainage blockage at Jalan Tun Razak cleared.",
        "time": "2d ago",
        "icon": Icons.check_circle_outline,
        "color": Colors.green,
        "isNew": false,
      },
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          "History",
          style: TextStyle(
            color: Color(0xFF01262E), 
            fontWeight: FontWeight.bold, 
            fontSize: 24
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  "2 new",
                  style: TextStyle(
                    color: Colors.red, 
                    fontWeight: FontWeight.bold, 
                    fontSize: 12
                  ),
                ),
              ),
            ),
          )
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: notifications.length,
        itemBuilder: (context, index) {
          final item = notifications[index];
          return _buildHistoryCard(item);
        },
      ),
    );
  }

  Widget _buildHistoryCard(Map<String, dynamic> item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 4),
          )
        ],
        // The teal accent line for new items
        border: item['isNew'] 
            ? const Border(left: BorderSide(color: Color(0xFF005F52), width: 4)) 
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon Container
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (item['color'] as Color).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(item['icon'], color: item['color'], size: 22),
            ),
            const SizedBox(width: 16),
            // Text Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        item['title'],
                        style: const TextStyle(
                          fontWeight: FontWeight.bold, 
                          fontSize: 16,
                          color: Color(0xFF01262E),
                        ),
                      ),
                      if (item['isNew'])
                        const Icon(Icons.circle, size: 8, color: Color(0xFF005F52)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item['desc'],
                    style: TextStyle(
                      color: Colors.grey.shade600, 
                      fontSize: 14,
                      height: 1.3
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item['time'],
                    style: const TextStyle(
                      color: Colors.grey, 
                      fontSize: 12
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}