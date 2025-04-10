import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';

class LiveCrowdScreen extends StatefulWidget {
  @override
  _LiveCrowdScreenState createState() => _LiveCrowdScreenState();
}

class _LiveCrowdScreenState extends State<LiveCrowdScreen> {
  late GoogleMapController _controller;
  LatLng? _currentLocation;
  List<Map<String, dynamic>> _busStops = [];
  List<Map<String, dynamic>> _sortedStops = [];

  // Chat-related state
  List<Map<String, String>> _chatHistory = [];
  final TextEditingController _chatController = TextEditingController();

  // For storing the "last approach" results
  List<Map<String, dynamic>> _lastCandidates = [];
  int _lastIndex = 0;
  String _lastApproach = ""; // e.g. "nearest", "lowest", or "fastest"

  @override
  void initState() {
    super.initState();
    _getLocation();
    _loadBusStopsFromFirestore();
  }

  // ------------------------ LOCATION / DATA LOADING ------------------------ //

  Future<void> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
    });
  }

  void _loadBusStopsFromFirestore() async {
    final random = Random();
    final snapshot =
    await FirebaseFirestore.instance.collection('busStops').get();

    final stops = snapshot.docs.map((doc) {
      final data = doc.data();
      final GeoPoint geo = data['location'];
      return {
        'name': data['name'],
        'location': LatLng(geo.latitude, geo.longitude),
        // Simulated live crowd count
        'crowd': random.nextInt(50) + 5,  // 5..54
        'eta': random.nextInt(60) + 1,    // 1..60
      };
    }).toList();

    setState(() {
      _busStops = stops;
      _sortedStops = List.from(stops)..sort((a, b) => b['crowd'].compareTo(a['crowd']));
    });
  }

  // --------------------- GET CANDIDATES BY APPROACH ------------------------ //
  // We filter to within 2km of user location, then sort based on approach type
  List<Map<String, dynamic>> _filterCandidates(String approach) {
    if (_currentLocation == null || _busStops.isEmpty) return [];

    // Filter to stops within 2km
    final filtered = _busStops.where((stop) {
      double distance = Geolocator.distanceBetween(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        stop['location'].latitude,
        stop['location'].longitude,
      );
      return distance < 2000; // 2km threshold
    }).toList();

    // Sort differently depending on approach
    if (approach == "nearest") {
      filtered.sort((a, b) {
        final distA = Geolocator.distanceBetween(
            _currentLocation!.latitude,
            _currentLocation!.longitude,
            a['location'].latitude,
            a['location'].longitude);
        final distB = Geolocator.distanceBetween(
            _currentLocation!.latitude,
            _currentLocation!.longitude,
            b['location'].latitude,
            b['location'].longitude);
        return distA.compareTo(distB);
      });
    } else if (approach == "lowest") {
      filtered.sort((a, b) => a['crowd'].compareTo(b['crowd']));
    } else if (approach == "fastest") {
      filtered.sort((a, b) => a['eta'].compareTo(b['eta']));
    }

    return filtered;
  }

  // --------------------- GENERATE SUGGESTION  ----------------------------- //
  Future<String> _generateAccurateSuggestion(String query) async {
    final normalized = query.toLowerCase();

    // 1. Check for "another suggestion" or "other" or "something else"
    if (normalized.contains("other") ||
        normalized.contains("another") ||
        normalized.contains("something else")) {
      // if we have leftover candidates from the last approach, show the NEXT one
      if (_lastCandidates.isEmpty) {
        return "No previous approach found. Try asking for nearest/lowest crowd/fastest first.";
      }
      _lastIndex++;
      if (_lastIndex >= _lastCandidates.length) {
        return "No more stops left in that list. Sorry!";
      }
      final nextStop = _lastCandidates[_lastIndex];
      return "Next best option is ${nextStop['name']} with ${nextStop['crowd']} people waiting and ETA of ${nextStop['eta']} mins.";
    }

    // 2. Otherwise, parse the approach
    bool wantNearest =
        normalized.contains("nearest") || normalized.contains("closest");
    bool wantLowest = normalized.contains("lowest crowd") ||
        normalized.contains("least crowd") ||
        normalized.contains("less crowd");
    bool wantFastest = normalized.contains("fastest") ||
        normalized.contains("quickest") ||
        normalized.contains("shortest time");

    // fallback approach if none matched
    String approach = "nearest";
    if (wantLowest) approach = "lowest";
    if (wantFastest) approach = "fastest";
    if (wantNearest) approach = "nearest";

    // 3. Filter & sort candidates based on approach
    final candidates = _filterCandidates(approach);

    if (candidates.isEmpty) {
      return "No bus stops are available within 2 km right now, or no data loaded.";
    }

    // store these for future "other suggestion" requests
    _lastCandidates = candidates;
    _lastApproach = approach;
    _lastIndex = 0;

    final top = candidates[_lastIndex];
    // Return the first suggestion from the sorted list
    if (approach == "nearest") {
      return "The nearest bus stop is ${top['name']}, with ${top['crowd']} people waiting and an ETA of ${top['eta']} minutes.";
    } else if (approach == "lowest") {
      return "The bus stop with the lowest crowd is ${top['name']}, at ${top['crowd']} people and ${top['eta']} mins ETA.";
    } else {
      return "The fastest arriving bus stop is ${top['name']}, with an ETA of ${top['eta']} mins and crowd of ${top['crowd']}.";
    }
  }

  // ------------------- WHEN THE USER SENDS A QUERY ------------------------ //
  void _sendUserQuery(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _chatHistory.add({"sender": "user", "message": query});
      _chatController.clear();
    });
    String aiResponse = await _generateAccurateSuggestion(query);
    setState(() {
      _chatHistory.add({"sender": "ai", "message": aiResponse});
    });
  }

  // ------------------- BOTTOM SHEET CHAT UI ------------------------------- //
  void _showChatModal() {
    showModalBottomSheet(
      isScrollControlled: true,
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            builder: (context, scrollController) {
              return Column(
                children: [
                  Container(
                    margin: EdgeInsets.only(top: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    "Chat with Gemini",
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.purple),
                  ),
                  SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _chatHistory.length,
                      itemBuilder: (context, index) {
                        final chat = _chatHistory[index];
                        final isUser = chat["sender"] == "user";
                        return Align(
                          alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: EdgeInsets.symmetric(
                                vertical: 4, horizontal: 8),
                            padding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isUser ? Colors.purple[200] : Colors.grey[300],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              chat["message"] ?? "",
                              style: TextStyle(
                                color: isUser ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: 10),
                  _buildLiveDataVisual(),
                  Padding(
                    padding: EdgeInsets.only(
                        bottom: 10, top: 8, left: 8, right: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            decoration: InputDecoration(
                              hintText: "Ask a question...",
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            onSubmitted: _sendUserQuery,
                          ),
                        ),
                        SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => _sendUserQuery(_chatController.text),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purple),
                          child: Icon(Icons.send, color: Colors.white),
                        )
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // Displays each bus stop's crowd visually
  Widget _buildLiveDataVisual() {
    return Container(
      height: 70,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _busStops.length,
        itemBuilder: (context, index) {
          final stop = _busStops[index];
          double crowd = (stop['crowd'] as int).toDouble();
          return Container(
            width: 90,
            margin: EdgeInsets.symmetric(horizontal: 4),
            padding: EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.purple),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  stop['name'],
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 4),
                LinearProgressIndicator(
                  value: crowd / 50.0, // assume max crowd ~50
                  backgroundColor: Colors.grey[200],
                  color: Colors.purple,
                ),
                SizedBox(height: 4),
                Text("${stop['crowd']} ppl", style: TextStyle(fontSize: 10)),
              ],
            ),
          );
        },
      ),
    );
  }

  // ------------------------- MAIN UI -------------------------------------- //
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Live Crowd"),
        backgroundColor: Colors.purple,
      ),
      body: _currentLocation == null
          ? Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          GoogleMap(
            onMapCreated: (controller) => _controller = controller,
            initialCameraPosition: CameraPosition(
              target: _currentLocation!,
              zoom: 16,
            ),
            markers: _busStops.map((stop) {
              return Marker(
                markerId: MarkerId(stop['name']),
                position: stop['location'],
                infoWindow: InfoWindow(
                  title: stop['name'],
                  snippet:
                  "${stop['crowd']} people waiting\nETA: ${stop['eta']} min",
                ),
              );
            }).toSet(),
            myLocationEnabled: true,
          ),
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black26)],
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: "Search bus stop...",
                  border: InputBorder.none,
                  icon: Icon(Icons.search),
                ),
                onSubmitted: (query) {
                  final match = _busStops.firstWhere(
                        (stop) => stop['name']
                        .toLowerCase()
                        .contains(query.toLowerCase()),
                    orElse: () => {},
                  );
                  if (match.isNotEmpty) {
                    _controller.animateCamera(
                      CameraUpdate.newLatLng(match['location']),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("No matching bus stop found.")),
                    );
                  }
                },
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton.icon(
              icon: Icon(Icons.auto_mode),
              label: Text("Ask AI Assistant"),
              onPressed: _showChatModal,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
            ),
          ),
        ],
      ),
    );
  }
}
