import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/screens/bus_data_service.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class LiveCrowdScreen extends StatefulWidget {
  final LatLng? initialLocation;
  final Map<String, dynamic>? busTrackerData;
  LiveCrowdScreen({this.initialLocation, this.busTrackerData});

  @override
  _LiveCrowdScreenState createState() => _LiveCrowdScreenState();
}

class _LiveCrowdScreenState extends State<LiveCrowdScreen> {
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;
  late GoogleMapController _controller;
  LatLng? _currentLocation;
  List<Map<String, dynamic>> _busStops = [];
  List<Map<String, dynamic>> _sortedStops = [];
  final BusDataService _busDataService = BusDataService();
  Map<String, List<Map<String, dynamic>>> _activeBusSegments = {};
  Map<String, String> _busAssignments = {};

  List<Map<String, String>> _chatHistory = [];
  final TextEditingController _chatController = TextEditingController();

  List<String> _lastCandidates = [];
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialLocation != null) {
      _currentLocation = widget.initialLocation;
    } else {
      _getLocation();
    }
    _loadBusStopsFromFirestore();
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) _fetchUserRole();
    if (widget.busTrackerData != null) {
      _activeBusSegments = widget.busTrackerData!['busSegments'] ?? {};
      _busAssignments = widget.busTrackerData!['busAssignments'] ?? {};
    }

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
  }

  Future<String> getGoogleAccessToken() async {
    try {
      // Ensure user is signed in
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Get the ID token
      final idToken = await user.getIdToken();
      return idToken ?? '';
    } catch (e) {
      print('Error getting access token: $e');
      throw Exception('Failed to get access token');
    }
  }
  Future<Map<String, dynamic>> _fetchBusRoutes(String stopName) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('busStops')
        .where('name', isEqualTo: stopName)
        .get();

    if (snapshot.docs.isEmpty) return {};
    return snapshot.docs.first.data();
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

  Future<void> _loadBusStopsFromFirestore() async {
    final stops = await BusRouteService().getAllStopsWithCrowd();
    setState(() {
      _busStops    = stops;
      _sortedStops = List.from(stops)
        ..sort((a,b) => (b['crowd'] as int).compareTo(a['crowd'] as int));
    });
  }

  // --------------------- VERTEX AI CALL (Returning Multiple Candidates) ----------------------------- //
  Future<String> _callVertexAIPrediction(String prompt) async {
    try {
      final apiKey = dotenv.env['GEMINI_API_KEY'];
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('No Gemini API key found');
      }

      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-8b:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [{
            "parts": [{"text": prompt}]
          }],
          "generationConfig": {
            "temperature": 1,
            "maxOutputTokens": 3100,
            "topP": 0.95,
            "topK": 40
          }
        }),
      ).timeout(const Duration(seconds: 15));

      debugPrint("Gemini response status: ${response.statusCode}");
      debugPrint("Gemini response body: ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates']?[0]['content']['parts'][0]['text'] ??
            "No response text found";

        // Handle truncated responses
        if (data['candidates']?[0]['finishReason'] == 'MAX_TOKENS') {
          return "$text\n\n[Response truncated - ask more specifically]";
        }
        return text;
      } else {
        throw Exception("API Error ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Gemini API Error: $e");
      return "Error getting response: ${e.toString()}";
    }
  }
  String _buildEnhancedPrompt(String query, List<Map<String, dynamic>> stops) {
    final limitedStops = stops.take(5).toList();
    String busInfo = "ACTIVE BUSES:\n";
    _busAssignments.forEach((busId, busCode) {
      final stopsForBus = _activeBusSegments[busId] ?? [];
      busInfo += """
  🚌 $busCode
  - Current Stops: ${stopsForBus.map((s) => s['name']).join(' → ')}
  - Next Stop: ${stopsForBus.isNotEmpty ? stopsForBus.first['name'] : 'None'}
  
  """;
    });

    final stopsInfo = stops.map((stop) {
      // Find which buses serve this stop
      final servingBuses = _busAssignments.entries.where((entry) {
        final busStops = _activeBusSegments[entry.key] ?? [];
        return busStops.any((s) => s['name'] == stop['name']);
      }).map((e) => e.value).toList();

      return """
    🚏 ${stop['name']}
    - 👥 Crowd: ${stop['crowd']} people
    - ⏱️ ETA: ${stop['eta']} minutes
    - 🚌 Serving Buses: ${servingBuses.isNotEmpty ? servingBuses.join(', ') : 'None'}
    """;
    }).join('\n');

    return """
  You are SmartMove, an expert public transportation assistant in Malaysia. 
  Provide concise, actionable advice based on this real-time data:

  $busInfo

  CURRENT BUS STOPS NEAR USER:
  $stopsInfo

  USER'S QUESTION: $query

  RESPONSE REQUIREMENTS:
  1. Start with most relevant recommendation including specific bus number
  2. Include specific stop names and crowd levels
  3. Mention ETAs and serving buses
  4. Keep response under 200 words
  5. Format clearly with emojis
  6. Always show the same crowd numbers as displayed on the map

  EXAMPLE RESPONSE:
  "🚍 Best option: Take Bus B2 from Aman Damai (15 people, 5 min ETA). 
  🚶 Alternative: Walk to BHEPA (10 min) if you want to avoid crowds."

  NOW ANSWER THE USER'S QUESTION:
  """;
  }

  void _sendUserQuery(String query) async {
    if (query.trim().isEmpty) return;

    // Clear input and update UI immediately
    _chatController.clear();
    setState(() {
      _chatHistory.add({"sender": "user", "message": query});
      _chatHistory.add({"sender": "ai", "message": "🔄 Analyzing..."});
    });


    try {
      final stops = _busStops;
      if (stops.isEmpty) throw Exception('No bus stop data');
      if (_busAssignments.isEmpty) {
        throw Exception('LiveCrowd has no bus data – did you forget to pass it from BusTracker?');
      }

      final response = await _callVertexAIPrediction(
        _buildEnhancedPrompt(query, stops),
      );

      // Ensure we remove the "Analyzing..." message
      setState(() {
        _chatHistory = List<Map<String, String>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing...")
          ..add({"sender": "ai", "message": response});
      });
    } catch (e) {
      debugPrint("Chat error: $e");
      setState(() {
        _chatHistory = List<Map<String, String>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing...")
          ..add({
            "sender": "ai",
            "message": "⚠️ Error: ${e.toString().replaceAll('Exception: ', '')}"
          });
      });
    }
  }
  // --------------------- WHEN THE USER SENDS A QUERY ------------------------ //

  // ------------------- BOTTOM SHEET CHAT UI (with improved keyboard handling) ------------------------------- //
  void _showChatModal() {
    showModalBottomSheet(
      isScrollControlled: true,
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.purple),
                  ),
                  SizedBox(height: 12),
                  if (_chatHistory.isNotEmpty &&
                      _chatHistory.last["sender"] == "ai" &&
                      _chatHistory.last["message"] == "🔄 Analyzing...")
                    LinearProgressIndicator(minHeight: 2),

                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _chatHistory.length,
                      // In your ListView.builder itemBuilder:
                      itemBuilder: (context, index) {
                        final chat = _chatHistory[index];
                        final isUser = chat["sender"] == "user";

                        // Skip if message is empty (safety check)
                        if (chat["message"]?.isEmpty ?? true) return SizedBox.shrink();

                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                            margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            padding: EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isUser ? Colors.purple[600] : Colors.grey[200],
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(isUser ? 12 : 0),
                                topRight: Radius.circular(isUser ? 0 : 12),
                                bottomLeft: Radius.circular(12),
                                bottomRight: Radius.circular(12),
                              ),
                            ),
                            child: Text(
                              chat["message"]!,
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
                    padding: EdgeInsets.only(bottom: 10, top: 8, left: 8, right: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            decoration: InputDecoration(
                              hintText: "Ask a question...",
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onSubmitted: _sendUserQuery,
                          ),
                        ),
                        SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => _sendUserQuery(_chatController.text),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
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


  // ------------------------ LIVE DATA VISUAL ----------------------------------- //
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

  // ------------------------ MAIN UI ----------------------------------- //
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
      bottomNavigationBar: BottomNavBar(
        selectedIndex: _selectedIndex,
        onItemTapped: _onItemTapped,
      ),
    );
  }
}