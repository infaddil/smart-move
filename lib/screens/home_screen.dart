import 'package:flutter/material.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LatLng? _currentPosition;
  GoogleMapController? _mapController;
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _initLocation();
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
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, Intan',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _iconButton('Live Crowd', Icons.wifi, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => LiveCrowdScreen()),
                    );
                  }),
                  _iconButton('Alt Routes', Icons.alt_route, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AltRoutesScreen()),
                    );
                  }),
                  _iconButton('My Trips', Icons.receipt_long, () {
                    // TODO: Navigate to My Trips screen
                  }),
                ],
              ),
              SizedBox(height: 16),
              Container(
                height: screenHeight * 0.75,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
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
                      ),
                      SizedBox(height: 12),
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
                                target: _currentPosition!, zoom: 15),
                            onMapCreated: (controller) {
                              _mapController = controller;
                            },
                            myLocationEnabled: true,
                            zoomControlsEnabled: false,
                          ),
                        )
                            : Center(child: CircularProgressIndicator()),
                      ),
                      SizedBox(height: 12),
                      Expanded(
                        child: ListView(
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
                      ),
                    ],
                  ),
                ),
              ),
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