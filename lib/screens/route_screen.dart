import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});
  @override
  _RouteScreenState createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  late GoogleMapController _mapController;
  User? _currentUser;
  String? _userRole;
  LatLng?    _initialPosition;
  String?    _routeInitialName;
  String?    _routeTerminalName;
  String? _driverRouteType;
  String? _assignedBusCode;
  List<Map<String, dynamic>> _assignedPickupStops = [];
  Map<String, LatLng> _allStopLocations = {};
  bool _isLoading = true; // Flag to show loading indicator
  int _originalStopCount = 0;

  List<Map<String, dynamic>> _pickupStops = [];
  String? _currentPickupMessage;

  bool _hasStartedNavigation = false;

  // Real-time location tracking.
  LatLng? _currentLocation;
  StreamSubscription<Position>? _positionStreamSubscription;
  final Map<String, String> _routeTypeStartStops = const {
    'A': 'Aman Damai',
    'B': 'Padang Kawad',
    'C': 'Padang Kawad',
  };
  final Map<String, String> _routeTypeEndStops = const {
    'A': 'Harapan',
    'B': 'Aman Damai',
    'C': 'Aman Damai',
  };

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) {
      _loadDriverRouteAndAssignment(); // Recommended
    } else {
      // Handle case where user is not logged in at init
      setState(() => _isLoading = false);
    }

    _loadBusStopsFromFirestore();

    FirebaseAuth.instance.authStateChanges().listen((user) {
      // Make sure the logic inside the listener is also null-safe
      if (user != null && user.uid != _currentUser?.uid) {
        setState(() {
          _currentUser = user;
          _isLoading = true;
          _assignedPickupStops.clear();
          _pickupStops.clear(); // Clear both lists just in case
        });
        _loadDriverRouteAndAssignment(); // Reload data for new user
      } else if (user == null) {
        setState(() {
          _currentUser = null;
          _isLoading = false;
          _assignedPickupStops.clear();
          _pickupStops.clear(); // Clear both lists
        });
      }
    });

  }
  Future<void> _fetchAllStopLocations() async {
    try {
      final stopsSnap = await FirebaseFirestore.instance.collection('busStops').get();
      final locations = <String, LatLng>{};
      for (var doc in stopsSnap.docs) {
        final data = doc.data();
        final name = data['name'] as String?;
        final geo = data['location'] as GeoPoint?;
        if (name != null && geo != null) {
          locations[name] = LatLng(geo.latitude, geo.longitude);
        }
      }
      if (mounted) {
        setState(() {
          _allStopLocations = locations;
        });
      }
    } catch (e) {
      debugPrint("Error fetching all stop locations: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error loading stop locations: ${e.toString()}")),
        );
      }
    }
  }
  Future<void> _loadDriverRouteAndAssignment() async {
    setState(() {
      _isLoading = true;
    });

    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    final busActivityId = userDoc.data()!['busActivityId'] as String;

    final activityDoc = await FirebaseFirestore.instance
        .collection('busActivity')
        .doc(busActivityId)
        .get();
    if (!activityDoc.exists) {
      setState(() {
        _assignedPickupStops = [];
        _originalStopCount   = 0;
        _isLoading           = false;
      });
      return;
    }

    final rawStops = activityDoc.data()!['stops'] as List<dynamic>;
    final stops = rawStops.map((e) {
      final m  = e as Map<String, dynamic>;
      final gp = m['location'] as GeoPoint;
      return {
        'name':     m['name']  as String,
        'crowd':    (m['crowd'] as num).toInt(),
        'eta':      (m['eta']   as num).toInt(),
        'location': LatLng(gp.latitude, gp.longitude),
      };
    }).toList();

    setState(() {
      _assignedPickupStops = stops;
      _originalStopCount   = stops.length;
      _isLoading           = false;
    });
  }
  Future<bool> _checkAndRequestLocationPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location services are disabled. Please enable them.')));
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location permissions are denied.')));
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location permissions are permanently denied. Cannot track location.')));
      return false;
    }
    return true; // Permissions granted
  }

  void _startNavigation() {
    if (_assignedPickupStops.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar( // Use const
          content: Text("No pickup stops assigned for this route activity."),
        ),
      );
      return;
    }
    if (!mounted) return;

    setState(() {
      _hasStartedNavigation = true;
      // Set initial message for the *first* assigned pickup stop
      _currentPickupMessage = "Picking up at: ${_assignedPickupStops.first['name']}";
    });

    _startLocationUpdates(); // Start tracking driver's location

    // Animate camera to the first pickup stop
    _mapController?.animateCamera( // Use null-aware call
      CameraUpdate.newLatLngZoom(
        _assignedPickupStops.first['location'],
        17,
      ),
    );
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

  Future<void> _checkLocationPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permissions are permanently denied.');
    }
  }

  // Start streaming location updates.
  void _startLocationUpdates() async {
    try {
      await _checkLocationPermissions();
      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10, // updates every 10 meters
        ),
      ).listen((Position position) {
        final newPosition = LatLng(position.latitude, position.longitude);
        setState(() {
          _currentLocation = newPosition;
        });
        // When in navigation mode, animate the camera to follow the user's location.
        if (_hasStartedNavigation && _mapController != null) {
          _mapController.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: newPosition, zoom: 17),
            ),
          );
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: ${e.toString()}")),
      );
    }
  }

  Future<void> _loadBusStopsFromFirestore() async {
    // 1) find the user's routeType
    final userSnap = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    final busType = userSnap.data()!['routeType'] as String;

    // 2) query exactly the busActivity doc for *this* driver
    final query = await FirebaseFirestore.instance
        .collection('busActivity')
        .where('driverId', isEqualTo: _currentUser!.uid)
        .limit(1)
        .get();
    if (query.docs.isEmpty) {
      // no assignment yet!
      return;
    }
    final busDoc = query.docs.first.data();

    // 3) pull out the raw stops array
    List<Map<String, dynamic>> stops =
    (busDoc['stops'] as List).map((raw) {
      final gp = raw['location'] as GeoPoint;
      return {
        'name':     raw['name']   as String,
        'crowd':    raw['crowd']  as int,
        'eta':      raw['eta']    as int,
        'location': LatLng(gp.latitude, gp.longitude),
      };
    }).toList();

    // 4) define each route's “start” + “end”
    final initials = {
      'A': 'Aman Damai',
      'B': 'Padang Kawad',
      'C': 'Padang Kawad',
    };
    final terminals = {
      'A': 'Harapan',
      'B': 'Aman Damai',
      'C': 'Aman Damai',
    };
    _routeInitialName  = initials[busType];
    _routeTerminalName = terminals[busType];

    // 5) rotate so we start from the initial
    final startIdx = stops.indexWhere((s) => s['name']==_routeInitialName);
    if (startIdx>0) {
      stops = [
        ...stops.sublist(startIdx),
        ...stops.sublist(0, startIdx),
      ];
    }

    // 6) truncate so we end at the terminal
    final endIdx = stops.indexWhere((s) => s['name']==_routeTerminalName);
    if (endIdx>=0) {
      stops = stops.sublist(0, endIdx+1);
    }

    setState(() {
      _pickupStops        = stops;
      _initialPosition    = stops.first['location'] as LatLng;
    });
  }

  Future<void> _moveToNextStop() async {
    if (!mounted) return;

    // 1) If there are no stops at all, bail:
    if (_assignedPickupStops.isEmpty) {
      return;
    }

    // 2) Complete the current (first) stop
    final currentStop = _assignedPickupStops.first;
    debugPrint("Completed pickup at: ${currentStop['name']}");

    // 3) Remove it
    setState(() {
      _assignedPickupStops.removeAt(0);
    });

    // 4) If there are more stops, show the next:
    if (_assignedPickupStops.isNotEmpty) {
      final next = _assignedPickupStops.first;
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(next['location'], 17),
      );
      setState(() {
        _currentPickupMessage = "Picking up at: ${next['name']}";
      });
    }
    // 5) Otherwise, we just finished the last one → award!
    else {
      setState(() {
        _currentPickupMessage = "All pickups completed!";
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("All pickups completed!")),
      );

      // **THIS** is where we actually give the points:
      await _awardUserPoints(_originalStopCount);
    }
  }

  Future<void> _awardUserPoints(int stopsCount) async {
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid);

    // read current
    final snap = await userRef.get();
    final current = (snap.data()?['points'] ?? 0) as int;
    final earned  = stopsCount * 10;

    // update
    await userRef.update({'points': current + earned});

    // optional feedback
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("You earned $earned points! Total: ${current + earned}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Pickup Route - Loading...'),
          backgroundColor: Colors.purple,
        ),
        body: const Center(child: CircularProgressIndicator()), // Use const
      );
    }

    // --- Build Markers ---
    final Set<Marker> markers = {};

    // Marker for the fixed route start point
    if (_initialPosition  != null && _routeInitialName != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('route-start'), // Use const
          position: _initialPosition !,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(title: 'Route Start: $_routeInitialName'),
        ),
      );
    }
    // Marker for the fixed route end point (Optional but helpful)
    if (_routeTerminalName != null && _allStopLocations.containsKey(_routeTerminalName)) {
      markers.add(
        Marker(
          markerId: MarkerId('route-end-$_routeTerminalName'),
          position: _allStopLocations[_routeTerminalName]!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
          infoWindow: InfoWindow(title: 'Route End: $_routeTerminalName'),
        ),
      );
    }

    // Markers for the ASSIGNED PICKUP stops
    for (int i = 0; i < _assignedPickupStops.length; i++) {
      final stop = _assignedPickupStops[i];
      final stopName = stop['name'] as String;
      final stopLocation = stop['location'] as LatLng;

      // Highlight the *next* pickup stop in green during navigation
      final bool isNextStop = _hasStartedNavigation && i == 0;
      final markerIcon = isNextStop
          ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)
          : BitmapDescriptor.defaultMarker; // Default (red) for other assigned stops

      markers.add(
        Marker(
          markerId: MarkerId('pickup-stop-$stopName'),
          position: stopLocation,
          icon: markerIcon,
          infoWindow: InfoWindow(
            title: stopName,
            snippet: 'Crowd: ${stop['crowd']}',
          ),
        ),
      );
    }

    // Marker for the driver's current location (if available)
    if (_currentLocation != null) {
      markers.add(
        Marker(
          markerId: const MarkerId("userLocation"), // Use const
          position: _currentLocation!,
          infoWindow: const InfoWindow(title: "You are here"), // Use const
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          flat: true, // Make driver icon flat
          // rotation: _currentBearing, // Add bearing if you calculate it
        ),
      );
    }

    // --- Build Polylines ---
    final Set<Polyline> polylines = {};

    // Draw polyline ONLY between the assigned pickup stops during navigation
    if (_hasStartedNavigation && _assignedPickupStops.isNotEmpty) {
      // Create points list including current location if desired for smoother start
      List<LatLng> pickupPoints = [];
      if (_currentLocation != null) {
        pickupPoints.add(_currentLocation!); // Start polyline from current location
      }
      pickupPoints.addAll(_assignedPickupStops.map((s) => s['location'] as LatLng));

      if (pickupPoints.length >= 2) { // Need at least 2 points for a line
        polylines.add(
          Polyline(
            polylineId: const PolylineId("pickupRoute"), // Use const
            color: Colors.deepOrange, // Different color for pickup path
            width: 5,
            points: pickupPoints,
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.purple[100],
        elevation: 0,
        toolbarHeight: 80,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.black),
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        title: Text(
            _hasStartedNavigation
                ? (_assignedBusCode != null
                ? 'Driving: $_assignedBusCode'
                : 'Navigation Started'
            )
                : 'Route: $_driverRouteType'
        ),
      ),

      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) {
              _mapController = controller;
              // Set initial camera AFTER map is created
              if (_initialPosition  != null) {
                controller.moveCamera(CameraUpdate.newLatLngZoom(_initialPosition !, 15));
              }
            },
            // Use the fixed start position if available, otherwise fallback
            initialCameraPosition: CameraPosition(
              target: _initialPosition  ?? const LatLng(5.356, 100.303), // Fallback USM coords
              zoom: 15,
            ),
            markers: markers,
            polylines: polylines,
            myLocationEnabled: false, // Disable default blue dot (using custom marker)
            myLocationButtonEnabled: true, // Keep the button to center on location
            zoomControlsEnabled: true, // Optional: enable zoom controls
          ),

          // Top Banner for current pickup instruction
          if (_hasStartedNavigation && _currentPickupMessage != null)
            Positioned(
              top: 10, // Adjusted position
              left: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12), // Use const
                decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8), // Slightly less opaque
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [ // Add subtle shadow
                      BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                    ]
                ),
                child: Text(
                  _currentPickupMessage!,
                  style: const TextStyle( // Use const
                    color: Colors.white,
                    fontSize: 16, // Slightly larger
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // (Optional) Bottom Info Panel - can show next stop or status
          if (_hasStartedNavigation)
            Positioned(
              left: 10,
              right: 10,
              bottom: 80, // Adjust position to make space for FAB
              child: Container(
                padding: const EdgeInsets.all(12), // Use const
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95), // More opaque
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [ // Add subtle shadow
                      BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, -1)),
                    ]
                ),
                child: Center(
                  child: Text(
                    _assignedPickupStops.isNotEmpty
                        ? "Next: ${_assignedPickupStops.first['name']} (Crowd: ${_assignedPickupStops.first['crowd']})"
                        : "Route Completed!",
                    style: const TextStyle( // Use const
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat, // Center the FAB
      floatingActionButton: !_hasStartedNavigation
          ? FloatingActionButton.extended(
        onPressed: _startNavigation, // Use dedicated function
        label: const Text("Start Navigation"), // Use const
        icon: const Icon(Icons.navigation_outlined), // Use const & outlined icon
        backgroundColor: Colors.green[700], // Different color for Start
      )
          : FloatingActionButton.extended(
        // Disable button if no more stops
        onPressed: _assignedPickupStops.isNotEmpty ? _moveToNextStop : null,
        label: Text(_assignedPickupStops.isNotEmpty ? "Arrived at Next Stop" : "Finish Route"),
        icon: Icon(_assignedPickupStops.isNotEmpty ? Icons.arrow_forward : Icons.check_circle_outline),
        backgroundColor: _assignedPickupStops.isNotEmpty ? Colors.purple : Colors.grey, // Grey out when done
      ),
    );
  }
}
