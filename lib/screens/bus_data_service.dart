import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';

class BusDataService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Random _random = Random();

  Future<List<Map<String, dynamic>>> getEnhancedBusStops() async {
    // 1. Get basic stops
    final stopsSnapshot = await _firestore.collection('busStops').get();
    final crowdSnap   = await _firestore.collection('crowd').get();
    final crowd = { for (var d in crowdSnap.docs) d.id : (d['crowd'] as num).toInt() };
    // 2. Enhance with dynamic data
    return await Future.wait(stopsSnapshot.docs.map((doc) async {
      final stopData = doc.data();
      final data = doc.data();

      // Get dynamic routes from 'route' collection
      final routes = await _getRoutesForStop(stopData['name']);

      return {
        'name': stopData['name'],
        'location': stopData['location'],
        'crowd'   : crowd[data['name']] ?? 0,
        'eta'     : await _calculateETA(data['location']) ?? Random().nextInt(30)+1,
        'routes': routes,
      };
    }));
    }

  Future<List<String>> _getRoutesForStop(String stopName) async {
    final routeSnapshot = await _firestore
        .collection('route')
        .where('stops', arrayContains: stopName)
        .get();

    return routeSnapshot.docs.map((doc) => doc.id).toList();
  }

  Future<int?> _calculateETA(GeoPoint location) async {
    // We'll implement this after fixing bus_tracker.dart
    return null;
  }
}