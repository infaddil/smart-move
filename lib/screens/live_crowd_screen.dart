import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/screens/bus_data_service.dart';
import 'package:smart_move/screens/bus_route_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:io';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';

class LiveCrowdScreen extends StatefulWidget {
  final LatLng? initialLocation;
  final Map<String, dynamic>? busTrackerData;
  LiveCrowdScreen({super.key, this.initialLocation, this.busTrackerData});

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
  File? _pickedImage;
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _audioPath;
  ScrollController? _sheetScrollController;
  bool _isBusyRecording = false;
  bool _isMicButtonPressed = false;
  Map<String,LatLng>   _stopLocations     = {};
  Map<String,int>      _crowdLevels       = {};


  List<Map<String,dynamic>> _chatHistory = [];
  final TextEditingController _chatController = TextEditingController();

  List<String> _lastCandidates = [];
  int _lastIndex = 0;
  /// 1) Load bus stop coords & crowd levels once
  Future<void> _loadStaticData() async {
    final stopsSnap = await FirebaseFirestore.instance.collection('busStops').get();
    for (var d in stopsSnap.docs) {
      final p = d['location'] as GeoPoint;
      _stopLocations[d.id] = LatLng(p.latitude, p.longitude);
      _crowdLevels[d.id]   = (d['crowd'] as num).toInt();
    }
  }
  void _listenToBusActivity() {
    FirebaseFirestore.instance
        .collection('busActivity')
        .snapshots()
        .listen((snap) {
      final assign = <String, String>{};
      final segs = <String, List<Map<String, dynamic>>>{};

      for (var d in snap.docs) {
        try {
          final data = d.data();
          final busCode = data['busCode'] as String?;
          // --- Read the 'stops' field as a List ---
          final stopsListRaw = data['stops'] as List?;

          if (busCode != null) {
            assign[d.id] = busCode;

            // --- Process the new structured stops list ---
            if (stopsListRaw != null) {
              final List<Map<String, dynamic>> currentBusStopsData = [];
              for (var item in stopsListRaw) {
                if (item is Map) {
                  // Safely extract data from each map in the list
                  final name = item['name'] as String?;
                  final etaRaw = item['eta'];
                  final crowdRaw = item['crowd'];

                  final int etaValue = (etaRaw is num) ? etaRaw.toInt() : -1;
                  final int crowdValue = (crowdRaw is num) ? crowdRaw.toInt() : 0;

                  if (name != null) {
                    currentBusStopsData.add({
                      'name': name,
                      'eta': etaValue,
                      'crowd': crowdValue,
                    });
                  } else {
                    debugPrint("⚠️ busActivity doc ${d.id}: Found stop map without 'name'. Skipping item.");
                  }
                } else {
                  debugPrint("⚠️ busActivity doc ${d.id}: Item in 'stops' list is not a Map. Skipping item.");
                }
              }
              segs[d.id] = currentBusStopsData; // Assign the processed list
            } else {
              debugPrint("⚠️ busActivity doc ${d.id}: 'stops' field is missing or null. Assigning empty list.");
              segs[d.id] = []; // Assign empty list if 'stops' field is bad
            }
            // --- End processing ---

          } else {
            debugPrint("⚠️ Document ${d.id} in busActivity missing 'busCode'.");
          }
        } catch (e) {
          debugPrint("Error processing document ${d.id} in _listenToBusActivity: $e");
          // Assign empty list on error for this bus
          if (assign.containsKey(d.id)) { // Check if assignment was successful before trying to add empty segs
            segs[d.id] = [];
          }
        }
      }

      if (mounted) {
        setState(() {
          _busAssignments = assign;
          _activeBusSegments = segs; // Update state with the new structured data
        });
      }
    }, onError: (error) {
      debugPrint("Error listening to busActivity snapshots: $error");
    });
  }

  @override
  void initState() {
    super.initState();
    _loadStaticData();
    _listenToBusActivity();
    if (widget.initialLocation != null) {
      _currentLocation = widget.initialLocation;
    } else {
      _getLocation();
    }
    _loadBusStopsFromFirestore();
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) _fetchUserRole();
    Future<({
    List<Map<String,dynamic>> stops,
    Map<String,String> assignments,
    Map<String,List<Map<String,dynamic>>> segments
    })> _fetchBusContext() async {
      // 1) all known stops with geo & crowd
      final stopsSnap = await FirebaseFirestore.instance.collection('busStops').get();
      final stops = stopsSnap.docs.map((d) {
        final data = d.data();
        final geo  = data['location'] as GeoPoint;
        return {
          'name': data['name'],
          'location': LatLng(geo.latitude, geo.longitude),
          'crowd': data['crowd'] as int,
          'eta':   data['eta'] as int,
        };
      }).toList();

      // 2) current busActivity
      final actSnap = await FirebaseFirestore.instance.collection('busActivity').get();
      final assignments = <String,String>{};
      final segments    = <String,List<Map<String,dynamic>>>{};

      for (var doc in actSnap.docs) {
        final d      = doc.data();
        final busId  = doc.id;
        assignments[busId] = d['busCode'] as String;
        segments[busId] = List<Map<String,dynamic>>.from(d['stops'] as List);
      }

      return (stops: stops, assignments: assignments, segments: segments);
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
    if (!serviceEnabled) {
      debugPrint("Location services disabled.");
      // Optionally show a message to the user
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint("Location permission denied initially. Requesting...");
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint("Location permission denied after request.");
        // Optionally show a message to the user
        return; // Exit if permission still denied
      }
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (mounted) { // Check if the state is still in the tree
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude); // Use the correct variable _currentLocation
        });
      }
    } catch (e) {
      debugPrint("Error getting current position in _getLocation: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error getting location: ${e.toString()}"))
        );
      }
    }
  }

  Future<void> _loadBusStopsFromFirestore() async {
    final stops = await BusRouteService().getAllStopsWithCrowd();
    setState(() {
      _busStops    = stops;
      _sortedStops = List.from(stops)
        ..sort((a,b) => (b['crowd'] as int).compareTo(a['crowd'] as int));
    });
  }
  /// Push the live state of one bus into Firestore


  Future<void> _pickImage() async {
    try {
      final XFile? file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 70); // Using gallery for example
      if (file == null) {
        debugPrint("Image picking cancelled by user.");
        return; // User cancelled picker
      }

      final imageFile = File(file.path);
      final imagePath = file.path; // Get the path

      // Add image preview to chat history
      setState(() {
        // It's generally better not to store the whole File object in state if
        // not needed long-term. Path is usually sufficient.
        // _pickedImage = imageFile; // Only store if needed elsewhere

        _chatHistory.add({
          "type": "image", // For UI rendering
          "sender": "user",
          "content": imagePath, // Store path for display
          "message": "🖼️ Image selected (asking AI...)" // Placeholder text
        });
      });

      // --- >>> THIS IS THE CRUCIAL PART THAT WAS MISSING <<< ---
      // Define the base instruction for the AI regarding the image
      // Use the complex prompt from the previous step asking it to find nearby stops
      String imageInstruction = "Identify the location/landmark/building shown in this image (likely within USM, Penang). If it's one of the known bus stops provided in the context, give directions to it. If it's NOT a known bus stop, identify the CLOSEST known bus stop from the context list and recommend going there to reach the location in the image. Provide bus details for the recommended stop.";

      // Trigger the API call with the image path, instruction, and context
      _sendImageQueryToGemini(
          imagePath, // Pass the image path
          imageInstruction,// Pass current bus segments/locations
      );
      // --- <<< END OF MISSING CALL <<< ---

    } catch (e) {
      debugPrint("Error picking or processing image: $e");
      if (mounted) { // Check if mounted before showing Snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error picking image: ${e.toString()}")),
        );
      }
      // Optionally add an error message to chat history
      setState(() {
        _chatHistory.add({
          "sender": "ai",
          "message": "⚠️ Error handling image."
        });
      });
    }
  }
  String _buildEnhancedImagePrompt(
      String baseInstruction, // e.g., "How do I get to the place in this image?"
      List<Map<String, dynamic>> stops,
      Map<String, String> busAssignments,
      Map<String, List<Map<String, dynamic>>> activeBusSegments) {

    // Format bus and stop data (same as before)
    String busInfo = "ACTIVE BUSES:\n";
    (busAssignments ?? {}).forEach((busId, busCode) {
      final stopsForBus = (activeBusSegments ?? {})[busId] ?? [];
      busInfo += """
  🚌 $busCode
  - Current Stops: ${stopsForBus.map((s) => s['name'] ?? 'Unknown').join(' → ')}
  - Next Stop: ${stopsForBus.isNotEmpty ? (stopsForBus.first['name'] ?? 'Unknown') : 'None'}

  """;
    });

    // Create a simple list of known stop names for the AI to check against
    final knownStopNames = (stops ?? []).map((s) => s['name'] ?? 'Unknown').toSet();

    final stopsInfo = (stops ?? []).map((stop) {
      final servingBuses = (busAssignments ?? {}).entries.where((entry) {
        final busStops = (activeBusSegments ?? {})[entry.key] ?? [];
        return busStops.any((s) => s['name'] == stop['name']);
      }).map((e) => e.value).toList();

      return """
    🚏 ${stop['name'] ?? 'Unknown'}
    - 👥 Crowd: ${stop['crowd'] ?? '?'} people
    - ⏱️ ETA: ${stop['eta'] ?? '?'} minutes
    - 🚌 Serving Buses: ${servingBuses.isNotEmpty ? servingBuses.join(', ') : 'None'}
    """;
    }).join('\n');

    // Combine base instruction with context AND the nearby logic request
    return """
  You are SmartMove, an expert public transportation assistant in Gelugor, Penang, Malaysia (specifically near USM).
  Analyze the provided image AND use the following real-time bus data context to answer the user's request.

  CONTEXT DATA:
  $busInfo

  LIST OF KNOWN BUS STOPS NEAR USER:
  ${knownStopNames.join(', ')}

  DETAILED INFO ON KNOWN BUS STOPS NEAR USER:
  $stopsInfo

  USER'S INSTRUCTION BASED ON IMAGE: $baseInstruction

  RESPONSE REQUIREMENTS & LOGIC:
  1. First, carefully identify the primary location, landmark, or building shown in the image. Let's call this the 'Image Location'. State clearly what you identified (e.g., "The image shows DK B").
  2. **Check if the identified 'Image Location' name exactly matches one of the names in the 'LIST OF KNOWN BUS STOPS NEAR USER' provided above.**
  3. **If it MATCHES a known bus stop name:** Provide directions directly to that bus stop using the real-time context data (ETA, crowd, serving buses from the 'DETAILED INFO' section).
  4. **If it DOES NOT MATCH a known bus stop name:**
      a. State that the 'Image Location' (e.g., DK B) is not a listed bus stop.
      b. **THEN, try to determine which bus stop from the 'LIST OF KNOWN BUS STOPS NEAR USER' is geographically closest to the identified 'Image Location' based on your general knowledge of USM/Penang geography.**
      c. Recommend the user travel to that *closest known bus stop* to reach the 'Image Location'. Mention the closest stop's name and provide its details (ETA, crowd, serving buses) from the 'DETAILED INFO' section. Example: "The image shows DK B, which isn't a listed bus stop. It seems closest to the DK A bus stop. To get near DK B, you can take Bus A1 to DK A (Crowd: ..., ETA: ...)."
  5. If the location cannot be reliably identified at all, or you cannot determine a nearby known bus stop, state that clearly.
  6. Keep response concise and clear. Format clearly with emojis.

  NOW ANALYZE THE IMAGE AND FOLLOW THE LOGIC ABOVE:
  """;
  }

  Future<void> _sendImageQueryToGemini(
      String imagePath,
      String baseInstruction
      ) async {

    final analyzingMessageId = DateTime.now().millisecondsSinceEpoch.toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if(mounted) {
        setState(() {
          _chatHistory.add({"id": analyzingMessageId, "sender": "ai", "message": "🔄 Analyzing image..."});
        });
        if (_sheetScrollController?.hasClients ?? false) {
          _sheetScrollController?.animateTo(_sheetScrollController!.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        }
      }
    });

    String finalMessage = "⚠️ An error occurred processing the image.";

    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      finalMessage = "⚠️ Error: API Key not configured.";
      debugPrint(finalMessage);
      if (mounted) {
        setState(() {
          _chatHistory.removeWhere((msg) => msg["id"] == analyzingMessageId);
          _chatHistory.removeWhere((msg) => msg["message"] == "🔄 Analyzing image...");
          _chatHistory.add({"sender": "ai", "message": finalMessage});
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_sheetScrollController?.hasClients ?? false) {
            _sheetScrollController?.animateTo(_sheetScrollController!.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
        });
      }
      return;
    }

    try {
      final ctx = await _fetchBusContext();
      final List<Map<String,dynamic>> freshStops = ctx['stops'] as List<Map<String,dynamic>>;
      final Map<String,String> freshAssignments = ctx['assignments'] as Map<String,String>;
      final Map<String,List<Map<String,dynamic>>> freshSegments = ctx['segments'] as Map<String,List<Map<String,dynamic>>>;

      final imageFile = File(imagePath);
      if (!await imageFile.exists()) throw Exception("Image file does not exist at path: $imagePath");
      final imageBytes = await imageFile.readAsBytes();
      final base64Image = base64Encode(imageBytes);
      String mimeType = 'image/jpeg';
      final lowerPath = imagePath.toLowerCase();
      if (lowerPath.endsWith('.png')) mimeType = 'image/png';
      else if (lowerPath.endsWith('.webp')) mimeType = 'image/webp';
      else if (lowerPath.endsWith('.heic')) mimeType = 'image/heic';
      else if (lowerPath.endsWith('.heif')) mimeType = 'image/heif';

      final fullPrompt = _buildEnhancedImagePrompt(
          baseInstruction,
          freshStops,           // Use fresh data
          freshAssignments,     // Use fresh data
          freshSegments         // Use fresh data
      );

      final requestBody = jsonEncode({
        "contents": [{"parts": [{"text": fullPrompt}, {"inlineData": {"mimeType": mimeType, "data": base64Image}}] }],
        "generationConfig": { "temperature": 0.7, "maxOutputTokens": 1024, }
      });

      debugPrint("--- Sending Image Query ---");
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      ).timeout(const Duration(seconds: 90));
      debugPrint("--- Gemini Response Received (Status: ${response.statusCode}) ---");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String geminiRawResponse = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? "";
        debugPrint("===== Raw Gemini Response Start =====");
        debugPrint(geminiRawResponse);
        debugPrint("===== Raw Gemini Response End =====");

        bool overrideApplied = false;

        final Map<String, String> locationOverrides = {
          "desasiswa cahaya gemilang h34": "BHEPA",
          "desasiswa bakti permai": "Stor Kimia",
          "desasiswa bakti fajar permai": "Stor Kimia",
        };
        String? identifiedLocationForMsg;
        String? correctNearbyStopName;
        String geminiResponseLower = geminiRawResponse.toLowerCase();
        debugPrint("Lowercase Gemini Response for check: $geminiResponseLower");

        for (var entry in locationOverrides.entries) {
          String keyToCheck = entry.key;
          String stopToSuggest = entry.value;
          bool containsKey = geminiResponseLower.contains(keyToCheck);
          debugPrint("Checking if response contains key: '$keyToCheck' | Result: $containsKey");

          if (containsKey) {
            identifiedLocationForMsg = keyToCheck;
            correctNearbyStopName = stopToSuggest;
            overrideApplied = true;
            debugPrint("!!! Override Rule Matched !!!");
            debugPrint("Matched Keyword: $identifiedLocationForMsg");
            debugPrint("Suggesting Override Stop: $correctNearbyStopName");
            break;
          }
        }

        if (overrideApplied && correctNearbyStopName != null) {
          debugPrint("Attempting to find data for override stop: '$correctNearbyStopName'");
          // Use the freshStops fetched earlier in the function
          debugPrint("Available stop names in freshStops: ${freshStops.map((s) => s['name']).toList()}");

          final correctStopData = freshStops.firstWhere(
                (stop) =>
            stop['name']?.toString().trim().toLowerCase() ==
                correctNearbyStopName!.trim().toLowerCase(),
            orElse: () => <String, dynamic>{}, // Ensure consistent return type
          );

          if (correctStopData.isNotEmpty) {
            debugPrint("Successfully found data for override stop: $correctNearbyStopName");
            final crowdRaw = correctStopData['crowd'];
            final etaRaw = correctStopData['eta'];
            final crowd = (crowdRaw is int) ? crowdRaw : '?'; // Check type before using
            final eta = (etaRaw is int) ? etaRaw : '?';

            final servingBuses = freshAssignments.entries
                .where((entry) => (freshSegments[entry.key] ?? []).any((s) => s['name'] == correctNearbyStopName))
                .map((e) => e.value)
                .toList();
            String displayIdentifiedName = identifiedLocationForMsg ?? "the identified location";
            if (displayIdentifiedName.isNotEmpty) {
              try {
                displayIdentifiedName = displayIdentifiedName.split(' ').map((word) {
                  if (word.isEmpty) return '';
                  if (word.length > 1 && word.substring(1).contains(RegExp(r'[A-Z0-9]'))) { return word[0].toUpperCase() + word.substring(1); }
                  return word[0].toUpperCase() + word.substring(1).toLowerCase();
                }).join(' ');
              } catch (e) { /* ignore */ }
            }

            finalMessage = """
✅ The image appears to show '$displayIdentifiedName'. This location is not a listed bus stop.
➡️ Based on known locations, the closest known bus stop is '$correctNearbyStopName'.

To reach '$displayIdentifiedName', I recommend going to the '$correctNearbyStopName' bus stop:
👥 Crowd: $crowd people
⏱️ ETA: $eta minutes
🚌 Serving Buses: ${servingBuses.isNotEmpty ? servingBuses.join(', ') : 'None'}""";
            debugPrint("Override applied. Final message constructed.");

          } else {
            debugPrint("Override logic failed: Stop data not found for '$correctNearbyStopName'. Falling back to Gemini response.");
            finalMessage = geminiRawResponse.isNotEmpty ? geminiRawResponse : "Could not extract response text.";
            overrideApplied = false;
          }
        }

        if (!overrideApplied) {
          debugPrint("No override applied. Using original Gemini logic.");
          if (geminiRawResponse.isEmpty) {
            final blockReason = data['promptFeedback']?['blockReason'];
            finalMessage = blockReason != null ? "⚠️ Response blocked: $blockReason" : "⚠️ Received an empty response from the AI.";
          } else if (data['candidates']?[0]?['finishReason'] == 'MAX_TOKENS') {
            finalMessage = "$geminiRawResponse\n\n[Response may be truncated]";
          } else {
            finalMessage = geminiRawResponse;
          }
        }

      } else { // Handle API errors
        String errorDetail = response.body;
        try {
          final errorJson = jsonDecode(response.body);
          errorDetail = errorJson['error']?['message'] ?? response.body;
        } catch (_) {}
        finalMessage = "⚠️ API Error ${response.statusCode}: $errorDetail";
        debugPrint("API Error encountered: $finalMessage");
      }
    } catch (e) { // Handle other exceptions
      debugPrint("Error sending image query (Exception caught): $e");
      finalMessage = "⚠️ Error processing image: ${e.toString()}";
    }

    // --- Final UI Update ---
    if (mounted) {
      setState(() {
        _chatHistory.removeWhere((msg) => msg["id"] == analyzingMessageId);
        _chatHistory.removeWhere((msg) => msg["message"] == "🔄 Analyzing image...");
        _chatHistory.add({"sender": "ai", "message": finalMessage});
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sheetScrollController?.hasClients ?? false) {
          _sheetScrollController?.animateTo(
            _sheetScrollController!.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      debugPrint("Widget unmounted before final UI update for image query.");
    }

  } // End of _sendImageQueryToGemini

  String _buildEnhancedAudioPrompt(
      String baseInstruction, // e.g., "Analyze this audio..."
      List<Map<String, dynamic>> stops,
      Map<String, String> busAssignments,
      Map<String, List<Map<String, dynamic>>> activeBusSegments) {

    // Reuse the logic from _buildEnhancedPrompt to format bus/stop data
    String busInfo = "ACTIVE BUSES:\n";
    // Add null check just in case
    (busAssignments ?? {}).forEach((busId, busCode) {
      final stopsForBus = (activeBusSegments ?? {})[busId] ?? [];
      busInfo += """
    🚌 $busCode
    - Current Stops: ${stopsForBus.map((s) => s['name'] ?? 'Unknown Stop').join(' → ')}
    - Next Stop: ${stopsForBus.isNotEmpty ? (stopsForBus.first['name'] ?? 'Unknown Stop') : 'None'}

    """;
    });

    final stopsInfo = (stops ?? []).map((stop) {
      // Find which buses serve this stop
      final servingBuses = (busAssignments ?? {}).entries.where((entry) {
        final busStops = (activeBusSegments ?? {})[entry.key] ?? [];
        return busStops.any((s) => s['name'] == stop['name']);
      }).map((e) => e.value).toList();

      return """
      🚏 ${stop['name'] ?? 'Unknown Stop'}
      - 👥 Crowd: ${stop['crowd'] ?? '?'} people
      - ⏱️ ETA: ${stop['eta'] ?? '?'} minutes
      - 🚌 Serving Buses: ${servingBuses.isNotEmpty ? servingBuses.join(', ') : 'None'}
      """;
    }).join('\n');

    // Combine base instruction with context
    return """
    You are SmartMove, an expert public transportation assistant in Gelugor, Penang, Malaysia.
    Listen to the following audio and provide concise, actionable advice based on the audio content AND this real-time data:

    $busInfo

    CURRENT BUS STOPS NEAR USER:
    $stopsInfo

    USER'S AUDIO CONTENT ANALYSIS INSTRUCTION: $baseInstruction

    RESPONSE REQUIREMENTS:
    1. First, understand the user's need from the audio.
    2. Then, provide the most relevant recommendation using the real-time data (include specific bus number/code).
    3. Include specific stop names and crowd levels from the data provided above.
    4. Mention ETAs and serving buses from the data.
    5. Keep response concise and clear.
    6. Format clearly with emojis if appropriate.
    7. Use the crowd numbers, ETAs, and bus assignments exactly as provided in the data context above.

    NOW ANALYZE THE AUDIO AND ANSWER BASED ON THE CONTEXT:
    """;
  }

  // NEW Function: Starts recording
  Future<void> _startRecording() async {
    if (_isBusyRecording) return; // Already busy with another operation

    setState(() {
      _isBusyRecording = true;
      _isMicButtonPressed = true; // Visually indicate press
    });

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      debugPrint("Microphone permission not granted.");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Microphone permission required.")),
      );
      setState(() {
        _isBusyRecording = false;
        _isMicButtonPressed = false; // Reset press state
      });
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      debugPrint("Attempting to start recording to: $filePath");

      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: filePath,
      );

      // Check if recording actually started
      final isActuallyRecording = await _recorder.isRecording();
      if (!isActuallyRecording) {
        throw Exception("Recorder failed to enter recording state.");
      }
      debugPrint("Recording started successfully.");
      // No need to set _isRecording flag anymore, press state handles it

    } catch (e) {
      debugPrint("Error starting recording: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error starting recording: ${e.toString()}")),
      );
      // Reset state on error
      setState(() {
        _isMicButtonPressed = false;
      });
    } finally {
      // Only mark as not busy if start failed immediately, otherwise stop will handle it
      final isActuallyRecording = await _recorder.isRecording();
      if(!isActuallyRecording) {
        setState(() => _isBusyRecording = false);
      }
    }
  }

  // CORRECTED Function: Stops recording and sends to chat
  // --- MODIFIED METHOD: Stops recording and sends to Gemini ---
  Future<void> _stopAndSendRecording() async {
    // Only proceed if we were actually recording (button was pressed)
    // and not already busy stopping.
    if (!_isBusyRecording || !_isMicButtonPressed) {
      setState(() {
        _isMicButtonPressed = false; // Ensure visual state is reset
        // Try to stop recording if it got stuck somehow
        _recorder.isRecording().then((isRec) {
          if (isRec) {
            debugPrint("Stop called without active press, but recorder was recording. Stopping now.");
            _recorder.stop().catchError((e) => debugPrint("Error stopping dangling recording: $e"));
          }
        });
      });
      if (!_isBusyRecording) return;
    }

    // Reset button press state immediately for visual feedback only if it was pressed
    if (_isMicButtonPressed) {
      setState(() {
        _isMicButtonPressed = false;
      });
    }

    String? recordedPath; // Variable to hold the path

    try {
      debugPrint("Attempting to stop recording...");
      recordedPath = await _recorder.stop(); // Wait for stop to complete
      debugPrint("Recording stopped. Path: $recordedPath");

      if (recordedPath != null && recordedPath.isNotEmpty) {
        // Add a placeholder to the UI immediately for the audio message itself
        // This is separate from the "Analyzing..." message added by the send function
        setState(() {
          _chatHistory.add({
            "type": "audio", // Keep type for potential UI rendering
            "sender": "user", // Audio is from the user
            "content": recordedPath, // Store path for reference
            "message": "🎤 Your recorded audio" // Display text for the audio message
          });
        });
        debugPrint("Audio added to chat history UI: $recordedPath");

        // --- >>> CALL THE NEW FUNCTION TO SEND AUDIO TO GEMINI <<< ---
        // Define the prompt you want to send *with* the audio.
        // You could also get this from a text field if you want users
        // to type a question *about* the audio.
        String audioInstruction = "Understand the user's request in this audio about public transport in USM, Penang.";

        // Trigger the API call (this will handle adding "Analyzing..." and the final response)
        _sendAudioQueryToGemini(
            recordedPath,
            audioInstruction
        );

        // --- <<< END OF NEW CALL <<< ---

      } else {
        debugPrint("Stop recording returned null or empty path. Recording might have been too short or failed.");
        if (mounted) { // Check if widget is still in the tree
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to record audio. Try holding longer.")),
          );
        }
      }
    } catch (e) {
      debugPrint("Error stopping/processing recording: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error processing recording: ${e.toString()}")),
        );
      }
      // Ensure mic button visual state is reset on error too
      setState(() { _isMicButtonPressed = false; });
    } finally {
      // Recording attempt finished (successfully or with error), mark as not busy
      setState(() {
        _isBusyRecording = false;
      });
    }
  } // End of _stopAndSendRecording
  // --- NEW METHOD: Sends Audio + Prompt to Gemini ---
  Future<void> _sendAudioQueryToGemini(String audioPath,
      String baseInstruction) async {
    // --- Safety check for audio path ---
    if (audioPath.isEmpty) {
      debugPrint("Error: Audio path is empty.");
      // Update chat history with error
      setState(() {
        _chatHistory = List<Map<String, dynamic>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing audio...")
          ..add({"sender": "ai", "message": "⚠️ Error: Could not find recorded audio file."});
      });
      return;
    }

    // --- Get API Key ---
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('Error: No Gemini API key found');
      setState(() {
        _chatHistory = List<Map<String, dynamic>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing audio...")
          ..add({"sender": "ai", "message": "⚠️ Error: API Key not configured."});
      });
      return;
    }

    // --- Prepare for API Call ---
    // Update UI to show analysis is in progress
    setState(() {
      // Add a placeholder message that we'll replace later
      _chatHistory.add({"sender": "ai", "message": "🔄 Analyzing audio..."});
    });


    try {
      final ctx = await _fetchBusContext();
      final List<Map<String,dynamic>> freshStops = ctx['stops'] as List<Map<String,dynamic>>;
      final Map<String,String> freshAssignments = ctx['assignments'] as Map<String,String>;
      final Map<String,dynamic> fetchedSegmentsRaw = ctx['segments'];
      final Map<String,List<Map<String,dynamic>>> freshSegments = {};
      fetchedSegmentsRaw.forEach((key, value) {
        if (value is List) {
          // Attempt to cast, handle potential errors if list items aren't maps
          try {
            freshSegments[key] = List<Map<String,dynamic>>.from(value.map((item) => item as Map<String,dynamic>));
          } catch (e) {
            debugPrint("Warning: Could not cast segments for $key in _sendAudioQueryToGemini. Items might not be Maps.");
            freshSegments[key] = []; // Assign empty list on error
          }
        } else {
          freshSegments[key] = [];
        }
      });
      final audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        throw Exception("Audio file does not exist at path: $audioPath");
      }
      final audioBytes = await audioFile.readAsBytes();
      final base64Audio = base64Encode(audioBytes);
      final mimeType = "audio/m4a";
      final fullPrompt = _buildEnhancedAudioPrompt(
          baseInstruction,
          freshStops,
          freshAssignments,
          freshSegments
      );
      debugPrint("--- Sending Audio Prompt to AI ---");
      debugPrint(fullPrompt);


      final requestBody = jsonEncode({
        "contents": [
          {
            "parts": [
              {"text": fullPrompt}, // The text prompt accompanying the audio
              {
                "inlineData": {
                  "mimeType": mimeType,
                  "data": base64Audio // The Base64 encoded audio data
                }
              }
            ]
          }
        ],
        // Optional: Add generationConfig if needed, similar to your text call
        "generationConfig": {
          "temperature": 0.7, // Example config
          "maxOutputTokens": 1024, // Example config
        }
      });

      // --- Make the API Call ---
      // Use a model that explicitly supports multimodal input (audio+text)
      // e.g., 'gemini-1.5-flash-latest' or 'gemini-1.5-pro-latest'
      // Update the URL if necessary based on documentation.
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: requestBody,
      ).timeout(const Duration(seconds: 90)); // Increased timeout for audio

      debugPrint("Gemini Audio response status: ${response.statusCode}");
      debugPrint("Gemini Audio response body: ${response.body.substring(0, min(response.body.length, 500))}...");

      String messageText;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Extract text response
        messageText = data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? "Could not extract response text.";
        if (data['candidates'] == null || data['candidates'].isEmpty) {
          final blockReason = data['promptFeedback']?['blockReason'];
          messageText = blockReason != null ? "⚠️ Response blocked: $blockReason" : "⚠️ Received an empty response from the AI.";
        } else if (data['candidates']?[0]?['finishReason'] == 'MAX_TOKENS') {
          messageText += "\n\n[Response may be truncated]";
        }
      } else {
        String errorDetail = response.body;
        try {
          final errorJson = jsonDecode(response.body);
          errorDetail = errorJson['error']?['message'] ?? response.body;
        } catch (_) {}
        messageText = "⚠️ API Error ${response.statusCode}: $errorDetail";
      }

      setState(() {
        _chatHistory = List<Map<String, dynamic>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing audio...")
          ..add({"sender": "ai", "message": messageText});
      });


    } catch (e) {
      debugPrint("Error sending audio query: $e");
      // Update chat history with error, replacing "Analyzing..."
      setState(() {
        _chatHistory = List<Map<String, dynamic>>.from(_chatHistory)
          ..removeWhere((msg) => msg["message"] == "🔄 Analyzing audio...")
          ..add({"sender": "ai", "message": "⚠️ Error processing audio: ${e.toString()}"});
      });
    }
  }
  Future<Map<String, dynamic>> _fetchBusContext() async {
    // a) all stops
    List<Map<String, dynamic>> stops = [];
    Map<String, String> assignments = {};
    Map<String, List<Map<String, dynamic>>> segments = {};

    try {
      // a) Fetch busStops (this remains the same, reads crowd/eta from busStops collection)
      final stopsSnap = await FirebaseFirestore.instance.collection('busStops').get();
      stops = stopsSnap.docs.map((d) {
        final data = d.data();
        final p = data['location'] as GeoPoint?;
        final crowdRaw = data['crowd'];
        final etaRaw = data['eta'];
        final int crowdValue = (crowdRaw is num) ? crowdRaw.toInt() : 0;
        final int etaValue = (etaRaw is num) ? etaRaw.toInt() : -1;
        return {
          'name': data['name'] ?? 'Unknown Stop',
          'location': (p != null) ? LatLng(p.latitude, p.longitude) : LatLng(0, 0),
          'crowd': crowdValue, // Crowd from busStops collection
          'eta': etaValue,     // ETA from busStops collection (might be different from busActivity)
        };
      }).toList();

      // b) Fetch live busActivity (assignments & the NEW stops structure)
      final actSnap = await FirebaseFirestore.instance.collection('busActivity').get();
      assignments = <String, String>{};
      segments = <String, List<Map<String, dynamic>>>{}; // Initialize for new structure

      for (var doc in actSnap.docs) {
        final d = doc.data();
        final busId = doc.id;
        final busCode = d['busCode'] as String?;
        // --- Read the 'stops' field as a List ---
        final stopsListRaw = d['stops'] as List?;

        if (busCode != null) {
          assignments[busId] = busCode;

          // --- Process the new structured stops list from busActivity ---
          if (stopsListRaw != null) {
            final List<Map<String, dynamic>> currentBusStopsData = [];
            for (var item in stopsListRaw) {
              if (item is Map) {
                final name = item['name'] as String?;
                final etaRaw = item['eta']; // ETA from busActivity
                final crowdRaw = item['crowd']; // Crowd from busActivity

                final int etaValue = (etaRaw is num) ? etaRaw.toInt() : -1;
                final int crowdValue = (crowdRaw is num) ? crowdRaw.toInt() : 0;

                if (name != null) {
                  currentBusStopsData.add({
                    'name': name,
                    'eta': etaValue,     // Use ETA from busActivity
                    'crowd': crowdValue, // Use Crowd from busActivity
                  });
                } else {
                  debugPrint("⚠️ _fetchBusContext: Found stop map without 'name' in busActivity/${doc.id}. Skipping item.");
                }
              } else {
                debugPrint("⚠️ _fetchBusContext: Item in 'stops' list in busActivity/${doc.id} is not a Map. Skipping item.");
              }
            }
            segments[busId] = currentBusStopsData; // Assign the processed list
          } else {
            debugPrint("⚠️ _fetchBusContext: 'stops' field missing/null in busActivity/${doc.id}. Assigning empty list.");
            segments[busId] = [];
          }
          // --- End processing ---
        } else {
          debugPrint("⚠️ _fetchBusContext: Missing 'busCode' in busActivity/${doc.id}. Skipping.");
        }
      }
    } catch (e) {
      debugPrint("Error fetching bus context: $e");
      return { 'stops': [], 'assignments': {}, 'segments': {}, };
    }

    return {
      'stops': stops, // This is still the list from busStops collection
      'assignments': assignments,
      'segments': segments, // This now holds the List<Map{name, eta, crowd}> from busActivity
    };
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
  String _buildEnhancedPrompt(
      String query,
      List<Map<String, dynamic>> stops, // Use parameter
      Map<String, String> busAssignments, // Use parameter
      Map<String, List<Map<String, dynamic>>> activeBusSegments
      ) {
    final limitedStops = stops.take(5).toList();
    String busInfo = "ACTIVE BUSES:\n";
    _busAssignments.forEach((busId, busCode) {
      final stopsDataForBus = (activeBusSegments ?? {})[busId] ?? [];
      final stopNamesString = stopsDataForBus.map((s) => s['name'] ?? 'Unknown').join(' → ');
      final nextStopName = stopsDataForBus.isNotEmpty ? (stopsDataForBus.first['name'] ?? 'Unknown') : 'None';
      busInfo += """
  🚌 $busCode
  - Current Stops: $stopNamesString
  - Next Stop: $nextStopName
  
  """;
    });

    final stopsInfo = (stops ?? []).map((stop) {
      // Find which buses serve this stop
      final stopName = stop['name'] as String?;
      if (stopName == null) return "";
      final servingBuses = (busAssignments ?? {}).entries.where((entry) {
        final busStopsData = (activeBusSegments ?? {})[entry.key] ?? [];
        return busStopsData.any((s) => s['name'] == stopName);
      }).map((e) => e.value).toList();

      // Ensure crowd and eta are handled safely if potentially null
      final crowd = stop['crowd'] ?? '?';
      final eta = stop['eta'] ?? '?';

      return """
    🚏 ${stop['name'] ?? 'Unknown'}
    - 👥 Crowd: $crowd people
    - ⏱️ ETA: $eta minutes
    - 🚌 Serving Buses: ${servingBuses.isNotEmpty ? servingBuses.join(', ') : 'None'}
    """;
    }).join('\n');

    String liveStopDetails = "LIVE STOP DETAILS (from active buses):\n";
    (activeBusSegments ?? {}).forEach((busId, stopsData) {
      final busCode = busAssignments[busId] ?? 'Unknown Bus';
      liveStopDetails += "For Bus $busCode:\n";
      if (stopsData.isEmpty) {
        liveStopDetails += "  - No stop data available.\n";
      } else {
        stopsData.forEach((stopData) {
          liveStopDetails += "  - 🚏 ${stopData['name'] ?? 'Unknown'}: Crowd: ${stopData['crowd'] ?? '?'}, ETA: ${stopData['eta'] ?? '?'} min\n";
        });
      }
    });

    // Construct the final prompt string using busInfo, stopsInfo, and query
    return """
  You are SmartMove, an expert public transportation assistant in Gelugor, Penang, Malaysia.
  Provide concise, actionable advice based on this real-time data:

  CONTEXT:
  $busInfo

  GENERAL BUS STOP INFO (may be slightly delayed):
  $stopsInfo

  LIVE STOP DETAILS (ETA/Crowd from active buses):
  $liveStopDetails

  USER'S QUESTION: $query

  RESPONSE REQUIREMENTS:
1. Understand the user's question.
2. Use the provided CONTEXT and LIVE STOP DETAILS primarily...
3. Start with the most relevant recommendation...
4. Include specific stop names, **live** crowd levels, and **live** ETAs...
5. **ETA Interpretation:** If a bus's ETA is negative, it means bus has passed by the destination asked by user. if 0, it means, its approaching to the destination
6. Keep response concise and clear.
7. Format clearly with emojis.

  NOW ANSWER THE USER'S QUESTION:
  """;
  }

  void _sendUserQuery(String query) async {
    if (query.trim().isEmpty) return;
    final userMessage = {"sender": "user", "message": query};
    final analyzingMessage = {"sender": "ai", "message": "🔄 Analyzing..."};
    // Create a temporary ID to easily find the analyzing message later
    final analyzingMessageId = analyzingMessage.hashCode.toString() + DateTime.now().millisecondsSinceEpoch.toString();
    analyzingMessage["id"] = analyzingMessageId; // Add ID to the map

    _chatController.clear(); // Clear input field
    if (mounted) { // Check mounted before initial setState
      setState(() {
        _chatHistory.add(userMessage);
        _chatHistory.add(analyzingMessage);
      });
      // Scroll to bottom after adding messages
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_sheetScrollController?.hasClients ?? false) {
          _sheetScrollController?.animateTo(
            _sheetScrollController!.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      return; // Don't proceed if not mounted
    }


    try {
      // Fetch context (this part seems okay now with previous fixes)
      final ctx = await _fetchBusContext();
      final stops = ctx['stops'] as List<Map<String, dynamic>>;
      final assignments = ctx['assignments'] as Map<String, String>;
      final segments = ctx['segments'] as Map<String, List<Map<String, dynamic>>>;

      final prompt = _buildEnhancedPrompt(
        query,
        stops,
        assignments,
        segments,
      );

      // Call the API
      debugPrint("--- Calling AI for Text Query ---");
      final response = await _callVertexAIPrediction(prompt);
      debugPrint("--- AI Response Received for Text Query ---");
      debugPrint("Response: $response"); // Log the received response

      // --- FIX: Update UI safely after await ---
      if (!mounted) return; // Check if still mounted after await

      // Create a new list from the current history
      final updatedHistory = List<Map<String, dynamic>>.from(_chatHistory);
      // Find and remove the analyzing message using its ID
      updatedHistory.removeWhere((msg) => msg["id"] == analyzingMessageId);
      // Add the actual AI response
      updatedHistory.add({"sender": "ai", "message": response});

      // Update the state with the new list
      setState(() {
        _chatHistory = updatedHistory;
      });
      debugPrint("Chat history updated with AI response.");
      // --- END FIX ---

    } catch (e) {
      debugPrint("Chat error in _sendUserQuery: $e");
      if (!mounted) return; // Check if still mounted after await in catch

      // --- FIX: Update UI safely on error ---
      final updatedHistory = List<Map<String, dynamic>>.from(_chatHistory);
      // Find and remove the analyzing message using its ID
      updatedHistory.removeWhere((msg) => msg["id"] == analyzingMessageId);
      // Add the error message
      updatedHistory.add({
        "sender": "ai",
        "message": "⚠️ Error: ${e.toString().replaceAll('Exception: ', '')}"
      });
      // Update the state with the new list
      setState(() {
        _chatHistory = updatedHistory;
      });
      debugPrint("Chat history updated with error message.");
      // --- END FIX ---

    } finally {
      // Scroll to bottom after response/error is processed
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_sheetScrollController?.hasClients ?? false)) {
          _sheetScrollController?.animateTo(
            _sheetScrollController!.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }
  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
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
              _sheetScrollController = scrollController;
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
                      itemBuilder: (context, index) {
                        final chat = _chatHistory[index];
                        final isUser = chat["sender"] == "user";

                        // Skip if message is empty (safety check)
                        if (chat["message"]?.isEmpty ?? true) return SizedBox.shrink();
                        if (chat["type"] == "image") {
                        return Image.file(File(chat["content"]));
                        }
                        if (chat["type"] == "audio") {
                        return Row(
                        children: [
                          IconButton(
                          icon: Icon(Icons.play_arrow),
                          onPressed: () {
                          },
                          ),
                          Text("Voice message"),
                        ],
                          );
                        }
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
                  // Near the bottom of the _showChatModal Column's children:
                  Padding(
                    padding: EdgeInsets.only(bottom: 10, top: 8, left: 8, right: 8),
                    child: Row(
                      children: [
                        IconButton( // Keep the image button
                          icon: Icon(Icons.image),
                          onPressed: _pickImage,
                        ),

                        // REPLACE the mic IconButton with this GestureDetector:
                        GestureDetector(
                          onLongPressStart: (_) => _startRecording(), // Start on press down
                          onLongPressEnd: (_) => _stopAndSendRecording(), // Stop on release
                          child: Container( // Wrap Icon in Container for visual feedback
                            padding: EdgeInsets.all(8.0), // Similar padding to IconButton
                            decoration: BoxDecoration(
                              color: _isMicButtonPressed ? Colors.red[100] : Colors.transparent, // Highlight when pressed
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.mic, // Keep the mic icon
                              color: _isMicButtonPressed ? Colors.red : Theme.of(context).iconTheme.color, // Change color when pressed
                            ),
                          ),
                        ),
                        // END of GestureDetector replacement

                        Expanded( // Keep the TextField
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
                        ElevatedButton( // Keep the Send button
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
    );
  }
}