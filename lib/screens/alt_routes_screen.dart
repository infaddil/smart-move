import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';

class AltRoutesScreen extends StatefulWidget {
  @override
  _AltRoutesScreenState createState() => _AltRoutesScreenState();
}

class _AltRoutesScreenState extends State<AltRoutesScreen> {
  bool leastWalking = true;
  bool nearestStop = false;
  bool lowestHeadcount = false;
  bool bicycle = false;
  bool walking = false;

  String? selectedDestination;
  String? selectedOrigin;
  LatLng? currentLocation;

  final List<Map<String, dynamic>> _busStops = [
    {'name': 'DK A', 'location': LatLng(5.358472063851898, 100.30358172014454)},
    {'name': 'Desasiswa Tekun', 'location': LatLng(5.356164243999046, 100.29137000150655)},
    {'name': 'Padang Kawad USM', 'location': LatLng(5.356575824397347, 100.29438698781404)},
    {'name': 'Aman Damai', 'location': LatLng(5.355016860781792, 100.29772995685882)},
    {'name': 'Informm', 'location': LatLng(5.355756904620433, 100.30022534653023)},

    {'name': 'Stor Pusat Kimia', 'location': LatLng(5.356432270401126, 100.30096914945585)},
    {'name': 'BHEPA', 'location': LatLng(5.35921073913782, 100.30250488384392)},
    {'name': 'DKSK', 'location': LatLng(5.359404468217731, 100.30451729410511)},
    {'name': 'SOLLAT', 'location': LatLng(5.357330653809769, 100.30720848569456)},
    {'name': 'GSB', 'location': LatLng(5.356934272035779, 100.30757773835158)},

    {'name': 'HBP', 'location': LatLng(5.355040006814353, 100.30626811136635)},
    {'name': 'Eureka', 'location': LatLng(5.354770901747802, 100.30414474646078)},
    {'name': 'Harapan', 'location': LatLng(5.355241844849605, 100.29968061136645)},
    {'name': 'Indah Kembara', 'location': LatLng(5.355791916604481, 100.29544875369481)},
    {'name': 'Jabatan Keselamatan', 'location': LatLng(5.355676144659425, 100.29790864945589)},

    {'name': 'Nasi Kandar Subaidah USM', 'location': LatLng(5.35689190629461, 100.30459688993344)},
    {'name': 'M07 USM', 'location': LatLng(5.356677224370704, 100.28989391453047)},
    {'name': 'M01 USM', 'location': LatLng(5.356141098470615, 100.28953752062004)}
  ];

  @override
  void initState() {
    super.initState();
    _getLocation();
  }

  Future<void> _getLocation() async {
    final hasPermission = await Geolocator.checkPermission();
    if (hasPermission == LocationPermission.denied || hasPermission == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();
    }

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() {
      currentLocation = LatLng(position.latitude, position.longitude);
    });
  }

  double _calculateDistance(LatLng from, LatLng to) {
    return Geolocator.distanceBetween(from.latitude, from.longitude, to.latitude, to.longitude) / 1000.0;
  }

  int _estimateETA(double distanceKm, {bool isWalking = false, bool isBike = false}) {
    if (isWalking) return (distanceKm / 4.8 * 60).round();
    if (isBike) return (distanceKm / 15 * 60).round();
    return (distanceKm / 25 * 60).round();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        title: Text('Suggested transportation'),
      ),
      body: Column(
        children: [
          _searchSection(),
          _preferencesButton(),
          Expanded(child: _suggestedRoutesList()),
        ],
      ),
    );
  }

  Widget _searchSection() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            decoration: InputDecoration(
              labelText: "From",
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
            value: selectedOrigin,
            items: _busStops.map((stop) {
              return DropdownMenuItem<String>(
                value: stop['name'],
                child: Text(stop['name']),
              );
            }).toList(),
            onChanged: (value) => setState(() => selectedOrigin = value),
          ),
          SizedBox(height: 10),
          DropdownButtonFormField<String>(
            decoration: InputDecoration(
              labelText: "To",
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
            value: selectedDestination,
            items: _busStops.map((stop) {
              return DropdownMenuItem<String>(
                value: stop['name'],
                child: Text(stop['name']),
              );
            }).toList(),
            onChanged: (value) => setState(() => selectedDestination = value),
          ),
          SizedBox(height: 10),
          currentLocation != null
              ? Text("Current Location: ${currentLocation!.latitude.toStringAsFixed(4)}, ${currentLocation!.longitude.toStringAsFixed(4)}")
              : CircularProgressIndicator(),
          SizedBox(height: 10),
          Text("Depart now", style: TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _preferencesButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: ElevatedButton(
        onPressed: _showPreferencesBottomSheet,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.purple,
          foregroundColor: Colors.white,
        ),
        child: Text("Transportation Preferences"),
      ),
    );
  }

  void _showPreferencesBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Route Preference", style: TextStyle(fontWeight: FontWeight.bold)),
            ListTile(
              title: Text("Least walking"),
              leading: Radio<bool>(
                value: true,
                groupValue: leastWalking,
                onChanged: (value) => setState(() => leastWalking = true),
              ),
            ),
            ListTile(
              title: Text("Shortest time"),
              leading: Radio<bool>(
                value: false,
                groupValue: leastWalking,
                onChanged: (value) => setState(() => leastWalking = false),
              ),
            ),
            Divider(color: Colors.grey[400]),
            Text("Bus Stop Preferences", style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              value: nearestStop,
              onChanged: (value) => setState(() => nearestStop = value),
              title: Text("Nearest stop"),
            ),
            SwitchListTile(
              value: lowestHeadcount,
              onChanged: (value) => setState(() => lowestHeadcount = value),
              title: Text("Lowest people headcount"),
            ),
            SwitchListTile(
              value: bicycle,
              onChanged: (value) => setState(() => bicycle = value),
              title: Text("Bicycle"),
            ),
            SwitchListTile(
              value: walking,
              onChanged: (value) => setState(() => walking = value),
              title: Text("Walking"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestedRoutesList() {
    if (selectedOrigin == null || selectedDestination == null) {
      return Center(child: Text("Please select both origin and destination."));
    }

    final origin = _busStops.firstWhere((stop) => stop['name'] == selectedOrigin);
    final destination = _busStops.firstWhere((stop) => stop['name'] == selectedDestination);
    final distance = _calculateDistance(origin['location'], destination['location']);

    return ListView(
      padding: EdgeInsets.all(16),
      children: [
        _routeCard(
          "Bus ETA: ${_estimateETA(distance)} mins",
          "From ${origin['name']} to ${destination['name']} (${distance.toStringAsFixed(2)} km)",
          Icons.directions_bus,
        ),
        _routeCard(
          "Walk ETA: ${_estimateETA(distance, isWalking: true)} mins",
          "From ${origin['name']} to ${destination['name']} walking",
          Icons.directions_walk,
        ),
        _routeCard(
          "Bike ETA: ${_estimateETA(distance, isBike: true)} mins",
          "From ${origin['name']} to ${destination['name']} cycling",
          Icons.pedal_bike,
        ),
      ],
    );
  }

  Widget _routeCard(String title, String subtitle, IconData icon) {
    return Card(
      color: Colors.white,
      child: ListTile(
        leading: Icon(icon, color: Colors.purple),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        onTap: () {
          // You can navigate to a map route here or show more details
        },
      ),
    );
  }
}