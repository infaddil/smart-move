// lib/main.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/bus_tracker.dart';
import 'package:smart_move/screens/live_crowd_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:smart_move/screens/route_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';

import 'firebase_options.dart';

/// DEV ONLY: allow self-signed certs
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, __, ___) => true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // DEV ONLY: bypass bad certs
  HttpOverrides.global = MyHttpOverrides();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await dotenv.load(fileName: ".env");

  runApp(NoCramApp());
}

class NoCramApp extends StatefulWidget {
  @override
  _NoCramAppState createState() => _NoCramAppState();
}

class _NoCramAppState extends State<NoCramApp> {
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    _listenAuth();
  }

  void _listenAuth() {
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      setState(() {
        _currentUser = user;
      });
      if (user != null) {
        // fetch role from Firestore (assumes you have a 'users' collection)
        final doc = await FirebaseAuth.instance.currentUser!
            .reload() // ensure latest token
            .then((_) => FirebaseAuth.instance.currentUser!);
        final roleSnap = await FirebaseAuth.instance.currentUser!
            .getIdTokenResult(); // you could encode role in custom claims
        // OR fetch separately:
        final data = await FirebaseAuth.instance.currentUser!.reload()
            .then((_) => FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get());
        setState(() {
          _userRole = data.data()?['role'] as String?;
        });
      } else {
        setState(() {
          _userRole = null;
        });
      }
    });
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final isDriver = _userRole == 'driver';

    // Define tabs based on role
    final passengerScreens = <Widget>[
      HomeScreen(),
      BusTrackerScreen(),
      LiveCrowdScreen(),
      AltRoutesScreen(),
      ProfileScreen(),
    ];
    final passengerItems = <BottomNavigationBarItem>[
      BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
      BottomNavigationBarItem(icon: Icon(Icons.directions_bus), label: 'Tracker'),
      BottomNavigationBarItem(icon: Icon(Icons.people_alt_outlined), label: 'Live Crowd'),
      BottomNavigationBarItem(icon: Icon(Icons.alt_route), label: 'Alt Transport'),
      BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
    ];

    final driverScreens = <Widget>[
      HomeScreen(),
      RouteScreen(),
      ProfileScreen(),
    ];
    final driverItems = <BottomNavigationBarItem>[
      BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
      BottomNavigationBarItem(icon: Icon(Icons.alt_route), label: 'Route'),
      BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
    ];

    final screens = isDriver ? driverScreens : passengerScreens;
    final items   = isDriver ? driverItems   : passengerItems;

    // Ensure selected index is in range
    if (_selectedIndex >= screens.length) {
      _selectedIndex = 0;
    }

    return MaterialApp(
      title: 'No Cram for USM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.purple),
      home: Scaffold(
        body: IndexedStack(
          index: _selectedIndex,
          children: screens,
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          items: items,
        ),
      ),
    );
  }
}
