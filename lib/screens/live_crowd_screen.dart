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
