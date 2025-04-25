import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';
import 'package:smart_move/screens/route_screen.dart'; // ← make sure this exists
import 'firebase_options.dart';

/// Custom HttpOverrides class to bypass certificate validation (DEV ONLY)
class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set global HttpOverrides (development only - DO NOT use in production)
  HttpOverrides.global = MyHttpOverrides();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(NoCramApp());
}

class NoCramApp extends StatefulWidget {
  @override
  State<NoCramApp> createState() => _NoCramAppState();
}

class _NoCramAppState extends State<NoCramApp> {
  int _selectedIndex = 0;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    FirebaseAuth.instance.authStateChanges().listen((user) {
      setState(() {
        _currentUser = user;
      });
    });
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> _screens = [
      HomeScreen(),
      _currentUser != null ? RouteScreen() : AltRoutesScreen(),
      ProfileScreen(),
    ];

    return MaterialApp(
      home: HomeScreen(),
    );
  }
}
