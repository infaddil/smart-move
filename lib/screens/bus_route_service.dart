// lib/services/bus_route_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class BusRouteService {
  final _db = FirebaseFirestore.instance;
  final _rnd = Random();

  /// Fetch the ordered list of all designated stops for this busType
  Future<List<String>> _getDesignatedStops(String busType) async {
    final doc = await _db.collection('route').doc(busType).get();
    return List<String>.from(doc.data()?['stops'] ?? []);
  }

  /// Load crowd+ETA data for a given list of stops
  Future<List<Map<String,dynamic>>> _loadStopsData(List<String> names) async {
    if (names.isEmpty) return [];
    final snap = await _db
        .collection('busStops')
        .where('name', whereIn: names)
        .get();

    return snap.docs.map((d) {
      final geo = d['location'] as GeoPoint;
      return {
        'name': d['name'],
        'location': LatLng(geo.latitude, geo.longitude),
        // simulate or replace with real crowd:
        'crowd': _rnd.nextInt(50)+5,
        'eta'  : _rnd.nextInt(60)+1,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _computeSegment(
        List<Map<String, dynamic>> stopsData,
        int capacity,
    ) {
      // Sort descending by crowd
      stopsData.sort((a, b) =>
        (b['crowd'] as int).compareTo(a['crowd'] as int)
      );

      final segment = <Map<String, dynamic>>[];
      var total = 0;

      for (final s in stopsData) {
        final crowd = s['crowd'] as int;
        if (total + crowd <= capacity) {
          segment.add(s);
          total += crowd;
        }
      }
     return segment;
    }

  /// Public API: returns [currentBusStops, nextBusStops]
  Future<Map<String,List<Map<String,dynamic>>>> getAssignments(
      String busType, {
        int capacity = 60,
      }) async {
    final designated = await _getDesignatedStops(busType);
    final allData   = await _loadStopsData(designated);
    final current   = _computeSegment(allData, capacity);

    // remaining = those designated stops not in current
    final remNames  = designated.where((n)=>
    !current.any((c)=> c['name']==n)
    ).toList();
    final remData   = allData.where((d)=> remNames.contains(d['name'])).toList();
    final nextSeg   = _computeSegment(remData, capacity);

    return {
      'current': current,
      'next'   : nextSeg,
    };
  }
}
