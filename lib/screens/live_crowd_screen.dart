import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';

class LiveCrowdScreen extends StatefulWidget {
  @override
  _LiveCrowdScreenState createState() => _LiveCrowdScreenState();
}

class _LiveCrowdScreenState extends State<LiveCrowdScreen> {
  late GoogleMapController _controller;
  LatLng? _currentLocation;
  List<Map<String, dynamic>> _busStops = [];

  @override
  void initState() {
    super.initState();
    _getLocation();
    _loadFakeBusStops();
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

  void _loadFakeBusStops() {
    final random = Random();
    _busStops = [
      {
        'name': 'DK A',
        'location': LatLng(5.358472063851898, 100.30358172014454),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Desasiswa Tekun',
        'location': LatLng(5.356164243999046, 100.29137000150655),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Padang Kawad USM',
        'location': LatLng(5.356575824397347, 100.29438698781404),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Aman Damai',
        'location': LatLng(5.355016860781792, 100.29772995685882),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Informm',
        'location': LatLng( 5.355756904620433, 100.30022534653023),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Stor Pusat Kimia',
        'location': LatLng(5.356432270401126, 100.30096914945585),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'BHEPA',
        'location': LatLng(5.35921073913782, 100.30250488384392),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'DKSK',
        'location': LatLng(5.359404468217731, 100.30451729410511),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'SOLLAT',
        'location': LatLng(5.357330653809769, 100.30720848569456),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'GSB',
        'location': LatLng(5.356934272035779, 100.30757773835158),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'HBP',
        'location': LatLng(5.355040006814353, 100.30626811136635),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'PHS',
        'location': LatLng(5.354941724482438, 100.30370271691852),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Eureka',
        'location': LatLng(5.354770901747802, 100.30414474646078),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Harapan',
        'location': LatLng(5.355241844849605, 100.29968061136645),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Indah Kembara',
        'location': LatLng(5.355791916604481, 100.29544875369481),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Jabatan Keselamatan',
        'location': LatLng(5.355676144659425, 100.29790864945589),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'Nasi Kandar Subaidah USM',
        'location': LatLng(5.35689190629461, 100.30459688993344),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'M07 USM',
        'location': LatLng(5.356677224370704, 100.28989391453047),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
      {
        'name': 'M01 USM',
        'location': LatLng(5.356141098470615, 100.28953752062004),
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      },
    ];
  }

  String generateAISummary() {
    if (_busStops.isEmpty) return "No bus stop data available.";
    _busStops.sort((a, b) => b['crowd'].compareTo(a['crowd']));
    final top = _busStops.first;
    return "🚍 Bus is approaching ${top['name']} where ${top['crowd']} people are waiting.\n"
        "ETA: ${top['eta']} minutes.";
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

          // 🔍 Search bar
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

          // 🤖 Gemini Suggest button
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton.icon(
              onPressed: () {
                final summary = generateAISummary();
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text("Gemini Suggests"),
                    content: Text(summary),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text("OK")),
                    ],
                  ),
                );
              },
              icon: Icon(Icons.auto_mode),
              label: Text("Ask Gemini"),
            ),
          ),
        ],
      ),
    );
  }
}
