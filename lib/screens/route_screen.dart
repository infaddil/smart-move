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

class RouteScreen extends StatefulWidget {
  @override
  _RouteScreenState createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  late GoogleMapController _mapController;
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;

  List<Map<String, dynamic>> _pickupStops = [];
  String? _currentPickupMessage;

  bool _hasStartedNavigation = false;

  // Real-time location tracking.
  LatLng? _currentLocation;
  StreamSubscription<Position>? _positionStreamSubscription;

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadBusStopsFromFirestore();
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

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
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

  void _loadBusStopsFromFirestore() async {
    // 1) grab the driver's routeType unconditionally
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    final busType = userDoc.data()!['routeType'] as String;

    // 2) compute pickups for exactly that routeType (A, B or C)
    final assignments = await BusRouteService()
        .getAssignments(busType, capacity: 60);

    setState(() {
      _pickupStops = assignments['current']!;
    });
  }

  void _moveToNextStop() {
    if (_pickupStops.isNotEmpty) {
      final currentStop = _pickupStops.first;
      // Animate to the current stop.
      _mapController.animateCamera(
        CameraUpdate.newLatLngZoom(currentStop['location'], 17),
      );

      setState(() {
        _currentPickupMessage = "Picking up at: ${currentStop['name']}";
        _pickupStops.removeAt(0); // Remove only once!
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("All pickups completed")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build markers ONLY for the stops in _pickupStops.
    Set<Marker> markers = {};
    for (int i = 0; i < _pickupStops.length; i++) {
      final stop = _pickupStops[i];
      // The currently "active" stop is the first in the list (green).
      BitmapDescriptor markerIcon = (i == 0 && _hasStartedNavigation)
          ? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)
          : BitmapDescriptor.defaultMarker; // default (red)

      markers.add(
        Marker(
          markerId: MarkerId(stop['name']),
          position: stop['location'],
          icon: markerIcon,
          infoWindow: InfoWindow(
            title: stop['name'],
            snippet: "Crowd: ${stop['crowd']}, ETA: ${stop['eta']} mins",
          ),
        ),
      );
    }

    // Add a marker for the user's current location, if available.
    if (_currentLocation != null) {
      markers.add(
        Marker(
          markerId: MarkerId("userLocation"),
          position: _currentLocation!,
          infoWindow: InfoWindow(title: "You are here"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        ),
      );
    }
    Set<Polyline> polylines = (_hasStartedNavigation && _pickupStops.isNotEmpty)
        ? {
      Polyline(
        polylineId: PolylineId("pickupRoute"),
        color: Colors.purple,
        width: 5,
        points: _pickupStops.map((s) => s['location'] as LatLng).toList(),
      )
    }
        : <Polyline>{};

    return Scaffold(
      appBar: AppBar(
        title: Text('Pickup Route'),
        backgroundColor: Colors.purple,
      ),
      body: Stack(
        children: [
          // The map itself:
          GoogleMap(
            onMapCreated: (controller) {
              _mapController = controller;
              // Move camera to the first eligible pickup stop (if any)
              if (!_hasStartedNavigation && _pickupStops.isNotEmpty) {
                _mapController.moveCamera(
                  CameraUpdate.newLatLngZoom(_pickupStops.first['location'], 16),
                );
              }
            },
            initialCameraPosition: CameraPosition(
              target: _pickupStops.isNotEmpty
                  ? _pickupStops.first['location']
                  : LatLng(5.356, 100.303), // fallback coordinate
              zoom: 16,
            ),
            markers: markers,
            polylines: polylines,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
          ),

          // New Top Banner: Shows the "Picking up at: ..." message.
          if (_hasStartedNavigation && _currentPickupMessage != null)
            Positioned(
              top: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 10, horizontal: 15),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _currentPickupMessage!,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // Existing Bottom UI: Current Stop information.
          if (_hasStartedNavigation)
            Positioned(
              left: 20,
              right: 20,
              bottom: 80,
              child: Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: _pickupStops.isNotEmpty
                      ? Text(
                    "Next Stop: ${_pickupStops.first['name']} (Crowd: ${_pickupStops.first['crowd']})",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                      : Text(
                    "All pickups completed",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: !_hasStartedNavigation
          ? FloatingActionButton.extended(
        onPressed: () {
          if (_pickupStops.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:
                Text("No eligible pickup stops available"),
              ),
            );
            return;
          }
          setState(() {
            _hasStartedNavigation = true;
          });
          _startLocationUpdates();
          _mapController.animateCamera(
            CameraUpdate.newLatLngZoom(
              _pickupStops.first['location'],
              17,
            ),
          );
        },
        label: Text("Start Navigation"),
        icon: Icon(Icons.navigation),
        backgroundColor: Colors.purple,
      )
          : FloatingActionButton.extended(
        onPressed: _pickupStops.isNotEmpty ? _moveToNextStop : null,
        label:
        Text(_pickupStops.isNotEmpty ? "Next Stop" : "Done"),
        icon: Icon(Icons.directions_bus),
        backgroundColor: Colors.purple,
      ),
    );
  }
}
