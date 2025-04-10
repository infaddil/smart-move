import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart'; // 🔥 for Firestore + GeoPoint


class LiveCrowdScreen extends StatefulWidget {
  @override
  _LiveCrowdScreenState createState() => _LiveCrowdScreenState();
}

class _LiveCrowdScreenState extends State<LiveCrowdScreen> {
  late GoogleMapController _controller;
  LatLng? _currentLocation;
  List<Map<String, dynamic>> _busStops = [];
  List<Map<String, dynamic>> _sortedStops = [];

  @override
  void initState() {
    super.initState();
    _getLocation();
    _loadBusStopsFromFirestore();
  }

  Future<void> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
    });
  }
  void _showAISuggestion(String suggestion) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("AI Suggestion"),
        content: Text(suggestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("OK"),
          )
        ],
      ),
    );
  }

  void _loadBusStopsFromFirestore() async {
    final random = Random();
    final snapshot = await FirebaseFirestore.instance.collection('busStops').get();

    final stops = snapshot.docs.map((doc) {
      final data = doc.data();
      final GeoPoint geo = data['location'];
      return {
        'name': data['name'],
        'location': LatLng(geo.latitude, geo.longitude),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      };
    }).toList();

    setState(() {
      _busStops = stops;
      _sortedStops = List.from(stops)..sort((a, b) => b['crowd'].compareTo(a['crowd']));
    });
  }


  String _getLeastCrowdedSuggestion() {
    final leastCrowded = _busStops.reduce((a, b) => a['crowd'] < b['crowd'] ? a : b);
    return "🟢 Least crowded: ${leastCrowded['name']} with only ${leastCrowded['crowd']} people. ETA: ${leastCrowded['eta']} mins.";
  }

  String _getFastestETASuggestion() {
    final fastest = _busStops.reduce((a, b) => a['eta'] < b['eta'] ? a : b);
    return "⚡ Fastest arriving: ${fastest['name']} with ETA just ${fastest['eta']} minutes. Crowd: ${fastest['crowd']} people.";
  }

  String _getNearestLowCrowdSuggestion() {
    if (_currentLocation == null) return "📍 Location not available.";

    final filtered = _busStops.where((stop) => stop['crowd'] <= 20).toList();
    if (filtered.isEmpty) return "🚫 No low-crowd stops found.";

    filtered.sort((a, b) {
      final distA = Geolocator.distanceBetween(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        a['location'].latitude,
        a['location'].longitude,
      );
      final distB = Geolocator.distanceBetween(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        b['location'].latitude,
        b['location'].longitude,
      );
      return distA.compareTo(distB);
    });

    final nearest = filtered.first;
    return "📍 Nearest with low crowd: ${nearest['name']} (${nearest['crowd']} people, ETA: ${nearest['eta']} mins)";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Live Crowd")),
      body: _currentLocation == null
          ? Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) => _controller = controller,
            initialCameraPosition: CameraPosition(
              target: _currentLocation!,
              zoom: 16,
            ),
            markers: _busStops.map((stop) {
              return Marker(
                markerId: MarkerId(stop['name']),
                position: stop['location'],
                infoWindow: InfoWindow(
                  title: stop['name'],
                  snippet:
                  "${stop['crowd']} people waiting\nETA: ${stop['eta']} min",
                ),
              );
            }).toSet(),
            myLocationEnabled: true,
          ),
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black26)],
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: "Search bus stop...",
                  border: InputBorder.none,
                  icon: Icon(Icons.search),
                ),
                onSubmitted: (query) {
                  final match = _busStops.firstWhere(
                        (stop) => stop['name'].toLowerCase().contains(query.toLowerCase()),
                    orElse: () => {},
                  );

                  if (match.isNotEmpty) {
                    _controller.animateCamera(
                      CameraUpdate.newLatLng(match['location']),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("No matching bus stop found.")),
                    );
                  }
                },
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton.icon(
              icon: Icon(Icons.auto_mode),
              label: Text("Ask AI Assistant"),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                  builder: (BuildContext context) => Padding(
                  padding: const EdgeInsets.all(20.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("🧠 Gemini Suggests", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        SizedBox(height: 10),
                        ListTile(
                          leading: Icon(Icons.people_alt),
                          title: Text("Least Crowded Stop"),
                          onTap: () {
                            Navigator.pop(context);
                            _showAISuggestion(_getLeastCrowdedSuggestion());
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.timer),
                          title: Text("Fastest ETA Stop"),
                          onTap: () {
                            Navigator.pop(context);
                            _showAISuggestion(_getFastestETASuggestion());
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.location_searching),
                          title: Text("Nearest Low-Crowd Stop"),
                          onTap: () {
                            Navigator.pop(context);
                            _showAISuggestion(_getNearestLowCrowdSuggestion());
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

        ],
      ),
    );
  }
}
