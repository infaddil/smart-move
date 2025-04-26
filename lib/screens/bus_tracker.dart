import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';

class BusTrackerScreen extends StatefulWidget {
  @override
  _BusTrackerScreenState createState() => _BusTrackerScreenState();
}

class _BusTrackerScreenState extends State<BusTrackerScreen> {
  GoogleMapController? _mapController;
  final _svc = BusRouteService();
  BitmapDescriptor? _busIcon;
  Map<String, List<LatLng>> _busPaths = {};
  final Map<String, Timer> _busTimers = {};

  Map<String,int>   _busIndex     = {};             // which stop we’re at
  Map<String,LatLng> _busPositions = {};            // actual marker pos

  Map<String, List<String>> _routes = {};
  Map<String, LatLng> _stopLocations = {};

  // stop name → crowd count
  Map<String, int> _crowdLevels = {};
  Map<String, String> _busAssignments = {};
  final Map<String, List<Map<String,dynamic>>> _busSegments = {};

  final Map<String, Color> _routeColors = {
    'A': Colors.purple,
    'B': Colors.green,
    'C': Colors.lightBlueAccent,
  };

  final Map<String, Color> _busColors = {
    'A1': Colors.purple,
    'A2': Colors.deepOrangeAccent,
    'B1': Colors.green,
    'B2': Colors.limeAccent,
    'C1': Colors.pink,
    'C2': Colors.blue,
  };

  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  Map<String,BitmapDescriptor> _busIcons = {};
  @override
  void initState() {
    super.initState();

    // 1) Load bus icons
    _busColors.keys.forEach((code) {
      BitmapDescriptor.fromAssetImage(
        ImageConfiguration(size: Size(48, 48)),
        'assets/bus_$code.png',
      ).then((d) {
        if (mounted) {
          setState(() => _busIcons[code] = d);
        }
      }).catchError((e) {
        debugPrint('❌ Failed to load assets/bus_$code.png → $e');
        if (mounted) {
          setState(() => _busIcons[code] = BitmapDescriptor.defaultMarkerWithHue(
              HSVColor.fromColor(_busColors[code]!).hue
          ));
        }
      });
    });

    // 2) Load all data and initialize
    _initData().then((_) async {
      await _initializeAllBuses();
      await _buildMapElements();

      // Verify everything is ready before starting animations
      if (mounted &&
          _busAssignments.isNotEmpty &&
          _busPaths.isNotEmpty &&
          _busPaths.values.every((path) => path.isNotEmpty)) {
        setState(() {
          _startBusAnimations();
        });
      } else {
        debugPrint('⚠️ Not starting animations - missing required data');
      }
    });
  }

  @override
  void dispose() {
    _stopBusAnimations();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _initializeAllBuses() async {
    final types = ['A','B','C'];
    final rnd = Random();
    final primary = types.removeAt(rnd.nextInt(3));
    final secondary = types[rnd.nextInt(2)];
    _busAssignments['bus1'] = primary + '1';
    _busAssignments['bus2'] = primary + '2';
    _busAssignments['bus3'] = secondary + '1';

    // Track stops that are already assigned to other buses
    final occupiedStops = <String>[];

    for (var busId in _busAssignments.keys) {
      final code = _busAssignments[busId]!;
      final letter = code[0];
      final data = await _svc.getAssignments(
        letter,
        capacity: 60,
        occupiedStops: occupiedStops,
      );

      _busSegments[busId] = data['current']!;

      // Add these stops to the occupied list
      for (var stop in data['current']!) {
        occupiedStops.add(stop['name'] as String);
      }

      setState(() {});
    }
  }
  void _onBusTapped(String busId) {
    final code    = _busAssignments[busId]!;
    final letter  = code[0];
    final stops   = _routes[letter]!;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        builder: (ctx, sc) => Column(
          children: [
            SizedBox(height: 12),
            Text('Bus $code', style: TextStyle(fontSize:18, fontWeight:FontWeight.bold)),
            Text('${stops.first} → ${stops.last}'),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: stops.length,
                itemBuilder: (_, i) {
                  return ListTile(
                    leading: i==0
                        ? Icon(Icons.trip_origin)
                        : Icon(Icons.circle, size: 12),
                    title: Text(stops[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _startBusAnimations() {
    _stopBusAnimations();

    _busAssignments.forEach((busId, code) {
      final path = _busPaths[busId];
      if (path == null || path.isEmpty) {
        debugPrint('⚠️ Cannot animate bus $busId - path is empty');
        return;
      }

      // Initialize position to first stop
      _busPositions[busId] = path[0];
      _busIndex[busId] = 0;

      _busTimers[busId] = Timer.periodic(Duration(seconds: 3), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }

        try {
          final currentIdx = _busIndex[busId] ?? 0;
          final nextIdx = (currentIdx + 1) % path.length;

          setState(() {
            _busPositions[busId] = path[nextIdx];
            _busIndex[busId] = nextIdx;
          });
        } catch (e) {
          debugPrint('⚠️ Animation error for bus $busId: $e');
          t.cancel();
        }
      });
    });
  }
  void _stopBusAnimations() {
    _busTimers.forEach((busId, timer) {
      timer.cancel();
    });
    _busTimers.clear();
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
       final geo = doc['location'] as GeoPoint;
       final name = doc['name'] as String;           // 🔑 use the name
       _stopLocations[name] = LatLng(geo.latitude, geo.longitude);
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
    await _buildMapElements();

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

  Future<void> _buildMapElements() async {
    _markers.clear();
    _polylines.clear();
    _busPaths.clear();

    _busAssignments.forEach((busId, routeCode) {
      final letter = routeCode[0];
      final color = _busColors[routeCode]!;
      final stops = _routes[letter]!;

      // 1) Build the animation path:
      final coords = stops
          .map((name) => _stopLocations[name])
          .whereType<LatLng>()
          .toList();

      if (coords.isEmpty) {
        debugPrint('⚠️ No coordinates for bus $busId ($routeCode)');
        return;
      }

      _busPaths[busId] = coords;
      // ... rest of the method
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

    // Add stop markers
    _busSegments.forEach((busId, stops) {
      if (stops == null) return;
      final code = _busAssignments[busId]!;
      if (stops == null) return;
      final hue = HSVColor.fromColor(_busColors[code]!).hue;

      for (var s in stops) {
        if (s['location'] == null) continue;
        markers.add(Marker(
          markerId: MarkerId('$busId-stop-${s['name']}'),
          position: s['location'] as LatLng,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: s['name'],
            snippet: 'Bus $code · Crowd: ${s['crowd']}, ETA: ${s['eta']} mins',
          ),
        ));
      }
    });

    // Add moving bus markers
    _busPositions.forEach((busId, pos) {
      if (pos == null) return;
      final code = _busAssignments[busId]!;
      if (pos == null) return;
      final icon = _busIcons[code];
      if (pos == null) return;
      if (icon != null) {
        markers.add(Marker(
          markerId: MarkerId('$busId-bus'),
          position: pos,
          icon: icon,
          flat: true, // Makes the marker flat against the map
          rotation: _getBusRotation(busId), // Optional: rotate bus in direction of travel
          onTap: () => _onBusTapped(busId),
        ));
      }
    });

    return markers;
  }

// Helper method to calculate bus direction (optional)
  double _getBusRotation(String busId) {
    final path = _busPaths[busId] ?? [];
    final currentIdx = path.indexOf(_busPositions[busId]!);
    if (currentIdx <= 0 || currentIdx >= path.length - 1) return 0;

    final prev = path[currentIdx - 1];
    final next = path[currentIdx + 1];
    return Geolocator.bearingBetween(
      prev.latitude, prev.longitude,
      next.latitude, next.longitude,
    );
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
        color: polyColor.withOpacity(0.5),
      ));
    });
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final loaded =
          _busAssignments.isNotEmpty
          && _busSegments.length == _busAssignments.length;
    if (!loaded) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Bus Tracker'),
          backgroundColor: Colors.purple[600],
        ),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final firstBusId = _busAssignments.keys.first;
        final firstStops  = _busSegments[firstBusId]!;
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
