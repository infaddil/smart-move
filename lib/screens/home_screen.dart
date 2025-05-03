import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:math';
import 'dart:async'; // Add this line

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
  final LatLng _predefinedUserLocation = const LatLng(5.354707732783205, 100.30236721352311);
  String? _nearbyBusAlertMessage;
  String? _nearestStopName;
  double? _distanceToNearestStop;
  StreamSubscription? _busActivitySubscription;

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
    _loadStopLocations().then((_) {
      if (!mounted) return; // Check if still mounted after loading
      // 2. Find the nearest stop to the predefined location
      _findNearestStop();
      // 3. Start listening to live bus activity
      _startBusActivityListener();
    }).catchError((error) {
      debugPrint("Error during initState data loading: $error");
      // Handle error appropriately, maybe show a message
    });
  }

  // Inside class _HomeScreenState

  void _findNearestStop() {
    if (_stopLocations.isEmpty) {
      debugPrint("Cannot find nearest stop: _stopLocations is empty.");
      return;
    }

    String? nearestName;
    double minDistance = double.infinity;

    _stopLocations.forEach((name, location) {
      final distance = Geolocator.distanceBetween(
        _predefinedUserLocation.latitude,
        _predefinedUserLocation.longitude,
        location.latitude,
        location.longitude,
      );

      if (distance < minDistance) {
        minDistance = distance;
        nearestName = name;
      }
    });

    if (nearestName != null) {
      debugPrint("Nearest stop to predefined location is: $nearestName (${minDistance.toStringAsFixed(0)}m away)");
      if (mounted) { // Update state if mounted
        setState(() {
          _nearestStopName = nearestName;
          _distanceToNearestStop = minDistance;
        });
      } else { // Otherwise, just set the internal variable
        _nearestStopName = nearestName;
        _distanceToNearestStop = minDistance;
      }
    } else {
      debugPrint("Could not determine nearest stop.");
      if (mounted) setState(() => _nearestStopName = null);
      else _nearestStopName = null;
    }
  }
  // Inside class _HomeScreenState

  void _startBusActivityListener() {
    if (_nearestStopName == null) {
      debugPrint("Cannot start listener: Nearest stop not determined yet.");
      // Optionally retry finding nearest stop or wait
      return;
    }

    // Cancel any previous listener
    _busActivitySubscription?.cancel();
    debugPrint("Starting Firestore listener for busActivity...");

    _busActivitySubscription = FirebaseFirestore.instance
        .collection('busActivity')
        .snapshots()
        .listen(
        _processBusActivitySnapshot, // Call the processing function
        onError: (error) {
          debugPrint("Firestore Listener Error: $error");
          // Handle error, maybe try restarting the listener after a delay
          _busActivitySubscription?.cancel();
          _busActivitySubscription = null;
          // Consider adding retry logic here if needed
          if(mounted) {
            setState(() {
              _nearbyBusAlertMessage = "⚠️ Error fetching live bus data.";
            });
          }
        },
        onDone: () {
          debugPrint("Firestore listener stream closed.");
          _busActivitySubscription = null;
        }
    );
  }

  void _processBusActivitySnapshot(QuerySnapshot snapshot) {
    if (!mounted || _nearestStopName == null) {
      debugPrint("Skipping snapshot processing: Not mounted or nearest stop unknown.");
      return; // Exit if not mounted or nearest stop isn't set
    }

    String? foundMessage; // Temporary variable to hold a potential message

    // Iterate through each active bus document
    for (var doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final busCode = data['busCode'] as String?;
      final stopsListRaw = data['stops'] as List?; // List of Maps: {name, eta, crowd, location}

      if (busCode == null || stopsListRaw == null) continue;

      // Check the stops for *this specific bus*
      for (var item in stopsListRaw) {
        if (item is Map<String, dynamic>) {
          final stopName = item['name'] as String?;
          final etaRaw = item['eta'];

          // Check if this stop is the nearest one we care about
          if (stopName != null && stopName == _nearestStopName) {
            final int? eta = (etaRaw is num) ? etaRaw.toInt() : null;

            // Check if ETA is valid and less than 3 minutes
            if (eta != null && eta >= 0 && eta < 3) {
              // Found a bus arriving soon at the nearest stop!
              foundMessage = "🚍 Bus $busCode arriving at $_nearestStopName in $eta minute${eta == 1 ? '' : 's'}!";
              debugPrint("Found nearby alert: $foundMessage");
              break; // Stop checking other stops for *this* bus
            }
          }
        }
      } // End loop through stops for one bus

      if (foundMessage != null) {
        break; // Stop checking other buses once we found one meeting the criteria
      }
    } // End loop through all bus documents

    // Update the state *once* after checking all buses
    // Use the temporary 'foundMessage'. If it's null, no bus met the criteria.
    if (mounted && _nearbyBusAlertMessage != foundMessage) { // Only update state if message changed
      setState(() {
        _nearbyBusAlertMessage = foundMessage;
      });
    }
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
// Inside _HomeScreenState class in lib/screens/home_screen.dart

  // Inside _HomeScreenState class in lib/screens/home_screen.dart

  /// Builds a prompt for Gemini using LIVE bus context, focusing on departure from the nearest stop.
  String _buildLivePrompt(
      String query, // The user's ultimate destination
      Map<String, dynamic> liveContext, // Data from _fetchLiveBusContext
      LatLng currentUserLocation,
      ) {

    final Map<String, String> liveAssignments = liveContext['assignments'] as Map<String, String>? ?? {};
    final Map<String, List<Map<String, dynamic>>> liveSegments = liveContext['segments'] as Map<String, List<Map<String, dynamic>>>? ?? {};
    final Map<String, LatLng> stopLocations = liveContext['stopLocations'] as Map<String, LatLng>? ?? {};


    // --- Format Live Bus Info ---
    // (Keep the same formatting as before - provides necessary data for the AI)
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
          Map<String, dynamic>? nextStopData = stopsDataForBus.firstWhere(
                  (s) => (s['eta'] as int? ?? -1) >= 0,
              orElse: () => stopsDataForBus.isNotEmpty ? stopsDataForBus.first : <String,dynamic>{}
          );
          liveBusInfo += "  - Current Next Stop: ${nextStopData['name'] ?? 'N/A'} (ETA: ${nextStopData['eta'] ?? '?'}m, Crowd: ${nextStopData['crowd'] ?? '?'})\n";
          liveBusInfo += "  - Full Segment Stops (Live ETA/Crowd):\n"; // Clarified title
          stopsDataForBus.forEach((stopData) {
            liveBusInfo += "    - 🚏 ${stopData['name'] ?? 'Unknown'}: ETA: ${stopData['eta'] ?? '?'} min, Crowd: ${stopData['crowd'] ?? '?'} ppl\n";
          });
        }
        liveBusInfo += "\n";
      });
    }

    // --- Find Nearest Stop to User ---
    // (Keep the same formatting as before - provides the key starting point)
    String nearestStopInfo = "NEAREST STOP TO USER'S PREDEFINED LOCATION:\n";
    String? nearestStopNameForPrompt; // Variable to store the name for prompt instructions
    if (stopLocations.isNotEmpty && currentUserLocation != null) { // Use predefined location for calculation if needed, but prompt context uses actual maybe? Let's stick to currentUserLocation passed in for the prompt context for now.
      double minDistance = double.infinity;

      // **Important:** Use the PREDEFINED location to find the nearest stop name
      // final LatLng locationToUse = _predefinedUserLocation; // Use the fixed location
      // However, the context for the prompt should probably use the actual user location if available, or the predefined one if not. Let's assume currentUserLocation IS the one we want the AI to use for context.
      final LatLng locationToUse = currentUserLocation; // Location for distance calc in prompt context

      stopLocations.forEach((name, loc) {
        final distance = Geolocator.distanceBetween(
          locationToUse.latitude, locationToUse.longitude, // Use the location passed to the function
          loc.latitude, loc.longitude,
        );
        if (distance < minDistance) {
          minDistance = distance;
          nearestStopNameForPrompt = name; // Store the name
        }
      });

      if (nearestStopNameForPrompt != null) {
        String liveDetails = "";
        liveAssignments.forEach((busId, busCode) {
          final segment = liveSegments[busId] ?? [];
          final stopData = segment.firstWhere(
                  (s) => s['name'] == nearestStopNameForPrompt,
              orElse: () => <String,dynamic>{}
          );
          if (stopData.isNotEmpty) {
            liveDetails += " (Bus $busCode ETA here: ${stopData['eta'] ?? '?'}m)"; // Clarify ETA is *at* this stop
          }
        });
        nearestStopInfo += "  - $nearestStopNameForPrompt (${minDistance.toStringAsFixed(0)}m away)$liveDetails\n";
      } else {
        nearestStopInfo += "  - Could not determine nearest stop.\n";
      }
    } else {
      nearestStopInfo += "  - Cannot determine nearest stop (missing location data).\n";
    }

    // --- Construct the final prompt ---
    // ***** START OF UPDATED PROMPT TEXT *****
    return """
You are SmartMove, an expert public transportation assistant for USM, Penang.
Your primary goal is to help the user get from their current vicinity towards their destination ('$query') by recommending the best bus to take from their NEAREST bus stop.

USER'S CURRENT LOCATION (Approx): ${currentUserLocation?.latitude.toStringAsFixed(5)}, ${currentUserLocation?.longitude.toStringAsFixed(5)}
USER'S DESTINATION: $query

CONTEXT DATA:
$nearestStopInfo
$liveBusInfo

TASK: Recommend the best bus route departing from the user's NEAREST stop towards their destination.

RESPONSE REQUIREMENTS:
1.  First, identify the user's nearest stop mentioned in '$nearestStopInfo'. Let's call this `NearestUserStop`.
2.  Look through the 'LIVE BUS DATA'. Find buses whose 'Full Segment Stops' list includes `NearestUserStop`.
3.  Filter these buses: Only consider buses where the live ETA *at `NearestUserStop`* is **positive (>= 0)**. Ignore buses with negative ETA at `NearestUserStop` as they have already passed it for this segment.
4.  For the filtered buses (arriving soon at `NearestUserStop`), determine if their route segment continues **towards** the user's destination '$query'. (The destination might be later in the segment list or the bus route generally heads that way).
5.  **If a suitable bus is found:**
    a.  Recommend the user go to `NearestUserStop`.
    b.  Clearly state which bus (e.g., "Take Bus A1...") to catch from `NearestUserStop`.
    c.  Provide the **Live ETA for that bus *at `NearestUserStop`*** (e.g., "...arriving in 2 minutes."). Use ETA=0 to mean 'arriving now'.
    d.  Confirm this bus heads towards their destination '$query'.
6.  **If multiple suitable buses:** Suggest the one arriving earliest at `NearestUserStop`, and briefly mention the other option if its ETA is also soon.
7.  **If NO suitable bus is found:** State that there are currently no buses departing soon from `NearestUserStop` towards '$query'. You can suggest checking the Bus Tracker for later times or other routes.
8.  **ETA Interpretation:** ETA=0 means arriving now. Negative ETA means 'has passed' that stop for this segment. -99 means data missing. Use this interpretation accurately.
9.  Keep the response concise, actionable, and focused on the departure from `NearestUserStop`.

NOW, provide the recommendation based on the data and requirements:
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
  // Inside class _HomeScreenState

  @override
  void dispose() {
    _mapController?.dispose(); // Dispose map controller if you have one
    _busActivitySubscription?.cancel(); // Cancel the listener!
    debugPrint("HomeScreen disposed, listener cancelled.");
    super.dispose();
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
                                  if ((liveContext['assignments'] as Map? ?? {}).isEmpty && (liveContext['segments'] as Map? ?? {}).isEmpty) {
                                    // This might happen if _fetchLiveBusContext caught an error and returned empty maps
                                    throw Exception("Failed to fetch live bus activity data.");
                                  }

                                  final allKnownStopNames = (liveContext['stopLocations'] as Map<String, LatLng>? ?? {}).keys.map((k) => k.toLowerCase()).toSet();
                                  if (!allKnownStopNames.contains(destinationLower)) {
                                   debugPrint("Destination '$destinationInput' not found in known stop names. Letting AI determine route.");
                                  }
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
                      if (_nearbyBusAlertMessage != null && _nearbyBusAlertMessage!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12.0, bottom: 4.0), // Adjust padding as needed
                          child: Card(
                            color: Colors.lightGreen[100], // Use a distinct color
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Row( // Use Row for Icon and Text
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: Colors.orange[800], size: 20,),
                                  SizedBox(width: 8),
                                  Expanded( // Allow text to wrap
                                    child: Text(
                                      _nearbyBusAlertMessage!,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.green[800],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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