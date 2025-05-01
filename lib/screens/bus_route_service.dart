// lib/services/bus_route_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class BusRouteService {
  static final BusRouteService _instance = BusRouteService._internal();
  factory BusRouteService() => _instance;
  BusRouteService._internal();
  final _db = FirebaseFirestore.instance;
  final _rnd = Random();
  List<Map<String, dynamic>>? _allStopsCache;
  Future<List<Map<String, dynamic>>> getAllStopsWithCrowd() async {
    if (_allStopsCache != null) return _allStopsCache!;

    // fetch every stop name & location
    final snap = await _db.collection('busStops').get();
    _allStopsCache = snap.docs.map((d) {
      final data = d.data();
      final name = data['name'] as String;
      final geo  = data['location'] as GeoPoint;
      return {
        'name': name,
        'location': LatLng(geo.latitude, geo.longitude),
        // Generate crowd between 10 and 22 (inclusive)
        // _rnd.nextInt(13) generates 0-12. Adding 10 gives 10-22.
        'crowd': 10 + _rnd.nextInt(13), // MODIFIED LINE
        // you can keep ETA random or plug in your real logic
        'eta': _rnd.nextInt(30) + 1,
      };
    }).toList();

    return _allStopsCache!;
  }

  /// Fetch the ordered list of all designated stops for this busType
  Future<List<String>> _getDesignatedStops(String busType) async {
    final doc = await _db.collection('route').doc(busType).get();
    return List<String>.from(doc.data()?['stops'] ?? []);
  }

  Future<List<Map<String,dynamic>>> _loadStopsData(List<String> names) async {
    if (names.isEmpty) return [];

    // 1) Load the geo‐points for the stops you care about
    final stopsSnap = await _db
        .collection('busStops')
        .where('name', whereIn: names)
        .get();

    // 2) Pull in every busActivity doc and flatten out its per-stop crowds
    final actSnap = await _db.collection('busActivity').get();
    final Map<String,int> crowdMap = {};
    for (var doc in actSnap.docs) {
      final rawStops = doc.data()['stops'] as List<dynamic>;
      for (var s in rawStops) {
        final m = s as Map<String, dynamic>;
        final stopName = m['name'] as String;
        final stopCrowd = (m['crowd'] as num?)?.toInt() ?? 0;
        crowdMap[stopName] = stopCrowd;
      }
    }

    // 3) Merge geo + crowd + (your ETA logic)
    return stopsSnap.docs.map((d) {
      final data = d.data();
      final name = data['name'] as String;
      final geo  = data['location'] as GeoPoint;
      return {
        'name'    : name,
        'location': LatLng(geo.latitude, geo.longitude),
        'crowd'   : crowdMap[name] ?? 0,
        // you can keep simulating ETA or plug in real logic here:
        'eta'     : _rnd.nextInt(30) + 1,
      };
    }).toList();
  }

  // In bus_route_service.dart

  List<Map<String, dynamic>> _computeSegment(
      List<Map<String, dynamic>> stopsData,
      int capacity, {
        List<String>? excludedStops,
      }) {

    // --- ADDED FILTERING STEP ---
    final validStops = stopsData.where((stop) {
      final crowd = stop['crowd'] as int? ?? 0;
      final name = stop['name'] as String?;
      // Ensure stop is not excluded AND crowd is within range
      final isExcluded = excludedStops?.contains(name) ?? false;
      final isInRange = crowd >= 10 && crowd <= 22;
      return !isExcluded && isInRange;
    }).toList();
    // --- END ADDED FILTERING STEP ---

    // Sort the VALID stops by crowd (descending)
    validStops.sort((a, b) => (b['crowd'] as int).compareTo(a['crowd'] as int));

    var total = 0;
    final seg = <Map<String, dynamic>>[];
    for (var s in validStops) { // Iterate through the filtered & sorted list
      final c = s['crowd'] as int;
      if (total + c <= capacity) { // Still ensures total doesn't exceed 60
        seg.add(s);
        total += c;
      }
      // Optional: Break early if the next stop would definitely exceed capacity
      // This can slightly improve efficiency if lists are very long.
       else if (c > 0) {
          if (capacity - total < c) break;
       }
    }
    return seg;
  }

  /// Public API: returns [currentBusStops, nextBusStops]
  Future<Map<String,List<Map<String,dynamic>>>> getAssignments(
      String busType, {
        int capacity = 60,
        List<String>? occupiedStops, // Add this parameter
      }) async {
    final doc = await _db.collection('route').doc(busType).get();
    final designated = List<String>.from(doc.data()?['stops'] ?? []);

    // get the same crowd‐enhanced list you built above
    final allData = await getAllStopsWithCrowd();

    // filter down to just this route’s stops
    final myStops = allData.where((s) => designated.contains(s['name'])).toList();

    // now do your segment logic exactly as before
    final current = _computeSegment(myStops, capacity, excludedStops: occupiedStops);
    final remNames = designated.where((n) => !current.any((c) => c['name'] == n)).toList();
    final remData  = myStops.where((d) => remNames.contains(d['name'])).toList();
    final nextSeg  = _computeSegment(remData, capacity);

    return { 'current': current, 'next': nextSeg };
  }
}
