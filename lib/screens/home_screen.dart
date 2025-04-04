import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';

class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.all(16),
        children: [
          Text('Hello, Intan', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          SizedBox(height: 10),
          TextField(
            decoration: InputDecoration(
              hintText: 'Search destination',
              prefixIcon: Icon(Icons.search),
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _iconButton('Live Crowd', Icons.wifi, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => LiveCrowdScreen()),
                );
              }),
              _iconButton('Alt routes', Icons.alt_route, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => AltRoutesScreen()),
                );
              }),
              _iconButton('My trips', Icons.receipt_long, () {
                // TODO: Navigate to my trips screen
              }),
            ],
          ),

          SizedBox(height: 20),
          _sectionCard('Frequent destination', 'To: Your school\n10 minutes    Arrive at 9:51 am'),
          SizedBox(height: 10),
          _sectionCard('Favourites', '🏫 Your school: School of Computer Sciences\n🏋️‍♀️ Gym: Tan Sri Azman Hashim Centre'),
          SizedBox(height: 10),
          _sectionCard('Recent journeys', 'Hamzah Sendut 2 → KOMCA\nNasi Kandar RM1 → USM'),
        ],
      ),
    );
  }

  Widget _iconButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: 28,
            child: Icon(icon, size: 28),
          ),
          SizedBox(height: 6),
          Text(label),
        ],
      ),
    );
  }

  Widget _sectionCard(String title, String content) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text(content),
          ],
        ),
      ),
    );
  }
}
