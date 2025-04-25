import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';

class BusTrackerScreen extends StatefulWidget {
  @override
  _BusTrackerScreenState createState() => _BusTrackerScreenState();
}

class _BusTrackerScreenState extends State<BusTrackerScreen> {
  GoogleMapController? _mapController;
  final _svc = BusRouteService();

  // routeType → list of stop names
  Map<String, List<String>> _routes = {};

  // stop name → geo-coordinate
  Map<String, LatLng> _stopLocations = {};

  // stop name → crowd count
  Map<String, int> _crowdLevels = {};

  // busId → routeType+suffix (e.g. "A1","A2","B1")
  Map<String, String> _busAssignments = {};

  // e.g. { 'bus1': [ {name, location, crowd, eta}, … ], … }
  final Map<String, List<Map<String,dynamic>>> _busSegments = {};

  final Map<String, Color> _routeColors = {
    'A': Colors.purple,
    'B': Colors.green,
    'C': Colors.lightBlueAccent,
  };

  final Map<String, Color> _busColors = {
    'A1': Colors.purple,
    'A2': Colors.deepPurple,
    'B1': Colors.green,
    'B2': Colors.lightGreen,
    'C1': Colors.pink,
    'C2': Colors.pinkAccent,
  };

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    _initData();
    _initializeAllBuses();
  }

  Future<void> _initializeAllBuses() async {
    // 1) Randomize which two share the same letter:
    final types = ['A','B','C'];
    final rnd = Random();
    final primary = types.removeAt(rnd.nextInt(3));           // e.g. 'A'
    final secondary = types[rnd.nextInt(2)];                  // pick from remaining
    _busAssignments['bus1'] = primary + '1';
    _busAssignments['bus2'] = primary + '2';
    _busAssignments['bus3'] = secondary + '1';


    // 2) For each bus, fetch its “current” stop‐segment
    for (var busId in _busAssignments.keys) {
      final code = _busAssignments[busId]!;
      final letter = code[0];
      final data = await _svc.getAssignments(letter, capacity: 60);
      // data['current'] is List<Map{name, location, crowd, eta}>
      _busSegments[busId] = data['current']!;
    }

    setState(() {});
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
      final gp = doc['location'] as GeoPoint;
      _stopLocations[doc.id] = LatLng(gp.latitude, gp.longitude);
    }

    // 3) Load crowd levels
    final crowdSnap =
    await FirebaseFirestore.instance.collection('crowd').get();
    for (var doc in crowdSnap.docs) {
      _crowdLevels[doc.id] = (doc['crowd'] as num).toInt();
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
  Set<Marker> get _allMarkers {
    final markers = <Marker>{};
    _busSegments.forEach((busId, stops) {
      final hue = _hueFromRoute(_busAssignments[busId]![0]);
      for (var s in stops) {
        markers.add(Marker(
          markerId: MarkerId('$busId-${s['name']}'),
          position: s['location'] as LatLng,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: s['name'],
            snippet:
            'Bus ${_busAssignments[busId]} · Crowd: ${s['crowd']}, ETA: ${s['eta']} mins',
          ),
        ));
      }
    });
    return markers;
  }

  Set<Polyline> get _allPolylines {
    final lines = <Polyline>{};
    _busAssignments.forEach((busId, code) {
      final code     = _busAssignments[busId]!;
      final hue  = HSVColor.fromColor(_busColors[code]!).hue;
      final polyColor= _busColors[code]!;
      final letter    = code[0];
      final stops     = _routes[letter]!;       // full route array from Firestore

      final pts = stops
          .map((name) => _stopLocations[name])
          .whereType<LatLng>()
          .toList();

      lines.add(Polyline(
        polylineId: PolylineId(busId),
        points: pts,
        width: 5,
        color: polyColor,        // full-route color
      ));
    });
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _busSegments.length == _busAssignments.length;
    if (!loaded) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Bus Tracker'),
          backgroundColor: Colors.purple[600],
        ),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final firstStops = _busSegments['bus1']!;
    final center = firstStops.isNotEmpty
        ? firstStops.first['location'] as LatLng
        : LatLng (5.354792742851638, 100.30181627359067);

    return Scaffold(
      appBar: AppBar(
        title: Text('Bus Tracker'),
        backgroundColor: Colors.purple[600],
      ),
      body: GoogleMap(
        onMapCreated: (ctrl) {
          _mapController = ctrl;
          ctrl.moveCamera(CameraUpdate.newLatLngZoom(center, 14));
        },
        initialCameraPosition: CameraPosition(target: center, zoom: 13),
        markers: _allMarkers,
        polylines: _allPolylines,
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
      ),
    );
  }
}
