import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';

class BusDataService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Random _random = Random();

  Future<List<Map<String, dynamic>>> getEnhancedBusStops() async {
    // 1. Get basic stops
    final stopsSnapshot = await _firestore.collection('busStops').get();

    // 2. Enhance with dynamic data
    return await Future.wait(stopsSnapshot.docs.map((doc) async {
      final stopData = doc.data();

      // Get dynamic routes from 'route' collection
      final routes = await _getRoutesForStop(stopData['name']);

      // Calculate ETA (we'll implement this separately)
      final eta = await _calculateETA(stopData['location']);

      return {
        'name': stopData['name'],
        'location': stopData['location'],
        'crowd': _random.nextInt(50) + 5,
        'eta': eta ?? _random.nextInt(30) + 1, // Fallback
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