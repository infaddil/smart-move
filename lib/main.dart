import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform, // ⬅️ Pass correct config
  );
  runApp(NoCramApp());
}

class NoCramApp extends StatefulWidget {
  @override
  State<NoCramApp> createState() => _NoCramAppState();
}

class _NoCramAppState extends State<NoCramApp> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    HomeScreen(),
    AltRoutesScreen(),
    DriverProfileScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: _screens[_selectedIndex],
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.alt_route), label: 'Alt routes'),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
