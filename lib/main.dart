import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/alt_routes_screen.dart';
import 'screens/profile_screen.dart';

void main() {
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
    //AltRoutesScreen(),
    //ProfileScreen(),
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
