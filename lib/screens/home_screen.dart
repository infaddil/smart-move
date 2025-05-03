import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/services/notification_service.dart';
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
import 'package:smart_move/main.dart';

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
  // Inside _HomeScreenState class in lib/screens/home_screen.dart

  /// Fetches live bus activity data and combines it with stop locations.
  /// Similar to _fetchBusContext in LiveCrowdScreen.
  Future<Map<String, dynamic>> _fetchLiveBusContext() async {
    List<Map<String, dynamic>> allStops = [];
    Map<String, String> liveAssignments = {};
    Map<String, List<Map<String, dynamic>>> liveSegments = {};
    Map<String, LatLng> stopLocations = {}; // Also fetch locations here

    try {
      // a) Fetch busStops (for locations and potentially default info)
      final stopsSnap = await FirebaseFirestore.instance.collection('busStops').get();
      for (var doc in stopsSnap.docs) {
        final data = doc.data();
        final name = data['name'] as String?;
        final geo = data['location'] as GeoPoint?;
        if (name != null && geo != null) {
          final location = LatLng(geo.latitude, geo.longitude);
          stopLocations[name] = location; // Store location for later use

          // Add to allStops list (optional, if needed for general context)
          allStops.add({
            'name': name,
            'location': location,
            // You might add default crowd/eta here if needed as fallback
            'crowd': data['crowd'] as int? ?? 0,
            'eta': data['eta'] as int? ?? -1,
          });
        }
      }
      // Update state if _stopLocations is empty
      if (_stopLocations.isEmpty && stopLocations.isNotEmpty) {
        if (mounted) {
          setState(() {
            _stopLocations = stopLocations;
          });
        } else {
          _stopLocations = stopLocations; // Update directly if not mounted (less ideal)
        }
      }


      // b) Fetch live busActivity (assignments & the stops structure with live ETA/crowd)
      final actSnap = await FirebaseFirestore.instance.collection('busActivity').get();
      if (!mounted) return {'stops': [], 'assignments': {}, 'segments': {}}; // Check mounted

      for (var doc in actSnap.docs) {
        final d = doc.data();
        final busId = doc.id;
        final busCode = d['busCode'] as String?;
        final stopsListRaw = d['stops'] as List?; // List of Maps: {name, eta, crowd, location}

        if (busCode != null) {
          liveAssignments[busId] = busCode;

          if (stopsListRaw != null) {
            final List<Map<String, dynamic>> currentBusStopsData = [];
            for (var item in stopsListRaw) {
              if (item is Map<String, dynamic>) { // Explicit cast
                final name = item['name'] as String?;
                final etaRaw = item['eta'];
                final crowdRaw = item['crowd'];
                final geoPoint = item['location'] as GeoPoint?; // Location from activity

                // Use live ETA/Crowd from busActivity
                final int etaValue = (etaRaw is num) ? etaRaw.toInt() : -99; // Use distinct value for missing
                final int crowdValue = (crowdRaw is num) ? crowdRaw.toInt() : -1; // Use distinct value for missing
                final LatLng? stopLocation = geoPoint != null
                    ? LatLng(geoPoint.latitude, geoPoint.longitude)
                    : stopLocations[name]; // Fallback to busStops location

                if (name != null && stopLocation != null) {
                  currentBusStopsData.add({
                    'name': name,
                    'eta': etaValue,     // Live ETA from busActivity
                    'crowd': crowdValue, // Live Crowd from busActivity
                    'location': stopLocation // Ensure LatLng is included
                  });
                } else {
                  debugPrint("⚠️ _fetchLiveBusContext: Missing name or location for stop in busActivity/${doc.id}. Skipping item: $item");
                }
              } else {
                debugPrint("⚠️ _fetchLiveBusContext: Item in 'stops' list in busActivity/${doc.id} is not a Map. Skipping item.");
              }
            }
            liveSegments[busId] = currentBusStopsData;
          } else {
            debugPrint("⚠️ _fetchLiveBusContext: 'stops' field missing/null in busActivity/${doc.id}. Assigning empty list.");
            liveSegments[busId] = [];
          }
        } else {
          debugPrint("⚠️ _fetchLiveBusContext: Missing 'busCode' in busActivity/${doc.id}. Skipping.");
        }
      }
    } catch (e, stackTrace) {
      debugPrint("Error fetching live bus context: $e\n$stackTrace");
      // Return empty structure on error to prevent crashes downstream
      return {'stops': [], 'assignments': {}, 'segments': {}};
    }

    // Return the fetched live data
    return {
      // 'stops': allStops, // You might not need allStops if segments have locations
      'assignments': liveAssignments,
      'segments': liveSegments,
      'stopLocations': stopLocations // Include the locations map
    };
  }
  // Inside _HomeScreenState class in lib/screens/home_screen.dart

  /// Builds a prompt for Gemini using LIVE bus context.
  String _buildLivePrompt(
      String query,
      Map<String, dynamic> liveContext, // Data from _fetchLiveBusContext
      LatLng currentUserLocation,
      ) {

    final Map<String, String> liveAssignments = liveContext['assignments'] as Map<String, String>? ?? {};
    final Map<String, List<Map<String, dynamic>>> liveSegments = liveContext['segments'] as Map<String, List<Map<String, dynamic>>>? ?? {};
    final Map<String, LatLng> stopLocations = liveContext['stopLocations'] as Map<String, LatLng>? ?? {};


    // --- Format Live Bus Info ---
    String liveBusInfo = "ACTIVE BUSES (LIVE DATA):\n";
    if (liveAssignments.isEmpty) {
      liveBusInfo += "  No active buses found.\n";
    } else {
      liveAssignments.forEach((busId, busCode) {
        final stopsDataForBus = liveSegments[busId] ?? [];
        liveBusInfo += "🚌 $busCode (ID: $busId):\n";
        if (stopsDataForBus.isEmpty) {
          liveBusInfo += "  - No current stop data available.\n";
        } else {
          // Find the next stop (first in the list with non-negative ETA, or just first)
          Map<String, dynamic>? nextStopData = stopsDataForBus.firstWhere(
                  (s) => (s['eta'] as int? ?? -1) >= 0,
              orElse: () => stopsDataForBus.isNotEmpty ? stopsDataForBus.first : <String,dynamic>{}
          );
          liveBusInfo += "  - Next Stop: ${nextStopData['name'] ?? 'N/A'} (ETA: ${nextStopData['eta'] ?? '?'}m, Crowd: ${nextStopData['crowd'] ?? '?'})\n";
          liveBusInfo += "  - Following Stops (Live ETA/Crowd):\n";
          stopsDataForBus.forEach((stopData) {
            // Use ?? '?' for safety, though _fetchLiveBusContext should handle parsing
            liveBusInfo += "    - 🚏 ${stopData['name'] ?? 'Unknown'}: ETA: ${stopData['eta'] ?? '?'} min, Crowd: ${stopData['crowd'] ?? '?'} ppl\n";
          });
        }
        liveBusInfo += "\n"; // Add spacing between buses
      });
    }

    // --- Find Nearest Stop to User (using stopLocations from context) ---
    String nearestStopInfo = "NEAREST STOP TO YOUR LOCATION:\n";
    if (stopLocations.isNotEmpty && currentUserLocation != null) {
      String? nearestStopName;
      double minDistance = double.infinity;

      stopLocations.forEach((name, loc) {
        final distance = Geolocator.distanceBetween(
          currentUserLocation.latitude, currentUserLocation.longitude,
          loc.latitude, loc.longitude,
        );
        if (distance < minDistance) {
          minDistance = distance;
          nearestStopName = name;
        }
      });

      if (nearestStopName != null) {
        // Try to find live data for the nearest stop
        String liveDetails = "";
        liveAssignments.forEach((busId, busCode) {
          final segment = liveSegments[busId] ?? [];
          final stopData = segment.firstWhere(
                  (s) => s['name'] == nearestStopName,
              orElse: () => <String,dynamic>{}
          );
          if (stopData.isNotEmpty) {
            liveDetails += " (Bus $busCode: ETA ${stopData['eta'] ?? '?'}m, Crowd ${stopData['crowd'] ?? '?'})";
          }
        });
        nearestStopInfo += "  - $nearestStopName (${minDistance.toStringAsFixed(0)}m away)$liveDetails\n";
      } else {
        nearestStopInfo += "  - Could not determine nearest stop.\n";
      }
    } else {
      nearestStopInfo += "  - Cannot determine nearest stop (missing location data).\n";
    }


    // --- Construct the final prompt ---
    return """
You are SmartMove, an expert public transportation assistant for USM, Penang.
Provide concise, actionable advice for the user's destination query based *primarily* on the following LIVE, real-time bus data.

USER'S CURRENT LOCATION (Approx): ${currentUserLocation?.latitude.toStringAsFixed(5)}, ${currentUserLocation?.longitude.toStringAsFixed(5)}

LIVE BUS DATA:
$liveBusInfo
$nearestStopInfo

USER'S DESTINATION QUERY: $query

RESPONSE REQUIREMENTS:
1.  Identify the best bus(es) and stop(s) to reach the user's destination "$query".
2.  **Prioritize using the LIVE ETA and CROWD numbers provided in the 'LIVE BUS DATA' section above.** Do not make up numbers.
3.  **ETA Interpretation:** An ETA of 0 means the bus is arriving now. A negative ETA means the bus has likely already passed that stop for this trip segment. -99 means ETA data was missing.
4.  **Crowd Interpretation:** -1 means crowd data was missing.
5.  Mention the specific bus code (e.g., A1, B2).
6.  Recommend the *specific stop* the user should wait at. Consider the nearest stop to the user if appropriate.
7.  Give clear instructions (e.g., "Take Bus A1 from DK A...").
8.  If the destination stop has a negative ETA for the best bus option, inform the user the bus have passed and suggest checking the tracker or waiting for the next cycle/bus.
9.  If multiple buses serve the destination, briefly compare their live ETAs/crowds if available.
10. Keep the response helpful short, precise

NOW, based on the LIVE DATA, answer the user's query for destination "$query":
""";
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

  String _buildAIPrompt(
      String dest,
      String busType,
      List<Map<String, dynamic>> current,
      List<Map<String, dynamic>> next,
      Map<String, LatLng> allLoc,
      LatLng myPos,
      ) {
    final allStops = [...current, ...next];
    if (allStops.isEmpty) {
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

                              // Inside lib/screens/home_screen.dart
// Inside class _HomeScreenState extends State<HomeScreen> { ... }
// Inside the build method's TextField:

                              onSubmitted: (dest) async {
                                if (!mounted) return;
                                setState(() {
                                  _searchResultMessage = "🔄 Fetching live data & recommendation..."; // Updated loading message
                                });

                                final destinationInput = dest.trim();
                                final destinationLower = destinationInput.toLowerCase();
                                // String? servingBusId; // We might not need servingBusId anymore if prompt handles finding best option

                                try {
                                  // 1. Ensure Current Location is Available
                                  if (_currentPosition == null) {
                                    await _initLocation(); // Make sure we have user's location
                                    if (!mounted) return;
                                    if (_currentPosition == null) {
                                      throw Exception("Could not get your current location.");
                                    }
                                  }

                                  // 2. Fetch FRESH Live Bus Context right now
                                  final liveContext = await _fetchLiveBusContext();
                                  if (!mounted) return;

                                  // Check if context fetching failed
                                  if ((liveContext['assignments'] as Map? ?? {}).isEmpty && (liveContext['segments'] as Map? ?? {}).isEmpty) {
                                    // This might happen if _fetchLiveBusContext caught an error and returned empty maps
                                    throw Exception("Failed to fetch live bus activity data.");
                                  }

                                  // --- Optional: Basic Check if Destination Exists as a Stop Name ---
                                  // This provides a quick fallback if the AI struggles later
                                  final allKnownStopNames = (liveContext['stopLocations'] as Map<String, LatLng>? ?? {}).keys.map((k) => k.toLowerCase()).toSet();
                                  if (!allKnownStopNames.contains(destinationLower)) {
                                    // If the destination isn't even a known stop, inform the user directly maybe?
                                    // Or let the AI handle it based on the prompt instructions.
                                    // For now, we let the AI try.
                                    debugPrint("Destination '$destinationInput' not found in known stop names. Letting AI determine route.");
                                  }
                                  // --- End Optional Check ---


                                  // 3. Build the LIVE Prompt
                                  final prompt = _buildLivePrompt(
                                    destinationInput, // User's query
                                    liveContext,      // The fetched live data
                                    _currentPosition!,// User's location
                                  );
                                  debugPrint("--- Live Gemini Prompt ---\n$prompt");

                                  // 4. Call Gemini API
                                  final aiResponse = await _callGemma(prompt); // Use your existing _callGemma
                                  debugPrint("--- Live Gemini Response ---\n$aiResponse");
                                  if (!mounted) return;

                                  // 5. Display Result
                                  setState(() => _searchResultMessage = aiResponse);

                                } catch (e, stackTrace) {
                                  if (!mounted) return;
                                  debugPrint("Error getting live suggestion: $e\n$stackTrace");
                                  setState(() {
                                    _searchResultMessage = "⚠️ Error getting recommendation: ${e.toString().replaceFirst('Exception: ', '')}";
                                  });
                                }
                              }, // End of onSubmitted
                            ),

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