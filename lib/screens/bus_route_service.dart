import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/foundation.dart';

class BusRouteService {
  static final BusRouteService _instance = BusRouteService._internal();
  factory BusRouteService() => _instance;
  BusRouteService._internal();
  final _db = FirebaseFirestore.instance;
  final _rnd = Random();
  Future<List<Map<String, dynamic>>> getAllStopsWithCrowd() async {

    final stopsSnap  = await _db.collection('busStops').get();
    if (stopsSnap.docs.isEmpty) {
      return []; // Return empty if no base stops defined
    }
    final activitySnap = await _db.collection('busActivity').get();
    final Map<String, int> liveCrowdMap = {};
    for (var doc in activitySnap.docs) {
      final data = doc.data();
      // Ensure 'stops' field exists and is a list
      final stopsListRaw = data['stops'] as List?;
      if (stopsListRaw != null) {
        for (var item in stopsListRaw) {
          // Ensure each item is a map and has name/crowd
          if (item is Map) {
            final name = item['name'] as String?;
            final crowdRaw = item['crowd']; // Crowd from busActivity
            final int crowdValue = (crowdRaw is num)
                ? crowdRaw.toInt()
                : 0; // Default to 0 if missing/invalid

            if (name != null) {
              // Store the crowd level found in busActivity for this stop name
              // If a stop is in multiple activity docs (shouldn't happen often),
              // this will overwrite with the last one found. Consider merging logic if needed.
              liveCrowdMap[name] = crowdValue;
            }
          }
        }
      }
    }

    final List<Map<String, dynamic>> mergedStops = [];
    for (var doc in stopsSnap.docs) {
      final stopData = doc.data();
      final name = stopData['name'] as String?;
      final geo = stopData['location'] as GeoPoint?;

      if (name != null && geo != null) {
        // Get crowd from live map if available, otherwise use default
        final int currentCrowd = liveCrowdMap[name] ?? 10; // Use live crowd or default to 10

        mergedStops.add({
          'name': name,
          'location': LatLng(geo.latitude, geo.longitude),
          'crowd': currentCrowd, // Use the resolved crowd value
          // Keep ETA logic as needed (random for now, or fetch from a source)
          'eta': _rnd.nextInt(30) + 1,
        });
      }

    }
    debugPrint("Merged stops count: ${mergedStops.length}");
    return mergedStops;
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

    if (designated.isEmpty) {
      // Handle case where the route definition is missing or empty
      print("⚠️ Warning: No designated stops found for route type '$busType' in Firestore.");
      return {'current': [], 'next': []};
    }
    final allData = await getAllStopsWithCrowd();
    final myStops = allData.where((s) => designated.contains(s['name'])).toList();
    final currentSegmentUnordered = _computeSegment(
      myStops,
      capacity,
      excludedStops: occupiedStops,
    );
    List<Map<String, dynamic>> currentSegmentOrdered = [];
    if (currentSegmentUnordered.isNotEmpty) {
      // Create a quick lookup map for the data of the selected stops
      final selectedStopDataMap = {
        for (var stopData in currentSegmentUnordered) stopData['name'] as String: stopData
      };

      // Iterate through the *original designated order* and pick out the selected stops
      for (String stopName in designated) {
        if (selectedStopDataMap.containsKey(stopName)) {
          // If this stop was selected, add its data to the ordered list
          currentSegmentOrdered.add(selectedStopDataMap[stopName]!);
        }
      }
      debugPrint("Route $busType: Selected ${currentSegmentUnordered.length} stops. Reordered based on designated path: ${currentSegmentOrdered.map((s)=>s['name']).join(', ')}");

    } else {
      debugPrint("Route $busType: No stops selected by _computeSegment.");
    }
    final currentStopNames = currentSegmentOrdered.map((s) => s['name'] as String).toSet();

    // Filter 'designated' to find stops NOT in the current segment
    final remainingNames = designated.where((name) => !currentStopNames.contains(name)).toList();

    // Get data for the remaining stops
    final remainingData = myStops.where((d) => remainingNames.contains(d['name'])).toList();

    // Compute the 'next' segment (you could reorder this too using the same logic if required)
    final nextSegmentUnordered = _computeSegment(remainingData, capacity); // No need to exclude stops here

    // --- Optional: Reorder the 'next' segment ---
    List<Map<String, dynamic>> nextSegmentOrdered = [];
    if (nextSegmentUnordered.isNotEmpty) {
      final nextStopDataMap = {
        for (var stopData in nextSegmentUnordered) stopData['name'] as String: stopData
      };
      // Use the 'remainingNames' which are already in designated order
      for (String stopName in remainingNames) {
        if (nextStopDataMap.containsKey(stopName)) {
          nextSegmentOrdered.add(nextStopDataMap[stopName]!);
        }
      }
    }
    // --- End Optional Reordering ---

    // 7. Return the results with the correctly ordered 'current' segment
    return {'current': currentSegmentOrdered, 'next': nextSegmentOrdered}; // Use ordered lists
  }
}
