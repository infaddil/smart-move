import 'package:smart_move/screens/bus_tracker.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'dart:math';


class BusDataService {
  final BusTracker _tracker;
  final BusRouteService _routeService;
  final Random _random = Random();

  BusDataService(this._tracker, this._routeService);

  Future<List<Map<String, dynamic>>> getEnhancedBusStops() async {
    // Get basic stops from your existing source
    final stops = await _tracker.getBusStops(); // Adapt based on your bus_tracker.dart

    // Enhance with dynamic data
    return stops.map((stop) async {
      final routes = await _routeService.getRoutesForStop(stop['name']);
      final eta = await _tracker.calculateETA(stop['location']); // Implement this in bus_tracker.dart

      return {
        'name': stop['name'],
        'location': stop['location'],
        'crowd': _random.nextInt(50) + 5, // Your existing random crowd
        'eta': eta ?? _random.nextInt(30) + 1, // Fallback if no ETA
        'routes': routes,
      };
    }).toList();
  }
}