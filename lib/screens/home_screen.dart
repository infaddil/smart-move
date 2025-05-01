import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'package:smart_move/screens/bus_tracker.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:math';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _searchResultMessage;
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;
  /// stopName → its LatLng
  Map<String, LatLng> _stopLocations = {};
  Map<String, String> _busAssignments   = {};
  Map<String, List<Map<String,dynamic>>> _busCurrentSegments = {};
  Map<String, List<Map<String,dynamic>>> _busNextSegments    = {};

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadStopLocations();
    _loadBusTrackerData();
    _currentPosition = LatLng (5.354792742851638, 100.30181627359067);
    // _initLocation(); (real later)
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) _fetchUserRole();

    FirebaseAuth.instance.authStateChanges().listen((user) {
      setState(() {
        _currentUser = user;
        if (user != null) {
          _fetchUserRole();
        } else {
          _userRole = null;
        }
      });
    });
  }

  Future<void> _fetchUserRole() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    setState(() {
      _userRole = doc.data()?['role'];
    });
  }
  Future<void> _loadStopLocations() async {
    final snap = await FirebaseFirestore.instance.collection('busStops').get();
    for (var doc in snap.docs) {
      final data = doc.data();
      final name = data['name'] as String;
      final geo  = data['location'] as GeoPoint;
      _stopLocations[name] = LatLng(geo.latitude, geo.longitude);
    }
  }

  /// 1) Call Gemma (Vertex AI) with a prompt
  Future<String> _callGemma(String prompt) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    final resp = await http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-8b:generateContent?key=$apiKey'
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
          "temperature": 0.7,
          "maxOutputTokens": 1000,
          "topP": 0.9,
          "topK": 40
        }
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('Gemma API Error ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body);
    return data['candidates'][0]['content']['parts'][0]['text'];
  }
  Future<void> _loadBusTrackerData() async {
    // replicate BusTrackerScreen._initializeAllBuses + segment logic
    final types = ['A','B','C'];
    final rnd = Random();
    final primary   = types.removeAt(rnd.nextInt(types.length));
    final secondary = types[rnd.nextInt(types.length)];

    final assignments = {
      'bus1': primary + '1',
      'bus2': primary + '2',
      'bus3': secondary + '1',
    };

    final occupied = <String>[];
    final curSegs  = <String, List<Map<String,dynamic>>>{};
    final nxtSegs  = <String, List<Map<String,dynamic>>>{};

    for (var busId in assignments.keys) {
      final code   = assignments[busId]!;
      final letter = code[0];
      final segs   = await BusRouteService()
          .getAssignments(letter, occupiedStops: occupied);
      curSegs[busId] = segs['current']!;
      nxtSegs[busId] = segs['next']!;
      // mark these stops occupied so next bus won’t pick them
      for (var s in segs['current']!) {
        occupied.add(s['name'] as String);
      }
    }

    setState(() {
      _busAssignments      = assignments;
      _busCurrentSegments  = curSegs;
      _busNextSegments     = nxtSegs;
    });
  }

  String _buildGemmaPrompt(
      String dest,
      String busType,
      List<Map<String, dynamic>> current,
      List<Map<String, dynamic>> next,
      Map<String, LatLng> allLoc,
      LatLng myPos,
      ) {
    final allStops = [...current, ...next];
    if (allStops.isEmpty) {
      // you could throw or return a simple fallback prompt
      throw Exception('No stop data available for your route');
    }
    var nearest = allStops.first;
    var bestDist = double.infinity;
    for (var s in allStops) {
      final loc = allLoc[s['name']]!;
      final d = Geolocator.distanceBetween(
        myPos.latitude, myPos.longitude,
        loc.latitude, loc.longitude,
      );
      if (d < bestDist) {
        bestDist = d;
        nearest = s;
      }
    }

    final sb = StringBuffer()
      ..writeln('You are an expert Malaysian transit assistant.')
      ..writeln('\nDESTINATION: $dest')
      ..writeln('\nBUS TYPE: $busType')
      ..writeln('\nCURRENT STOPS:')
      ..writeln(current.map((s) =>
      '• ${s['name']} – ${s['crowd']} ppl, ETA ${s['eta']}m'
      ).join('\n'))
      ..writeln('\nNEXT STOPS:')
      ..writeln(next.map((s) =>
      '• ${s['name']} – ${s['crowd']} ppl, ETA ${s['eta']}m'
      ).join('\n'))
      ..writeln('\nNEAREST STOP: ${nearest['name']} '
          '(${nearest['crowd']} ppl, ETA ${nearest['eta']}m)')
      ..writeln('\nINSTRUCTION: Recommend the best stop & ETA on bus $busType for $dest.');
    return sb.toString();
  }

  Future<void> _initLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) {
      return;
    }
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    setState(() {
      _currentPosition = LatLng(pos.latitude, pos.longitude);
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: Colors.purple[100],
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, Intan',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 20),
                SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  height: MediaQuery.of(context).size.height * 0.85,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              decoration: InputDecoration(
                                hintText: 'Search destination',
                                prefixIcon: Icon(Icons.search),
                                filled: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (dest) async {
                                final lc = dest.trim().toLowerCase();
                                String? servingBusId;

                                // 1) Make sure tracker data is loaded
                                if (_busAssignments.isEmpty) {
                                  await _loadBusTrackerData();
                                }

                                // 2) Look for immediate service in current/next segments
                                _busAssignments.forEach((busId, code) {
                                  if (servingBusId != null) return;
                                  final cur = _busCurrentSegments[busId] ?? [];
                                  final nxt = _busNextSegments[busId]  ?? [];
                                  if (
                                  cur.any((s) => (s['name'] as String).toLowerCase() == lc) ||
                                      nxt.any((s) => (s['name'] as String).toLowerCase() == lc)
                                  ) {
                                    servingBusId = busId;
                                  }
                                });

                                // 3) If not immediately serviced, check full route membership
                                if (servingBusId == null) {
                                  for (var entry in _busAssignments.entries) {
                                    final busId   = entry.key;
                                    final busType = entry.value[0]; // 'A', 'B' or 'C'
                                    final doc = await FirebaseFirestore.instance
                                        .collection('route')
                                        .doc(busType)
                                        .get();
                                    final stops = List<String>.from(doc.data()?['stops'] ?? []);
                                    if (stops.any((n) => n.toLowerCase() == lc)) {
                                      servingBusId = busId;
                                      break;
                                    }
                                  }
                                }

                                // 4) No route at all?
                                if (servingBusId == null) {
                                  setState(() => _searchResultMessage =
                                  'No bus route A, B or C serves “$dest”.'
                                  );
                                  return;
                                }

                                // 5) On‐route but not currently serviced?
                                final cur = _busCurrentSegments[servingBusId!]!;
                                final nxt = _busNextSegments[servingBusId!]!;
                                if (cur.isEmpty && nxt.isEmpty) {
                                  setState(() => _searchResultMessage =
                                  'Route ${_busAssignments[servingBusId]![0]} includes “$dest” but no buses are currently servicing it. '
                                      'Please check the Bus Tracker for upcoming departures.'
                                  );
                                  return;
                                }

                                // 6) Build your Gemini prompt and ask AI
                                final prompt = _buildGemmaPrompt(
                                  dest,
                                  _busAssignments[servingBusId!]![0],
                                  cur,
                                  nxt,
                                  _stopLocations,
                                  _currentPosition!,
                                );
                                final ai = await _callGemma(prompt);
                                setState(() => _searchResultMessage = ai);
                              },
                            ),

                            // 3) Result card, sibling to the TextField
                            if (_searchResultMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Card(
                                  color: Colors.purple[50],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Text(
                                      _searchResultMessage!,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      SizedBox(height: 12),

                      // your map container, unchanged:
                      Container(
                        height: 150,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: _currentPosition != null
                            ? ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: GoogleMap(
                            initialCameraPosition: CameraPosition(
                              target: _currentPosition!,
                              zoom: 15,
                            ),
                            onMapCreated: (c) => _mapController = c,

                            // ← add this:
                            onTap: (LatLng tappedPoint) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LiveCrowdScreen(
                                    initialLocation: _currentPosition!,
                                  ),
                                ),
                              );
                            },
                            myLocationEnabled: true,
                            zoomControlsEnabled: false,
                          ),
                        )
                            : Center(child: CircularProgressIndicator()),
                      ),
                      SizedBox(height: 12),

                      // your ListView, unchanged:
                      ListView(
                        shrinkWrap: true,
                        physics: NeverScrollableScrollPhysics(),
                        children: [
                          _sectionCard(
                            'Frequent destination',
                            'To: Your school\n • 10 minutes • Arrive at 9:51 am',
                          ),
                          SizedBox(height: 10),
                          _sectionCard(
                            'Favourites',
                            '🏫 Your school: School of Computer Sciences\n🏋️‍♀️ Gym: Tan Sri Azman Hashim Centre',
                          ),
                          SizedBox(height: 10),
                          _sectionCard(
                            'Recent journeys',
                            'Hamzah Sendut 2 → KOMCA\nNasi Kandar RM1 → USM',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16), // bottom spacing so scroll doesn’t end flush to nav bar
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(radius: 28, child: Icon(icon, size: 28)),
          SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _sectionCard(String title, String content) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
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