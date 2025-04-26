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
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  Future<String> _callVertexAIPrediction(String prompt) async {
    try {
      final accessToken = await getGoogleAccessToken();
      if (accessToken.isEmpty) {
        throw Exception('No access token available');
      }

      const String project = "smart-move-455808";
      const String region = "us-central1";
      final String url = "https://$region-aiplatform.googleapis.com/v1/projects/$project/locations/$region/publishers/google/models/gemini-pro:predict";

      debugPrint("Sending prompt to Gemini:\n$prompt");

      final payload = {
        "contents": [{
          "parts": [{"text": prompt}]
        }],
        "generationConfig": {
          "temperature": 0.5,
          "maxOutputTokens": 1000,
          "topP": 0.8,
          "topK": 40
        }
      };

      final headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer $accessToken",
      };
      final apiKey = dotenv.env['GEMINI_API_KEY'];

      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [{
            "parts": [{"text": "Your prompt here"}]
          }]
        }),
      ).timeout(const Duration(seconds: 30));

      debugPrint("Gemini response status: ${response.statusCode}");
      debugPrint("Gemini response body: ${response.body}");

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final candidates = responseData['candidates'] ?? [];
        if (candidates.isNotEmpty) {
          return candidates[0]['content']['parts'][0]['text'] ??
              "No response content from Gemini";
        }
        return "No candidates returned from Gemini";
      } else {
        throw Exception("API Error ${response.statusCode}: ${response.body}");
      }
    } catch (e) {
      debugPrint("Gemini API Error: $e");
      return "Error getting response: ${e.toString()}";
    }
  }
  String _buildEnhancedPrompt(String query, List<Map<String, dynamic>> stops) {
    // Format the stops information clearly
    final stopsInfo = stops.map((stop) {
      return """
    🚏 ${stop['name']}
    - 👥 Crowd: ${stop['crowd']} people
    - ⏱️ ETA: ${stop['eta']} minutes
    - 🚌 Routes: ${stop['routes']?.join(', ') ?? 'None'}
    """;
    }).join('\n');

    return """
  You are SmartMove, an expert public transportation assistant in Malaysia. 
  Provide concise, actionable advice based on this real-time data:

  CURRENT BUS STOPS NEAR USER:
  $stopsInfo

  USER'S QUESTION: $query

  RESPONSE REQUIREMENTS:
  1. Start with most relevant recommendation
  2. Include specific stop names and route numbers
  3. Mention crowd levels and ETAs
  4. Keep response under 200 words
  5. Format clearly with emojis

  EXAMPLE RESPONSE:
  "🚍 Best option: Take Route BHEPA from Aman Damai (15 people, 5 min ETA). 
  🚶 Alternative: Walk to BHEPA (10 min) if you want to avoid crowds."

  NOW ANSWER THE USER'S QUESTION:
  """;
  }

  void _sendUserQuery(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _chatHistory.add({"sender": "user", "message": query});
      _chatHistory.add({"sender": "ai", "message": "🔄 Analyzing real-time data..."});
    });

    try {
      // 1. Get enhanced stop data
      final stops = await _busDataService.getEnhancedBusStops();
      if (stops.isEmpty) {
        throw Exception('No bus stop data available');
      }

      // 2. Build the prompt
      final prompt = _buildEnhancedPrompt(query, stops);
      debugPrint("Final prompt:\n$prompt");

      // 3. Get Gemini response
      final response = await _callVertexAIPrediction(prompt);
      debugPrint("Raw Gemini response:\n$response");

      // 4. Update UI
      setState(() {
        _chatHistory.removeLast();
        _chatHistory.add({
          "sender": "ai",
          "message": response.contains("Error") ?
          "⚠️ $response" :
          "🚍 SmartMove Advice:\n$response"
        });
      });

    } catch (e) {
      debugPrint("Chat error: $e");
      setState(() {
        _chatHistory.removeLast();
        _chatHistory.add({
          "sender": "ai",
          "message": "⚠️ Sorry, I couldn't process your request. Please try again later."
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
