import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class BusTrackerScreen extends StatefulWidget {
  @override
  _BusTrackerScreenState createState() => _BusTrackerScreenState();
}

class _BusTrackerScreenState extends State<BusTrackerScreen> {
  GoogleMapController? _mapController;

  // routeType → list of stop names
  Map<String, List<String>> _routes = {};

  // stop name → geo-coordinate
  Map<String, LatLng> _stopLocations = {};

  // stop name → crowd count
  Map<String, int> _crowdLevels = {};

  // busId → routeType+suffix (e.g. "A1","A2","B1")
  Map<String, String> _busAssignments = {};

  // routeType → display color
  final Map<String, Color> _routeColors = {
    'A': Colors.purple,
    'B': Colors.deepPurple,
    'C': Colors.pink,
  };

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    // 1) Load all routes
    final routeSnap =
    await FirebaseFirestore.instance.collection('route').get();
    for (var doc in routeSnap.docs) {
      _routes[doc.id] = List<String>.from(doc['stops']);
    }

    // 2) Load all stop coordinates
    final stopsSnap =
    await FirebaseFirestore.instance.collection('busStops').get();
    for (var doc in stopsSnap.docs) {
      final gp = doc['geo'] as GeoPoint;
      _stopLocations[doc.id] = LatLng(gp.latitude, gp.longitude);
    }

    // 3) Load crowd levels
    final crowdSnap =
    await FirebaseFirestore.instance.collection('crowd').get();
    for (var doc in crowdSnap.docs) {
      _crowdLevels[doc.id] = (doc['count'] as num).toInt();
    }

    // 4) Randomize bus assignments (3 buses, two share one routeType)
    _assignBuses();

    // 5) Build markers & polylines
    _buildMapElements();

    setState(() {});
  }

  void _assignBuses() {
    final rnd = Random();
    final types = _routes.keys.toList();
    // pick primary type for two buses:
    final primary = types[rnd.nextInt(types.length)];
    types.remove(primary);
    // pick a secondary for the third bus:
    final secondary = types[rnd.nextInt(types.length)];

    _busAssignments = {
      'bus1': '${primary}1',
      'bus2': '${primary}2',
      'bus3': '${secondary}1',
    };
  }

  void _buildMapElements() {
    _markers.clear();
    _polylines.clear();

    _busAssignments.forEach((busId, routeCode) {
      final routeType = routeCode[0]; // 'A','B' or 'C'
      final color = _routeColors[routeType]!;
      final stops = _routes[routeType]!;

      // build polyline
      final coords = stops
          .map((name) => _stopLocations[name])
          .whereType<LatLng>()
          .toList();
      _polylines.add(Polyline(
        polylineId: PolylineId(busId),
        points: coords,
        width: 5,
        color: color,
      ));

      // build markers
      for (var s in stops) {
        final loc = _stopLocations[s];
        if (loc == null) continue;
        _markers.add(Marker(
          markerId: MarkerId('$busId-$s'),
          position: loc,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            _hueFromRoute(routeType),
          ),
          infoWindow: InfoWindow(
            title: s,
            snippet: 'Bus $routeCode · Crowd: ${_crowdLevels[s] ?? 0}',
          ),
        ));
      }
    });
  }

  double _hueFromRoute(String r) {
    switch (r) {
      case 'A':
        return BitmapDescriptor.hueViolet;
      case 'B':
        return BitmapDescriptor.hueMagenta;
      case 'C':
        return BitmapDescriptor.hueRose;
      default:
        return BitmapDescriptor.hueAzure;
    }
  }

  @override
  Widget build(BuildContext context) {
    // center map on first stop
    final firstLoc = _stopLocations.values.isNotEmpty
        ? _stopLocations.values.first
        : LatLng(0, 0);

    return Scaffold(
      appBar: AppBar(
        title: Text('Bus Tracker'),
        backgroundColor: Colors.purple[600],
      ),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: firstLoc, zoom: 13),
        markers: _markers,
        polylines: _polylines,
        onMapCreated: (c) => _mapController = c,
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
      ),
    );
  }
}
