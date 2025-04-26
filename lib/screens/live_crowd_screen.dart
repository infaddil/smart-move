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

class LiveCrowdScreen extends StatefulWidget {
  final LatLng? initialLocation;
  LiveCrowdScreen({this.initialLocation});

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
        // Simulated live crowd count between 5 and 54
        'crowd': random.nextInt(50) + 5,
        'eta': random.nextInt(60) + 1,
      };
    }).toList();
    setState(() {
      _busStops = stops;
      _sortedStops = List.from(stops)
        ..sort((a, b) => b['crowd'].compareTo(a['crowd']));
    });
  }

  // --------------------- VERTEX AI CALL (Returning Multiple Candidates) ----------------------------- //
  Future<String> _callVertexAIPrediction(String query) async {
    const String project = "smart-move-455808";
    const String region = "us-central1"; // try us-central1 if needed
    final String url = "https://$region-aiplatform.googleapis.com/v1/projects/$project/locations/$region/publishers/google/models/gemini-pro:predict";
    const String accessToken = "YOUR_ACCESS_TOKEN";  // update with current token
    final enhancedStops = await _busDataService.getEnhancedBusStops();
    String prompt = """
  You are a smart transit assistant. Analyze this real-time data:
  
  CURRENT BUS STOPS:
  ${enhancedStops.map((stop) =>
    "${stop['name']}: ${stop['crowd']} people | ETA ${stop['eta']} mins | Buses: ${stop['routes']?.join(', ') ?? 'Unknown'}"
    ).join('\n')}
  
  USER LOCATION: ${_currentLocation?.latitude}, ${_currentLocation?.longitude}
  
  Provide recommendations in this exact format:
  
  1. [Least Crowded] - Stop with fewest people
  2. [Fastest Option] - Quickest route considering ETA
  3. [Route Details] - Which buses go where from this stop
  4. [Smart Alternative] - Walking/other options if better
  
  Question: $query
  """;

    final payload = {
      "contents": [{
        "parts": [{"text": prompt}]
      }],
      "generationConfig": {
        "temperature": 0.5,
        "maxOutputTokens": 500
      }
    };

    print("Calling Vertex AI with payload: ${jsonEncode(payload)}");

    final headers = {
      "Content-Type": "application/json",
      "Authorization": "Bearer $accessToken",
    };

    final response = await http.post(Uri.parse(url), headers: headers, body: jsonEncode(payload));
    print("HTTP status: ${response.statusCode}");
    print("Response body: ${response.body}");

    if (response.statusCode == 200) {
      final Map<String, dynamic> responseData = jsonDecode(response.body);
      return responseData["predictions"][0]["candidates"][0]["content"] ??
          "No suggestion returned from AI.";
    } else {
      throw Exception("Vertex AI call failed: ${response.statusCode} ${response.body}");
    }
  }

  void _sendUserQuery(String query) async {
    setState(() {
      _chatHistory.add({"sender": "user", "message": query});
      _chatHistory.add({"sender": "ai", "message": "⌛ Analyzing real-time data..."});
    });

    try {
      final response = await _callVertexAIPrediction(query);

      // Parse the numbered recommendations
      final recommendations = response.split('\n')
          .where((line) => line.startsWith(RegExp(r'^\d\.\s')))
          .map((rec) => rec.substring(3))
          .toList();

      setState(() {
        _chatHistory.removeLast();
        _chatHistory.addAll([
          {"sender": "ai", "message": "🚍 Smart Recommendations:"},
          {"sender": "ai", "message": recommendations[0]},
          {"sender": "ai", "message": recommendations[1]},
          {"sender": "ai", "message": recommendations[2]},
          {"sender": "ai", "message": recommendations[3]},
        ]);
      });
    } catch (e) {
      setState(() {
        _chatHistory.removeLast();
        _chatHistory.add({"sender": "ai", "message": "❌ Error: ${e.toString()}"});
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
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _chatHistory.length,
                      itemBuilder: (context, index) {
                        final chat = _chatHistory[index];
                        final isUser = chat["sender"] == "user";
                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
