import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

class BusTrackerScreen extends StatefulWidget {
  @override
  _BusTrackerScreenState createState() => _BusTrackerScreenState();
}
class BusAnimationService with ChangeNotifier {
  static final BusAnimationService _instance = BusAnimationService._();
  factory BusAnimationService() => _instance;
  BusAnimationService._();

  final _timers = <String, Timer>{};
  final positions = <String, LatLng>{};
  final progress  = <String, double>{};
  // …other state: _busIndex, _busPaths, assignments, etc.

  Future<void> initOnce() async {
    if (_timers.isNotEmpty) return; // already started
    // 1) fetch routes & stops
    // 2) compute segments
    // 3) build paths
    // 4) start Timer.periodic for each bus, updating positions & progress…
    //    when a route reaches progress>=1, reset or stop that one
    notifyListeners();
  }
}


class _BusTrackerScreenState extends State<BusTrackerScreen> with AutomaticKeepAliveClientMixin {
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;
  GoogleMapController? _mapController;
  final Map<String, double> _busVelocities = {};
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
  bool get wantKeepAlive => true;
  void initState() {
    print(">>> initState Called for BusTrackerScreen");
    super.initState();
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
        if (mounted) { // <<< ADD Check >>>
          setState(() => _busIcons[code] = BitmapDescriptor.defaultMarkerWithHue(
              HSVColor.fromColor(_busColors[code]!).hue
          ));
        }
      });
    });
    if (_busTimers.isEmpty) {
      print(">>> Running FULL Initialization in initState"); // Should run only ONCE per state creation

      // --- THIS BLOCK MUST NOT BE COMMENTED OUT ---
      _initData().then((_) async {
        await _initializeAllBuses();
        await _buildMapElements();

        // Verify everything is ready before starting animations
        if (mounted &&
            _busAssignments.isNotEmpty &&
            _busPaths.isNotEmpty &&
            _busPaths.values.every((path) => path.isNotEmpty)) {
          setState(() {
            // Call _startBusAnimations AFTER data is ready
            _startBusAnimations();
          });
        } else {
          if (!mounted) { // Optional: log if not mounted here
            debugPrint("initState.then: Not starting animations - widget unmounted.");
          } else {
            debugPrint('⚠️ Not starting animations - missing required data after init');
          }
        }
      });
      // --- END OF BLOCK TO KEEP ---

    } else {
      print(">>> Skipping full init in initState - Reusing State");
      // If state is preserved (timers exist), do nothing extra here.
      // The build method will use the existing state.
    }


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
  Future<List<Map<String, dynamic>>> getBusRoutesForStop(String stopName) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('busRoutes')
        .where('stops', arrayContains: stopName)
        .get();

    return snapshot.docs.map((doc) => doc.data()).toList();
  }

  final Map<String, double> _busProgress = {};

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
      final data = await BusRouteService().getAssignments(
        letter,
        capacity: 60,
        occupiedStops: occupiedStops,
      );
      _busSegments[busId] = data['current']!;
      _busSegments[busId] = data['current']!;

      // Add these stops to the occupied list
      for (var stop in data['current']!) {
        occupiedStops.add(stop['name'] as String);
      }

      if (mounted) { // Check before setState
        setState(() {});
      }
    }
  }

  /// Calculate points between two coordinates
  List<LatLng> _getPointsBetween(LatLng start, LatLng end, int segments) {
    final points = <LatLng>[];
    for (int i = 0; i <= segments; i++) {
      final ratio = i / segments;
      points.add(LatLng(
        start.latitude + (end.latitude - start.latitude) * ratio,
        start.longitude + (end.longitude - start.longitude) * ratio,
      ));
    }
    return points;
  }

  /// Generate a smooth path with intermediate points between all stops
  List<LatLng> _generateSmoothPath(List<LatLng> stops, {int segments = 10}) {
    if (stops.length < 2) return stops;

    final path = <LatLng>[];
    for (int i = 0; i < stops.length - 1; i++) {
      final segment = _getPointsBetween(stops[i], stops[i+1], segments);
      path.addAll(segment);
    }
    return path;
  }
  void _onBusTapped(String busId) {
    final code = _busAssignments[busId]!;
    final letter = code[0];
    final stops = _routes[letter]!;
    final currentProgress = _busProgress[busId] ?? 0.0;
    final path = _busPaths[busId] ?? [];
    final segmentIndex = (currentProgress * (path.length - 1)).floor();
    final segmentProgress = (currentProgress * (path.length - 1)) - segmentIndex;

    // Get which stops are actually being serviced
    final servicedStops = _busSegments[busId]?.map((s) => s['name'] as String).toList() ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        builder: (ctx, sc) => Column(
          children: [
            SizedBox(height: 12),
            Text('Bus $code', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('${stops.first} → ${stops.last}'),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: stops.length,
                itemBuilder: (_, i) {
                  final isServiced = servicedStops.contains(stops[i]);
                  final isCurrent = i == segmentIndex ||
                      (i == segmentIndex + 1 && segmentProgress > 0.5);
                  final isPassed = i < segmentIndex ||
                      (i == segmentIndex && segmentProgress > 0.5);

                  return Column(
                    children: [
                      // Timeline connector (except for first item)
                      if (i > 0)
                        Container(
                          height: 20,
                          width: 2,
                          color: isPassed
                              ? _busColors[code]!.withOpacity(isServiced ? 0.8 : 0.3)
                              : Colors.grey[300],
                          margin: EdgeInsets.only(left: 11),
                        ),
                      // Stop item
                      ListTile(
                        leading: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isCurrent
                                ? _busColors[code]!
                                : isServiced
                                ? _busColors[code]!.withOpacity(isPassed ? 0.8 : 0.5)
                                : Colors.grey[300],
                            border: Border.all(
                              color: _busColors[code]!,
                              width: isServiced ? 2 : 1,
                            ),
                          ),
                          child: i == 0
                              ? Icon(Icons.trip_origin, size: 12, color: Colors.white)
                              : null,
                        ),
                        title: Text(
                          stops[i],
                          style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            color: isServiced ? Colors.black : Colors.grey,
                          ),
                        ),
                        subtitle: isCurrent
                            ? Text(
                          segmentProgress > 0.5 && i < stops.length - 1
                              ? 'Heading to ${stops[i+1]}'
                              : 'At ${stops[i]}',
                          style: TextStyle(color: _busColors[code]!),
                        )
                            : null,
                      ),
                      // Bus position indicator
                      if (isCurrent)
                        Padding(
                          padding: EdgeInsets.only(left: 24),
                          child: Row(
                            children: [
                              Icon(
                                Icons.directions_bus,
                                color: _busColors[code]!,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: i == segmentIndex
                                      ? segmentProgress
                                      : 1 - segmentProgress,
                                  backgroundColor: Colors.grey[200],
                                  valueColor: AlwaysStoppedAnimation(_busColors[code]!),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  final Map<String, double> _busSpeeds = {
    'A1': 1.0,
    'A2': 1.3,
    'B1': 1.4,
    'B2': 1.6,
    'C1': 1.9,
    'C2': 0.9,
  };

  // In _BusTrackerScreenState

  void _startBusAnimations() {
    _busAssignments.forEach((busId, code) {
      if (_busTimers.containsKey(busId) && _busTimers[busId]!.isActive) {
        // (Existing logic to handle already active timers)
        if (_busPositions[busId] == null && _busPaths[busId] != null && _busPaths[busId]!.isNotEmpty) {
          final path = _busPaths[busId]!;
          final progress = _busProgress[busId] ?? 0.0;
          final segmentLength = path.length > 1 ? path.length - 1 : 1;
          final segmentIndex = (progress * segmentLength).floor().clamp(0, path.length - 2);
          final segmentProgress = (progress * segmentLength) - segmentIndex;
          final start = path[segmentIndex];
          final end = path[segmentIndex + 1];
          _busPositions[busId] = LatLng(
            start.latitude + (end.latitude - start.latitude) * segmentProgress,
            start.longitude + (end.longitude - start.longitude) * segmentProgress,
          );
          _busIndex[busId] = segmentIndex;
        }
        return; // Skip starting a new timer
      }

      final path = _busPaths[busId];
      if (path == null || path.isEmpty) {
        debugPrint("Path is null or empty for $busId ($code). Skipping animation start.");
        return;
      }

      // --- Initialize state if it doesn't exist ---
      if (!_busPositions.containsKey(busId)) {
        _busPositions[busId] = path[0];
      }
      if (!_busIndex.containsKey(busId)) {
        _busIndex[busId] = 0;
      }
      if (!_busProgress.containsKey(busId)) {
        _busProgress[busId] = 0.0;
      }
      // --- End Initialization Check ---

      final speedModifier = _busSpeeds[code] ?? 1.0;

      final averageSpeedMetersPerSecond = 6.0 * speedModifier;
      // --- END SPEED ADJUSTMENT ---

      // --- Calculate total path distance once ---
      double totalPathDistance = 0;
      if (path.length > 1) {
        for (int i = 0; i < path.length - 1; i++) {
          totalPathDistance += Geolocator.distanceBetween(
              path[i].latitude, path[i].longitude,
              path[i+1].latitude, path[i+1].longitude
          );
        }
      }
      // --- End Path Distance Calculation ---


      _busTimers[busId]?.cancel(); // Cancel any previous inactive timer entry

      _busTimers[busId] = Timer.periodic(Duration(milliseconds: 800), (t) async { // Your 800ms interval
        if (!mounted) {
          t.cancel();
          _busTimers.remove(busId);
          return;
        }

        try {
          final currentPath = _busPaths[busId]; // Re-fetch in case it changes? Unlikely here.
          if (currentPath == null || currentPath.isEmpty) {
            debugPrint("Path became null or empty for $busId in timer. Stopping timer.");
            t.cancel();
            _busTimers.remove(busId);
            return;
          }

          final currentProgress = _busProgress[busId] ?? 0.0;
          final segmentLength = currentPath.length > 1 ? currentPath.length - 1 : 1;

          // --- CORRECTED Distance Increment Calculation ---
          // Use the timer interval (0.8 seconds), NOT t.tick
          double estimatedDistanceIncrement = averageSpeedMetersPerSecond * 0.8; // 0.8 seconds = 800ms
          // --- END CORRECTION ---

          // Calculate progress increment based on distance
          double progressIncrement = 0.0;
          if (totalPathDistance > 0) {
            progressIncrement = estimatedDistanceIncrement / totalPathDistance;
          } else {
            // Handle zero distance path - maybe advance slowly?
            progressIncrement = 0.0005; // Fallback small increment
          }

          double newProgress = currentProgress + progressIncrement;

          if (newProgress >= 1.0) {
            newProgress = 0.0; // Reset progress or handle route completion
          }

          // Calculate position based on new progress
          final segmentIndex = (newProgress * segmentLength).floor().clamp(0, currentPath.length - 2);
          final segmentProgress = (newProgress * segmentLength) - segmentIndex;

          final start = currentPath[segmentIndex];
          final end = currentPath[segmentIndex + 1];

          final currentPos = LatLng(
            start.latitude + (end.latitude - start.latitude) * segmentProgress,
            start.longitude + (end.longitude - start.longitude) * segmentProgress,
          );

          // --- REDUCED FIRESTORE UPDATE ---
          // Update roughly every 8 seconds (10 ticks * 800ms interval)
          // Also check if progress actually changed to avoid unnecessary writes on reset/pause
          if (t.tick % 10 == 0 && newProgress != currentProgress) {
            final String routeLetter = code[0];
            final Map<String, int> etaMap = {};
            final List<String> stopNames = _routes[routeLetter] ?? [];

            // --- ETA Calculation Logic START (Keep your existing logic here) ---
            if (stopNames.isNotEmpty && _stopLocations.isNotEmpty) {
              int currentStopIndexOnRoute = -1;
              double cumulativeLength = 0;
              for(int i=0; i < currentPath.length -1; ++i){
                cumulativeLength += Geolocator.distanceBetween(currentPath[i].latitude, currentPath[i].longitude, currentPath[i+1].latitude, currentPath[i+1].longitude);
                if(i >= segmentIndex) break;
              }
              double targetLength = cumulativeLength + (Geolocator.distanceBetween(start.latitude, start.longitude, end.latitude, end.longitude) * segmentProgress);

              double lengthAlongOriginalStops = 0;
              List<LatLng> originalStopCoords = stopNames.map((name) => _stopLocations[name]).whereType<LatLng>().toList();

              for(int i=0; i < originalStopCoords.length -1; ++i){
                double stopSegmentLength = Geolocator.distanceBetween(originalStopCoords[i].latitude, originalStopCoords[i].longitude, originalStopCoords[i+1].latitude, originalStopCoords[i+1].longitude);
                if(lengthAlongOriginalStops + stopSegmentLength >= targetLength || i == originalStopCoords.length - 2){
                  currentStopIndexOnRoute = i;
                  break;
                }
                lengthAlongOriginalStops += stopSegmentLength;
              }

              for (int i = 0; i < stopNames.length; i++) {
                final stopName = stopNames[i];
                final stopLoc = _stopLocations[stopName];
                if (stopLoc != null && i > currentStopIndexOnRoute) {
                  double distanceToStop = 0;
                  if(i == currentStopIndexOnRoute + 1 && currentStopIndexOnRoute < originalStopCoords.length -1) {
                    distanceToStop += Geolocator.distanceBetween(currentPos.latitude, currentPos.longitude, originalStopCoords[i].latitude, originalStopCoords[i].longitude);
                  } else if (i > currentStopIndexOnRoute + 1 && currentStopIndexOnRoute < originalStopCoords.length -1) {
                    distanceToStop += Geolocator.distanceBetween(currentPos.latitude, currentPos.longitude, originalStopCoords[currentStopIndexOnRoute+1].latitude, originalStopCoords[currentStopIndexOnRoute+1].longitude);
                    for(int j = currentStopIndexOnRoute + 1; j < i; ++j){
                      if (j < originalStopCoords.length - 1) {
                        distanceToStop += Geolocator.distanceBetween(originalStopCoords[j].latitude, originalStopCoords[j].longitude, originalStopCoords[j+1].latitude, originalStopCoords[j+1].longitude);
                      }
                    }
                  }
                  if (distanceToStop > 0 && averageSpeedMetersPerSecond > 0) {
                    final etaSeconds = distanceToStop / averageSpeedMetersPerSecond;
                    etaMap[stopName] = (etaSeconds / 60).round();
                  } else {
                    etaMap[stopName] = 0;
                  }
                } else if (i <= currentStopIndexOnRoute) {
                  etaMap[stopName] = -1;
                }
              }
            }
            // --- ETA Calculation Logic END ---
            final assignedStops = _busSegments[busId] ?? [];
            final List<Map<String, dynamic>> stopsData = assignedStops.map((s) {
              final name = s['name'] as String;
              return {
                'name':  name,
                'eta':   etaMap[name]        ?? -1,
                'crowd': _crowdLevels[name]  ??  0,
                // if you also want to store the stop’s geo‐point, add:
                'location': GeoPoint(
                (s['location'] as LatLng).latitude,
                (s['location'] as LatLng).longitude,)

              };
            }).toList();

            final Map<String, dynamic> busActivityData = {
              'busCode': code,
              // --- >>> USE NEW STRUCTURED LIST <<< ---
              'stops': stopsData,
              // --- >>> REMOVE OLD etaMap <<< ---
              // 'etaMap': etaMap, // Removed, data is now in 'stops' list
              'currentPosition': GeoPoint(currentPos.latitude, currentPos.longitude),
              'isActive': (newProgress < 1.0 && newProgress > 0.0),
              'lastUpdated': FieldValue.serverTimestamp(),
            };

            // Perform Firestore update
            // Using try-catch specifically for the Firestore operation might be useful
            try {
              await FirebaseFirestore.instance
                  .collection('busActivity')
                  .doc(busId)
                  .set(busActivityData, SetOptions(merge: true));
              // debugPrint('Firestore updated for $busId at tick ${t.tick}'); // Optional log
            } catch (fsError) {
              debugPrint('Firestore update failed for $busId: $fsError');
              // Decide how to handle Firestore errors (e.g., retry later?)
            }
          }

          if (_busPositions[busId] != currentPos || _busProgress[busId] != newProgress || _busIndex[busId] != segmentIndex) {
            if (mounted) {
              setState(() {
                _busPositions[busId] = currentPos;
                _busProgress[busId] = newProgress;
                _busIndex[busId] = segmentIndex;
              });
            } else {
              t.cancel();
              _busTimers.remove(busId);
            }
          }

        } catch (e, stackTrace) {
          debugPrint('Error in timer calculation/setState for bus $busId: $e\n$stackTrace');
          // Consider stopping the timer on calculation errors
          // t.cancel();
          // _busTimers.remove(busId);
        }
      });
    });

    // Initial build might be needed if state was just created or assignments changed
    if (mounted) {
      setState(() {});
    }
  }
  void _moveBusAlongPath(String busId, List<LatLng> path, Timer timer) {
    if (!mounted) {
      timer.cancel();
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
      timer.cancel();
    }
  }

  double _getBusRotation(String busId) {
    final path = _busPaths[busId] ?? [];
    final currentPos = _busPositions[busId];
    if (currentPos == null || path.length < 2) return 0;

    final currentIdx = _busIndex[busId] ?? 0;
    if (currentIdx >= path.length - 1) return 0;

    final nextIdx = (currentIdx + 1) % path.length;
    return Geolocator.bearingBetween(
      path[currentIdx].latitude, path[currentIdx].longitude,
      path[nextIdx].latitude, path[nextIdx].longitude,
    );
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

    FirebaseFirestore.instance
        .collection('busStops')
        .snapshots()
        .listen((snapshot) {
      for (var doc in snapshot.docs) {
        final name     = doc['name']  as String;
        final crowdVal = (doc['crowd'] as num?)?.toInt() ?? 0;
        _crowdLevels[name] = crowdVal;
      }
    });

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

    _busAssignments.addAll({
      'bus1': '${primary}1',
      'bus2': '${primary}2',
      'bus3': '${secondary}1',
    });
  }

  Future<void> _buildMapElements() async {
    _markers.clear();
    _polylines.clear();
    _busPaths.clear();

    _busAssignments.forEach((busId, routeCode) {
      final letter = routeCode[0];
      final color = _busColors[routeCode]!;
      final stops = _routes[letter]!;

      // Get stop coordinates
      final stopCoords = stops
          .map((name) => _stopLocations[name])
          .whereType<LatLng>()
          .toList();

      if (stopCoords.isEmpty) {
        debugPrint('⚠️ No coordinates for bus $busId ($routeCode)');
        return;
      }

      // Generate smooth path with intermediate points
      _busPaths[busId] = _generateSmoothPath(stopCoords);

      // Draw the polyline
      _polylines.add(Polyline(
        polylineId: PolylineId(busId),
        points: stopCoords, // Use original stops for the polyline
        width: 5,
        color: color.withOpacity(0.6),
      ));

      // Draw the static stop markers
      final hue = HSVColor.fromColor(color).hue;
      for (var s in stops) {
        final loc = _stopLocations[s];
        if (loc == null) {
          debugPrint('⚠️ Missing location for stop "$s" on route $routeCode');
          continue;
        }
        _markers.add(Marker(
          markerId: MarkerId('$busId-stop-$s'),
          position: loc,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          infoWindow: InfoWindow(
            title: s,
            snippet: 'Bus $routeCode',
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

  Future<void> _updateBusStops() async {
    final batch = FirebaseFirestore.instance.batch();

    _crowdLevels.forEach((stopName, crowd) {
      final stopRef = FirebaseFirestore.instance.collection('busStops').doc(stopName);
      batch.update(stopRef, {
        'crowd': crowd,
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();
  }
  Set<Marker> get _allMarkers {
    final markers = <Marker>{};

    // Add stop markers with connection lines
    _busSegments.forEach((busId, stops) {
      if (stops == null) return;
      final code = _busAssignments[busId]!;
      final hue = HSVColor.fromColor(_busColors[code]!).hue;

      for (var s in stops) {
        if (s['location'] == null) continue;

        // Add connection line to next stop if available
        final nextStop = stops.length > stops.indexOf(s) + 1
            ? stops[stops.indexOf(s) + 1]
            : null;

        if (nextStop != null && nextStop['location'] != null) {
          markers.add(Marker(
            markerId: MarkerId('$busId-connector-${s['name']}'),
            position: LatLng(
              (s['location'].latitude + nextStop['location'].latitude) / 2,
              (s['location'].longitude + nextStop['location'].longitude) / 2,
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(hue),
            visible: false, // Hidden marker just for the line
          ));
        }

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

    // Add moving bus markers with exact positioning
    _busPositions.forEach((busId, pos) {
      if (pos == null) return;
      final code = _busAssignments[busId]!;
      final icon = _busIcons[code];
      if (icon != null) {
        final progress = _busProgress[busId] ?? 0.0;

        markers.add(Marker(
          markerId: MarkerId('$busId-bus'),
          position: pos,
          icon: icon,
          flat: true,
          rotation: _getBusRotation(busId),
          infoWindow: InfoWindow(
            title: 'Bus $code',
            snippet: 'Progress: ${(progress * 100).toStringAsFixed(1)}%',
          ),
          onTap: () => _onBusTapped(busId),
        ));
      }
    });

    return markers;
  }

  Set<Polyline> get _allPolylines {
    final lines = <Polyline>{};
    _busAssignments.forEach((busId, code) {
      final color = _busColors[code]!;
      final letter = code[0];
      final stops = _routes[letter]!;

      final pts = stops
          .map((name) => _stopLocations[name])
          .whereType<LatLng>()
          .toList();

      if (pts.isEmpty) return;

      // Main route line
      lines.add(Polyline(
        polylineId: PolylineId(busId),
        points: pts,
        width: 5,
        color: color.withOpacity(0.3),
      ));

      // Progress line (shows completed portion)
      final progress = _busProgress[busId] ?? 0.0;
      if (progress > 0) {
        final progressIndex = (progress * (pts.length - 1)).toInt();
        final progressPoints = pts.sublist(0, progressIndex + 1);

        // Add current position to the progress line
        if (_busPositions[busId] != null) {
          progressPoints.add(_busPositions[busId]!);
        }

        lines.add(Polyline(
          polylineId: PolylineId('$busId-progress'),
          points: progressPoints,
          width: 5,
          color: color,
        ));
      }
    });
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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