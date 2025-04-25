import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smart_move/screens/bus_route_service.dart';


class HomeScreen extends StatefulWidget {


  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _searchResultMessage;
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _currentPosition = LatLng (5.354792742851638, 100.30181627359067);
    // _initLocation(); (real later)
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

  Future<void> _fetchUserRole() async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUser!.uid)
        .get();
    setState(() {
      _userRole = doc.data()?['role'];
    });
  }

  Future<void> _initLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) {
      return;
    }
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    setState(() {
      _currentPosition = LatLng(pos.latitude, pos.longitude);
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return Scaffold(
      backgroundColor: Colors.purple[100],
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hello, Intan',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 20),
                // BUS TRACKER BUTTON
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple[600],             // medium–dark purple
                        padding: EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: Icon(Icons.directions_bus, color: Colors.white),
                      label: Text('Bus tracker',
                          style: TextStyle(color: Colors.white, fontSize: 16)),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => BusTrackerScreen()),
                        );
                      },
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  height: MediaQuery.of(context).size.height * 0.75,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  // ← ADD THIS to give inner horizontal (and vertical) breathing room:
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              decoration: InputDecoration(
                                hintText: 'Search destination',
                                prefixIcon: Icon(Icons.search),
                                filled: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (dest) async {
                                // 0) Ensure we know the driver's routeType
                                if (_userRole == null) {
                                  setState(() {
                                    _searchResultMessage =
                                    'Still loading your route info… please try again in a moment.';
                                  });
                                  return;
                                }
                                final busType = _userRole!;  // "A", "B" or "C"

                                // 1) Get the current + next segments
                                final assigns =
                                await BusRouteService().getAssignments(busType);
                                final current = assigns['current']!;
                                final next    = assigns['next']!;

                                // 2) Look up the destination
                                final inCurrent = current.firstWhere(
                                      (s) => s['name'].toLowerCase() == dest.toLowerCase(),
                                  orElse: () => {},
                                );

                                String msg;
                                if (inCurrent.isNotEmpty) {
                                  msg = 'Current bus $busType is going to $dest in '
                                      '${inCurrent['eta']} min';
                                } else {
                                  final inNext = next.firstWhere(
                                        (s) => s['name'].toLowerCase() == dest.toLowerCase(),
                                    orElse: () => {},
                                  );
                                  if (inNext.isNotEmpty) {
                                    msg = 'Wait for next bus $busType as current won’t pick you up. '
                                        'ETA ${inNext['eta']} min';
                                  } else {
                                    msg = 'No $busType bus serving $dest right now.';
                                  }
                                }

                                setState(() {
                                  _searchResultMessage = msg;
                                });
                              },
                            ),

                            // 3) Result card, sibling to the TextField
                            if (_searchResultMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Card(
                                  color: Colors.purple[50],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Text(
                                      _searchResultMessage!,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      SizedBox(height: 12),

                      // your map container, unchanged:
                      Container(
                        height: 150,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: _currentPosition != null
                            ? ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: GoogleMap(
                            initialCameraPosition: CameraPosition(
                              target: _currentPosition!,
                              zoom: 15,
                            ),
                            onMapCreated: (c) => _mapController = c,

                            // ← add this:
                            onTap: (LatLng tappedPoint) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LiveCrowdScreen(
                                    initialLocation: _currentPosition!,
                                  ),
                                ),
                              );
                            },
                            myLocationEnabled: true,
                            zoomControlsEnabled: false,
                          ),
                        )
                            : Center(child: CircularProgressIndicator()),
                      ),
                      SizedBox(height: 12),

                      // your ListView, unchanged:
                      ListView(
                        shrinkWrap: true,
                        physics: NeverScrollableScrollPhysics(),
                        children: [
                          _sectionCard(
                            'Frequent destination',
                            'To: Your school\n • 10 minutes • Arrive at 9:51 am',
                          ),
                          SizedBox(height: 10),
                          _sectionCard(
                            'Favourites',
                            '🏫 Your school: School of Computer Sciences\n🏋️‍♀️ Gym: Tan Sri Azman Hashim Centre',
                          ),
                          SizedBox(height: 10),
                          _sectionCard(
                            'Recent journeys',
                            'Hamzah Sendut 2 → KOMCA\nNasi Kandar RM1 → USM',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 16), // bottom spacing so scroll doesn’t end flush to nav bar
              ],
            ),
          ),
        ),
      ),

      bottomNavigationBar: BottomNavBar(
        selectedIndex: _selectedIndex,
        onItemTapped: _onItemTapped,
      ),
    );
  }

  Widget _iconButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(radius: 28, child: Icon(icon, size: 28)),
          SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _sectionCard(String title, String content) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 6),
            Text(content),
          ],
        ),
      ),
    );
  }
}