import 'package:flutter/material.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:smart_move/screens/route_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BottomNavBar extends StatefulWidget {
  final int selectedIndex;
  final Function(int) onItemTapped;

  const BottomNavBar({
    required this.selectedIndex,
    required this.onItemTapped,
  });

  @override
  _BottomNavBarState createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  String role = '';

  @override
  void initState() {
    super.initState();
    _fetchUserRole();
  }

  Future<void> _fetchUserRole() async {
    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        String userId = user.uid;
        DocumentSnapshot userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .get();

        if (userDoc.exists) {
          setState(() {
            role = userDoc['role'] ?? 'other';
            print('Role fetched: $role');
          });
        } else {
          print('User document does not exist');
        }
      } else {
        print('No user logged in');
      }
    } catch (e) {
      print('Error fetching user role: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    print('Role in build method: $role');
    return BottomNavigationBar(
      backgroundColor: Color(0xFF3F3F3F),
      selectedItemColor: Colors.yellow,
      unselectedItemColor: Colors.grey,
      currentIndex: widget.selectedIndex,
      onTap: (int index) {
        if (index == 0) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => HomeScreen(),
            ),
          );
        } else if (index == 1) {
          if (role != 'driver') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => LiveCrowdScreen(),
              ),
            );
          } else if (role == 'driver') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => RouteScreen(),
              ),
            );
          }
        } else if (index == 2) {
          if (role != 'driver') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => AltRoutesScreen(),
              ),
            );
          } else if (role == 'driver') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => RouteScreen(),
              ),
            );
          }
        }else if (index == 3) {
          if (role != 'driver') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => AltRoutesScreen(),
              ),
            );
          }
        } else if (index == 4) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ProfileScreen(),
            ),
          );
        }
      },
      type: BottomNavigationBarType.fixed,
      items: <BottomNavigationBarItem>[
        BottomNavigationBarItem(
          icon: Image.asset(
            'assets/home.png',
            height: 30,
            width: 30,
          ),
          label: 'Home',
        ),
        BottomNavigationBarItem(
          icon: role == 'driver'
              ? const SizedBox.shrink()        // no icon for drivers
              : Image.asset(
            'assets/crowd.png',
            height: 30,
            width: 30,
          ),
          label: role == 'driver' ? '' : 'Crowd',  // no label for drivers
        ),
        BottomNavigationBarItem(
          icon: Image.asset(
            role == 'driver'
                ? 'assets/alt_routes.png'
                : 'assets/public_transport.png',
            height: 30,
            width: 30,
          ),
          label: role == 'driver' ? 'Route' : 'Alt Transport',
        ),
        BottomNavigationBarItem(
          icon: role == 'driver'
              ? const SizedBox.shrink()        // no icon for drivers
              : Image.asset(
            'assets/history.png',
            height: 30,
            width: 30,
          ),
          label: role == 'driver' ? '' : 'Trips',  // no label for drivers
        ),
        BottomNavigationBarItem(
          icon: Image.asset(
            'assets/profile.png',
            height: 30,
            width: 30,
          ),
          label: 'Profile',
        ),
      ],
    );
  }
}