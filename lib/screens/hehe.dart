import 'package:flutter/material.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/alt_routes_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';
import 'package:smart_move/widgets/nav_bar.dart';

class MainWrapper extends StatefulWidget {
  @override
  _MainWrapperState createState() => _MainWrapperState();
}

class _MainWrapperState extends State<MainWrapper> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    HomeScreen(),
    AltRoutesScreen(),
    DriverProfileScreen(),
  ];

  void _onTap(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavBar(
        currentIndex: _selectedIndex,
        onTap: _onTap,
      ),
    );
  }
}
