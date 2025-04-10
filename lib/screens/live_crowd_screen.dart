import 'dart:convert'; // Needed for jsonEncode
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

class LiveCrowdScreen extends StatefulWidget {
  @override
  _LiveCrowdScreenState createState() => _LiveCrowdScreenState();
}

class _LiveCrowdScreenState extends State<LiveCrowdScreen> {
  late GoogleMapController _controller;
  LatLng? _currentLocation;
  List<Map<String, dynamic>> _busStops = [];
  List<Map<String, dynamic>> _sortedStops = [];

  // Chat-related state for AI assistant
  List<Map<String, String>> _chatHistory = [];
  final TextEditingController _chatController = TextEditingController();

  // For storing the "last approach" candidates (if needed)
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

  // --------------------- VERTEX AI INTEGRATION ----------------------------- //
  // Calls a pre-trained Vertex AI model endpoint to get a suggestion.
  Future<String> _callVertexAIPrediction(String query) async {
    // Replace these with your actual project details.
    final String project = "YOUR_PROJECT_ID";
    final String region = "YOUR_REGION"; // e.g., "us-central1"
    final String endpointId = "YOUR_ENDPOINT_ID";

    // Construct the Vertex AI REST API URL:
    final String url =
        "https://$region-aiplatform.googleapis.com/v1/projects/$project/locations/$region/endpoints/$endpointId:predict";

    // Construct payload – sending query, bus stops data, and user location.
    final Map<String, dynamic> payload = {
      "instances": [
        {
          "query": query,
          "busStops": _busStops.map((stop) {
            final LatLng loc = stop['location'] as LatLng;
            return {
              "name": stop['name'],
              "crowd": stop['crowd'],
              "eta": stop['eta'],
              "lat": loc.latitude,
              "lng": loc.longitude,
            };
          }).toList(),
          "userLocation": _currentLocation != null
              ? {"lat": _currentLocation!.latitude, "lng": _currentLocation!.longitude}
              : null
        }
      ],
      "parameters": {}
    };

    // In production, obtain your access token securely.
    final headers = {
      "Content-Type": "application/json",
      "Authorization": "Bearer YOUR_ACCESS_TOKEN",
    };

    final response = await http.post(Uri.parse(url),
        headers: headers, body: jsonEncode(payload));

    if (response.statusCode == 200) {
      final Map<String, dynamic> responseData = jsonDecode(response.body);
      // Assumes the endpoint returns: {"predictions": [{"suggestion": "Your text"}]}
      return responseData["predictions"][0]["suggestion"] ??
          "No suggestion returned from AI.";
    } else {
      throw Exception(
          "Vertex AI call failed with status ${response.statusCode}: ${response.body}");
    }
  }

  // --------------------- WHEN THE USER SENDS A QUERY ------------------------ //
  void _sendUserQuery(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _chatHistory.add({"sender": "user", "message": query});
      _chatController.clear();
    });
    try {
      // Use Vertex AI for a suggestion.
      String aiResponse = await _callVertexAIPrediction(query);
      setState(() {
        _chatHistory.add({"sender": "ai", "message": aiResponse});
      });
    } catch (error) {
      setState(() {
        _chatHistory.add({"sender": "ai", "message": "Error: ${error.toString()}"});
      });
    }
  }

  // ------------------- BOTTOM SHEET CHAT UI (with improved keyboard handling) ------------------------------- //
  void _showChatModal() {
    showModalBottomSheet(
      isScrollControlled: true,
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
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
                          onPressed: () =>
                              _sendUserQuery(_chatController.text),
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
                  value: crowd / 50.0,
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

  // ------------------------ MAIN UI -------------------------------------- //
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
