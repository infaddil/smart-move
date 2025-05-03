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
  String? _routeBusCode; // e.g., "A2"
  String? _routeStartStopName; // e.g., "HBP"
  String? _routeEndStopName; // e.g., "DK A"
  List<LatLng>? _routeFullPolylinePoints; // Full path for the bus
  List<LatLng>? _routeSegmentPolylinePoints; // Path segment (e.g., HBP to DK A)
  LatLng? _routeBusPosition; // Live position of the bus
  Color? _routeColor;
  BitmapDescriptor? _routeBusIcon;
  Set<Marker> _mapMarkers = {}; // Markers for this map
  Set<Polyline> _mapPolylines = {}; // Polylines for this map
  Timer? _busPositionUpdateTimer; // To refresh the bus position
  Map<String, Color> _busColors = {}; // To store bus colors
  Map<String, BitmapDescriptor> _busIcons = {}; // To store bus icons
  Map<String, LatLng> _liveBusPositions = {}; // Temp store for live positions
  StreamSubscription? _liveBusPositionSubscription;
  Map<String, List<String>> _routes = {};
  final List<String> _destinations = [
    'Aman Damai',
    'Informm',
    'Stor Kimia',
    'BHEPA',
    'DKSK',
    'SOLLAT',
    'HBP',
    'PHS',
    'Eureka',
    'Harapan',
  ];
  String? _selectedDestination;

  @override
  void initState() {
      super.initState();
      _initLocation();
      _loadStopLocations().then((_) { // Ensure stops are loaded first
        _loadRouteDefinitions(); // Then load routes
      });
      // _loadBusTrackerData(); // Maybe rename or refactor this
      _loadStopLocations().then((_) {
        if (!mounted) return;
        _findNearestStop();
        _startBusActivityListener();
        // Call _loadRouteDefinitions *after* stops are loaded if needed elsewhere first
        // Or call independently if order doesn't strictly matter for other init steps
        _loadRouteDefinitions();
      }).catchError((error) {
        debugPrint("Error during initState data loading: $error");
      });
      _loadSharedBusData(); // <- NEW: Load colors, icons, maybe paths
      _startLiveBusPositionListener(); // <- NEW: Listen to live bus positions
      _currentPosition = LatLng (5.354792742851638, 100.30181627359067);
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

  Future<void> _loadSharedBusData() async {
    // Copy color definitions from BusTrackerScreen
    _busColors = {
      'A1': Colors.purple, 'A2': Colors.deepOrangeAccent,
      'B1': Colors.green, 'B2': Colors.limeAccent,
      'C1': Colors.pink, 'C2': Colors.blue,
    };

    // Copy icon loading logic from BusTrackerScreen
    _busColors.keys.forEach((code) {
      BitmapDescriptor.fromAssetImage(
        ImageConfiguration(size: Size(48, 48)), // Adjust size if needed
        'assets/bus_$code.png', // Ensure these assets exist!
      ).then((d) {
        if (mounted) setState(() => _busIcons[code] = d);
      }).catchError((e) {
        debugPrint('❌ Failed to load assets/bus_$code.png in HomeScreen → $e');
        if (mounted) {
          setState(() => _busIcons[code] = BitmapDescriptor.defaultMarkerWithHue(
              HSVColor.fromColor(_busColors[code] ?? Colors.grey).hue));
        }
      });
    });

    // --- Fetch Full Route Paths (example - adapt based on your structure) ---
    // This assumes you have route definitions and can generate smooth paths
    // This logic likely needs to be shared or replicated from BusTracker
    // For simplicity, let's assume _fetchLiveBusContext or another function can provide this
    // or you query 'route' collection + _stopLocations + _generateSmoothPath here.
    // Example placeholder:
    // await _generateAllBusPaths(); // You'd need to implement or call this
  }

  void _startLiveBusPositionListener() {
    _liveBusPositionSubscription?.cancel(); // Cancel previous listener
    _liveBusPositionSubscription = FirebaseFirestore.instance
        .collection('busActivity')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      Map<String, LatLng> updatedPositions = {};
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final busCode = data['busCode'] as String?;
        final geoPoint = data['currentPosition'] as GeoPoint?;
        if (busCode != null && geoPoint != null) {
          updatedPositions[busCode] = LatLng(geoPoint.latitude, geoPoint.longitude);
        }
      }
      // Store all live positions temporarily
      _liveBusPositions = updatedPositions;

      // If a route is currently displayed, update its bus position
      if (_routeBusCode != null && _liveBusPositions.containsKey(_routeBusCode)) {
        setState(() {
          _routeBusPosition = _liveBusPositions[_routeBusCode!];
          _updateMapMarkersAndPolylines(); // Update the map elements
        });
      }

    }, onError: (error) {
      debugPrint("Error listening to live bus positions: $error");
    });
  }
// Add this function inside _HomeScreenState
  Future<void> _loadRouteDefinitions() async {
    try {
      final routeSnap = await FirebaseFirestore.instance.collection('route').get();
      Map<String, List<String>> tempRoutes = {};
      for (var doc in routeSnap.docs) {
        final stopsData = doc.data()['stops'];
        if (stopsData is List) {
          tempRoutes[doc.id] = List<String>.from(stopsData.map((item) => item.toString()));
        } else {
          debugPrint("⚠️ Route data for ${doc.id} is missing or not a list.");
        }
      }
      if (mounted) {
        setState(() {
          _routes = tempRoutes;
        });
      }
      debugPrint("Loaded route definitions: ${_routes.keys.join(', ')}");
    } catch (e) {
      debugPrint("Error loading route definitions: $e");
    }
  }

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
    // 1) Bail out early if we’re not ready
    if (!mounted || _nearestStopName == null) {
      debugPrint("Skipping snapshot processing: Not mounted or nearest stop unknown.");
      return;
    }

    // 2) Find any bus arriving < 3 min at the nearest stop
    String? foundMessage;
    for (var doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final busCode = data['busCode'] as String?;
      final stopsList = data['stops'] as List<dynamic>?;  // [{name, eta, …}, ...]

      if (busCode == null || stopsList == null) continue;
      for (var item in stopsList) {
        if (item is Map<String, dynamic>) {
          final stopName = item['name'] as String?;
          final etaRaw   = item['eta'];
          if (stopName == _nearestStopName) {
            final int? eta = (etaRaw is num) ? etaRaw.toInt() : null;
            if (eta != null && eta >= 0 && eta < 5) {
              foundMessage = "🚍 Bus $busCode arriving at $_nearestStopName in $eta minute${eta == 1 ? '' : 's'}!";
              break;
            }
          }
        }
      }
      if (foundMessage != null) break;
    }

    if (mounted && _nearbyBusAlertMessage != foundMessage) {
      setState(() {
        _nearbyBusAlertMessage = foundMessage;
      });

      if (foundMessage != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              backgroundColor: Colors.lightGreen[100],
              content: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange[800]),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      foundMessage!,
                      style: TextStyle(
                        color: Colors.green[800],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),

              duration: Duration(seconds: 5),
              action: SnackBarAction(
                label: 'OK',
                textColor: Colors.green[800],
                onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              ),
            ),
          );
        });
      }
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
10. If there is a recommended bus, at the end of your answer output only this JSON object like this
{ "busCode":"A2","startStop":"HBP","endStop":"DK A","eta":2 }
11. If no buses are departing soon, output null


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
    // _busPositionUpdateTimer?.cancel(); // Cancel timer if used
    _liveBusPositionSubscription?.cancel(); // Cancel listener
    _mapController?.dispose();
    super.dispose();
  }
  List<LatLng>? _calculateSegmentPath(List<LatLng>? fullPath, LatLng? start, LatLng? end) {
    if (fullPath == null || fullPath.isEmpty || start == null || end == null) {
      return null;
    }

    int startIndex = _findNearestPathIndex(fullPath, start);
    int endIndex   = _findNearestPathIndex(fullPath, end);
    if (startIndex == -1 || endIndex == -1) return null;

    if (startIndex <= endIndex) {
      // simple case: straight slice
      return fullPath.sublist(startIndex, endIndex + 1);
    } else {
      // loop-around case: take from startIndex→end, then 0→endIndex
      final segment1 = fullPath.sublist(startIndex);
      final segment2 = fullPath.sublist(0, endIndex + 1);
      return [
        ...segment1,
        ...segment2,
      ];
    }
  }

  int _findNearestPathIndex(List<LatLng> path, LatLng point) {
    double minDistance = double.infinity;
    int nearestIndex = -1;
    for (int i = 0; i < path.length; i++) {
      double distance = Geolocator.distanceBetween(
          point.latitude, point.longitude,
          path[i].latitude, path[i].longitude
      );
      if (distance < minDistance) {
        minDistance = distance;
        nearestIndex = i;
      }
    }
    // Optional: Add a threshold check - if minDistance is too large, maybe the stop isn't truly on the path
    if (minDistance > 500) { // Example threshold: 500 meters
      debugPrint("Stop (${point.latitude}, ${point.longitude}) is > 500m from the nearest path point. Index: $nearestIndex");
      // return -1; // Uncomment if you want to invalidate if too far
    }
    return nearestIndex;
  }

  // --- NEW: Helper to get the smooth path (needs implementation) ---
  // This MUST replicate or access the logic from BusTrackerScreen._generateSmoothPath
  // and know the full stop list for the given bus code.
  // --- IMPLEMENTATION for _getSmoothPathForBus ---
  List<LatLng>? _getSmoothPathForBus(String busCode) {
    if (busCode.isEmpty || _routes.isEmpty || _stopLocations.isEmpty) {
      debugPrint("⚠️ Cannot get smooth path: Missing busCode ('$busCode'), routes (${_routes.length}), or stopLocations (${_stopLocations.length}).");
      return null;
    }
    // Get the route letter (e.g., 'A' from 'A2')
    final routeLetter = busCode[0];
    // Get the list of stop names for this route letter
    final stopNames = _routes[routeLetter];

    if (stopNames == null || stopNames.isEmpty) {
      debugPrint("⚠️ No designated stops found for route letter '$routeLetter'. Cannot generate path for $busCode.");
      return null;
    }

    // Get LatLng for each stop name, filtering out any missing ones
    final stopCoords = stopNames
        .map((name) {
      final loc = _stopLocations[name];
      // if (loc == null) debugPrint("   - Missing location for stop: $name"); // Optional debug
      return loc;
    })
        .whereType<LatLng>() // Filters out nulls if a stop location is missing
        .toList();

    if (stopCoords.length != stopNames.length) {
      debugPrint("⚠️ Mismatch between stop names (${stopNames.length}) and found locations (${stopCoords.length}) for route '$routeLetter'. Some stops might be missing coordinates.");
    }

    if (stopCoords.length < 2) {
      debugPrint("⚠️ Need at least 2 valid stop locations to generate a path for route '$routeLetter'. Found ${stopCoords.length}. Cannot generate path for $busCode.");
      return null; // Cannot create a path with fewer than 2 points
    }

    // Generate the smooth path using the helper function
    List<LatLng> smoothPath = _generateSmoothPath(stopCoords);
    debugPrint("Generated smooth path for $busCode ($routeLetter) with ${smoothPath.length} points from ${stopCoords.length} stops.");
    return smoothPath;
  }
  List<LatLng> _getPointsBetween(LatLng start, LatLng end, int segments) {
    final points = <LatLng>[];
    for (int i = 0; i <= segments; i++) {
      final ratio = i / segments;
      points.add(LatLng(
        start.latitude + (end.latitude - start.latitude) * ratio,
        start.longitude + (end.longitude - start.longitude) * ratio,
      ));
    }
    return points;
  }
  List<LatLng> _generateSmoothPath(List<LatLng> stops, {int segments = 10}) {
    if (stops.length < 2) return stops;
    final path = <LatLng>[];
    for (int i = 0; i < stops.length - 1; i++) {
      final segmentPoints = _getPointsBetween(stops[i], stops[i + 1], segments);
      // Add all points from the segment except the last one,
      // unless it's the very last segment of the whole path.
      path.addAll(segmentPoints.sublist(0, segments));
    }
    // Add the final destination stop explicitly.
    path.add(stops.last);
    return path;
  }

  // --- NEW: Method to update map markers and polylines ---
  void _updateMapMarkersAndPolylines() {
    Set<Marker> markers = {};
    Set<Polyline> polylines = {};

    if (_routeBusCode != null && _routeSegmentPolylinePoints != null && _routeColor != null) {
      // Add Polyline for the segment
      polylines.add(Polyline(
        polylineId: PolylineId('route_segment_$_routeBusCode'),
        points: _routeSegmentPolylinePoints!,
        color: _routeColor!.withOpacity(0.8),
        width: 5,
      ));

      // Add Start Marker
      if (_routeStartStopName != null && _stopLocations.containsKey(_routeStartStopName!)) {
        markers.add(Marker(
          markerId: MarkerId('start_stop_$_routeStartStopName'),
          position: _stopLocations[_routeStartStopName!]!,
          infoWindow: InfoWindow(title: _routeStartStopName!, snippet: "Board Here"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ));
      }

      // Add End Marker
      if (_routeEndStopName != null && _stopLocations.containsKey(_routeEndStopName!)) {
        markers.add(Marker(
          markerId: MarkerId('end_stop_$_routeEndStopName'),
          position: _stopLocations[_routeEndStopName!]!,
          infoWindow: InfoWindow(title: _routeEndStopName!, snippet: "Destination"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ));
      }


      // Add Moving Bus Marker (if position and icon are available)
      if (_routeBusPosition != null && _routeBusIcon != null) {
        // Calculate rotation (needs path segment)
        double rotation = 0;
        if (_routeSegmentPolylinePoints != null && _routeSegmentPolylinePoints!.length >= 2) {
          // Find current segment on the path based on bus position (simplified)
          int busIndex = _findNearestPathIndex(_routeSegmentPolylinePoints!, _routeBusPosition!);
          if (busIndex != -1 && busIndex < _routeSegmentPolylinePoints!.length - 1) {
            LatLng start = _routeSegmentPolylinePoints![busIndex];
            LatLng end = _routeSegmentPolylinePoints![busIndex + 1];
            rotation = Geolocator.bearingBetween(start.latitude, start.longitude, end.latitude, end.longitude);
          }
        }

        markers.add(Marker(
            markerId: MarkerId('bus_marker_$_routeBusCode'),
            position: _routeBusPosition!,
            icon: _routeBusIcon!,
            rotation: rotation,
            flat: true,
            anchor: Offset(0.5, 0.5), // Center anchor for rotation
            zIndex: 2 // Ensure bus is drawn on top
        ));
      }
    }

    // Update the state
    // Note: Check mounting if this is called from async callbacks outside setState scope
    if(mounted){
      setState(() {
        _mapMarkers = markers;
        _mapPolylines = polylines;
      });
    } else {
      _mapMarkers = markers; // Update directly if not mounted (use with caution)
      _mapPolylines = polylines;
    }

  }

  // --- NEW: Method to clear the route display ---
  void _clearRouteDisplay() {
    // _busPositionUpdateTimer?.cancel(); // Cancel timer if used
    // _busPositionUpdateTimer = null;
    setState(() {
      _routeBusCode = null;
      _routeStartStopName = null;
      _routeEndStopName = null;
      _routeFullPolylinePoints = null;
      _routeSegmentPolylinePoints = null;
      _routeBusPosition = null;
      _routeColor = null;
      _routeBusIcon = null;
      _mapMarkers.clear();
      _mapPolylines.clear();
    });
  }

  // --- NEW: Method to zoom map ---
  void _zoomToRoute() {
    if (_routeSegmentPolylinePoints == null || _routeSegmentPolylinePoints!.isEmpty || _mapController == null) {
      return;
    }
    LatLngBounds bounds;
    if (_routeSegmentPolylinePoints!.length == 1) {
      // Handle single point case - maybe zoom to a fixed level?
      bounds = LatLngBounds(
          southwest: _routeSegmentPolylinePoints!.first,
          northeast: _routeSegmentPolylinePoints!.first);
    } else {
      bounds = LatLngBounds(
        southwest: _routeSegmentPolylinePoints!.reduce((value, element) => LatLng(
          min(value.latitude, element.latitude),
          min(value.longitude, element.longitude),
        )),
        northeast: _routeSegmentPolylinePoints!.reduce((value, element) => LatLng(
          max(value.latitude, element.latitude),
          max(value.longitude, element.longitude),
        )),
      );
    }

    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 50.0), // Add padding
    );
  }


  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final raw = _searchResultMessage ?? '';
    final displayMessage = raw.split('```').first.trim();
    return Scaffold(
      backgroundColor: Colors.purple[100],
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 40.0, left: 16.0, right: 16.0), // Added top: 10.0
                  child: Text(
                    'Hello, Intan',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                ),
                SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
                        value: _selectedDestination,
                        decoration: InputDecoration(
                          hintText: 'Search destination',
                          // 2️⃣ move the search icon to the right:
                          suffixIcon: Icon(Icons.search),
                          filled: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        items: _destinations.map((dest) {
                          return DropdownMenuItem(
                            value: dest,
                            child: Text(dest),
                          );
                        }).toList(),
                        onChanged: (dest) async {
                          if (!mounted || dest == null) return;
                          if (!mounted) return;
                          setState(() {
                            _searchResultMessage = "🔄 Fetching live data & recommendation..."; // Updated loading message
                            _clearRouteDisplay();
                          });

                          // Assuming 'towards' indicates destination

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
                            if (aiResponse.contains('No buses departing') ||
                                aiResponse.contains('currently no buses') ||
                                aiResponse.contains('no suitable bus')) {
                              setState(() {
                                _searchResultMessage = aiResponse;
                                _clearRouteDisplay();
                              });
                              return;
                            }
                            if (!mounted) return;
                            bool noRouteFound = aiResponse.contains("No buses departing") ||
                                aiResponse.contains("no suitable bus") || // Add other variations if needed
                                aiResponse.contains("currently no buses");

                            if (noRouteFound) {
                              // Gemini explicitly said no route, so just display its message
                              debugPrint("Gemini reported no suitable route found.");
                              setState(() {
                                _searchResultMessage = aiResponse; // Show Gemini's explanation
                                _clearRouteDisplay(); // Ensure no old route is shown
                              });
                            } else {
                              // 2. A route *might* have been suggested, attempt to parse
                              debugPrint("Attempting to parse route details from Gemini response...");
                              if (aiResponse.trim() == 'null') {
                                // no buses departing
                                setState(() {
                                  _searchResultMessage = "🚫 No buses departing soon. Please check later.";
                                  _clearRouteDisplay();
                                });
                                return;
                              }
// … after you’ve already done the “null” / no-bus short-circuit…

// 1) Extract the JSON blob
                              final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(aiResponse);
                              if (jsonMatch == null) {
                                setState(() {
                                  _searchResultMessage = aiResponse + "\n\n(Could not parse recommendation.)";
                                  _clearRouteDisplay();
                                });
                                return;
                              }

// 2) Decode it
                              final jsonString = jsonMatch.group(0)!;
                              final parsed = jsonDecode(jsonString) as Map<String, dynamic>;

// 3) Pull out your fields directly
                              final busCode   = parsed['busCode'] as String?;
                              final startStop = parsed['startStop'] as String?;
                              final endStop   = parsed['endStop'] as String?;
                              final eta       = parsed['eta'] as int?;

// 4) Validate & update state
                              if (busCode == null || startStop == null || endStop == null || eta == null) {
                                setState(() {
                                  _searchResultMessage = aiResponse + "\n\n(Could not parse recommendation fields.)";
                                  _clearRouteDisplay();
                                });
                              } else {
                                setState(() {
                                  _searchResultMessage        = aiResponse;
                                  _routeBusCode               = busCode;
                                  _routeStartStopName         = startStop;
                                  _routeEndStopName           = endStop;
                                  _routeColor                 = _busColors[busCode];
                                  _routeBusIcon               = _busIcons[busCode];
                                  _routeFullPolylinePoints    = _getSmoothPathForBus(busCode);
                                  _routeSegmentPolylinePoints = _calculateSegmentPath(
                                      _routeFullPolylinePoints,
                                      _stopLocations[startStop],
                                      _stopLocations[endStop]
                                  );
                                  _routeBusPosition           = _liveBusPositions[busCode];
                                  _updateMapMarkersAndPolylines();
                                  _zoomToRoute();
                                });
                              }

                              String? parsedStartStop;
                              String? parsedEndStop;

                              // Keep your RegExp definitions

                            } // End of the 'else' block (where parsing is attempted)

                            // **** END OF CHANGES ****

                          } catch (e, stackTrace) {
                            if (!mounted) return;
                            debugPrint("Error getting live suggestion: $e\n$stackTrace");
                            setState(() {
                              _searchResultMessage = "⚠️ Error getting recommendation: ${e.toString().replaceFirst('Exception: ', '')}";
                              _clearRouteDisplay();
                            });
                          }
                        }, // End of onSubmitted
                      ),
                    ],
                  ),
                ),
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
                        target: _currentPosition ?? const LatLng(5.354803870916983, 100.3023350270162), // Use fallback
                        zoom: 15,
                      ),
                      onMapCreated: (c) {
                        _mapController = c;
                        // If a route was calculated before map loaded, zoom now
                        if (_routeSegmentPolylinePoints != null) {
                          Future.delayed(Duration(milliseconds: 500), _zoomToRoute);
                        }
                      },
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
                      markers: _mapMarkers,
                      polylines: _mapPolylines,
                    ),
                  )
                      : Center(child: CircularProgressIndicator()),
                ),
                SizedBox(height: 30),
                Container(
                  width: double.infinity,
                  // adapt the height as you like (or remove if you want it to size to content)
                  height: MediaQuery.of(context).size.height * 0.85,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                  child: SingleChildScrollView(
                    // wrap in a scroll view so the infographic + list can scroll together
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // —————— GEMINI SUGGESTION CARD ——————
                        if (displayMessage != null && displayMessage.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: Card(
                              color: Colors.purple[50],
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Text(
                                  displayMessage,  // ← safe, never null here
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // —————— OTHER SECTION CARDS ——————
                        ListView(
                          shrinkWrap: true,
                          physics: NeverScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16.0),
                              child: Image.asset(
                                'assets/route_infographic.png',
                                fit: BoxFit.contain,
                                // you can also constrain height/width here
                              ),
                            ),
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