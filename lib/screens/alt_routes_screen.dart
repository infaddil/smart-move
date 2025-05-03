import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:smart_move/widgets/nav_bar.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:smart_move/screens/PaymentWebview.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'dart:convert';

class AltRoutesScreen extends StatefulWidget {
  @override
  _AltRoutesScreenState createState() => _AltRoutesScreenState();
}

class _AltRoutesScreenState extends State<AltRoutesScreen> {
  int _selectedIndex = 0;
  User? _currentUser;
  String? _userRole;
  bool leastWalking = true;
  bool nearestStop = false;
  bool lowestHeadcount = false;
  bool bicycle = false;
  bool walking = true;
  bool scooter = false;

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

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  Future<void> _getLocation() async {
    // --- Improved Permission Handling ---
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      debugPrint("Location permission denied, requesting...");
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        debugPrint("Location permission denied after request.");
        if (mounted) { // Check mounted before showing Snackbar
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Location permission is required to show alternatives from your location."))
          );
        }
        return; // Exit if permission is still denied
      }
    }

    // --- Get Location with Error Handling ---
    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // --- Add Mounted Check ---
      if (mounted) { // Check if the widget is still mounted BEFORE setState
        setState(() {
          currentLocation = LatLng(position.latitude, position.longitude);
        });
      }
      // --- End Mounted Check ---

    } catch (e) {
      debugPrint("Error getting current position in AltRoutesScreen: $e");
      if (mounted) { // Check mounted before showing Snackbar on error
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error getting location: ${e.toString()}"))
        );
      }
    }
  }

  double _calculateDistance(LatLng from, LatLng to) {
    return Geolocator.distanceBetween(from.latitude, from.longitude, to.latitude, to.longitude) / 1000.0;
  }

  // ETA calculation based on speed (bus: 25 km/h, walking: 4.8 km/h, bike: 15 km/h)
  int _estimateETA(double distanceKm, {bool isWalking = false, bool isBike = false}) {
    if (isWalking) return (distanceKm / 4.8 * 60).round();
    if (isBike) return (distanceKm / 15 * 60).round();
    return (distanceKm / 25 * 60).round();
  }
  Future<void> _navigateToPayment(String provider, double distance) async {
    // --- Check for necessary data ---
    final secretKey = dotenv.env['TOYYIBPAY_SECRET_KEY'];
    final categoryCode = dotenv.env['TOYYIBPAY_CATEGORY_CODE'];

    if (secretKey == null || categoryCode == null) {
      print('Error: ToyyibPay Secret Key or Category Code not found in .env file');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Payment configuration error.")),
        );
      }
      return; // Stop execution if keys are missing
    }

    // --- TODO: Get User Details ---
    // You need the user's name, email, and phone for the ToyyibPay API.
    // Fetch these from Firestore using _currentUser or use placeholder/default values.
    String userName = _currentUser?.displayName ?? "Smart Move User"; // Example placeholder
    String userEmail = _currentUser?.email ?? "user@example.com"; // Example placeholder
    String userPhone = "0123456789"; // Example placeholder - You might need to fetch this from Firestore

    // --- TODO: Calculate Amount ---
    // Calculate the price based on the provider and distance.
    // ToyyibPay expects the amount in *cents* as a String (e.g., "1000" for RM10.00).
    double priceRM;
    if (provider == "Beam") {
      // Example: RM 1.50 base + RM 0.50 per km
      priceRM = 1.50 + (distance * 0.50);
    } else if (provider == "Bike Commute USM") {
      // Example: Flat rate RM 2.00
      priceRM = 2.00;
    } else {
      priceRM = 1.00; // Default fallback?
    }
    // Convert RM to cents and then to string
    String amountInCents = (priceRM * 100).toInt().toString();


    // --- Prepare donationData (if needed by PaymentWebView) ---
    // This seems specific to a donation flow in the original example.
    // Adapt or remove if not needed for your booking scenario.
    Map<String, dynamic> bookingData = {
      'provider': provider,
      'distance_km': distance.toStringAsFixed(2),
      'calculated_amount_rm': priceRM.toStringAsFixed(2),
      'userId': _currentUser?.uid ?? 'unknown',
      // Add any other data you want to pass to PaymentWebView or use after payment
    };

    // --- Create ToyyibPay Bill ---
    try {
      print('Attempting to create ToyyibPay bill...'); // Debug print
      final response = await http.post(
        Uri.parse('https://toyyibpay.com/index.php/api/createBill'),
        body: {
          'userSecretKey': secretKey,
          'categoryCode': categoryCode,
          'billName': 'Bike Commute: $provider', // More specific name
          'billDescription': 'Booking for $provider for approx ${distance.toStringAsFixed(2)} km', // More specific description
          'billPriceSetting': '1', // 0 = Not Fixed, 1 = Fixed Price
          'billPayorInfo': '1', // 0 = Hide, 1 = Show Payor Info Fields
          'billAmount': amountInCents, // Amount in cents
          // --- TODO: Update Return/Callback URLs ---
          // Use appropriate URLs for your app (deep links or web URLs)
          'billReturnUrl': 'https://yourdomain.com/payment-success', // Replace with your actual success URL/deeplink
          'billCallbackUrl': 'https://yourdomain.com/payment-callback', // Replace with your actual callback URL/deeplink
          'billExternalReferenceNo': 'SM-${provider.substring(0,min(provider.length,3))}-${DateTime.now().millisecondsSinceEpoch}', // Unique ref number
          'billTo': userName,
          'billEmail': userEmail,
          'billPhone': userPhone,
          'billSplitPayment': '0', // 0 = No Split, 1 = Split Payment Allowed
          'billPaymentChannel': '0', // 0 = Both FPX & Card, 1 = FPX only, 2 = Card only
          'billDisplayMerchant': '1' // 0 = Hide Merchant Name, 1 = Show
          // Optional: 'billContentEmail': 'Thank you for your payment!'
        },
      );

      print('ToyyibPay Response Status Code: ${response.statusCode}'); // Debug print
      print('ToyyibPay Response Body: ${response.body}'); // Debug print

      if (response.statusCode == 200) {
        // Check if response body is valid JSON and expected format
        try {
          final data = jsonDecode(response.body);
          // ToyyibPay often returns a list with one object
          if (data is List && data.isNotEmpty && data[0]['BillCode'] != null) {
            final billCode = data[0]['BillCode'];
            final url = 'https://toyyibpay.com/$billCode';
            print('Successfully created bill. Navigating to: $url'); // Debug print

            // --- Check if mounted before navigating ---
            if (!mounted) return;

            // Navigate to your PaymentWebView
            Navigator.push(
              context,
              MaterialPageRoute(
                // Pass the URL and any booking data needed by the WebView screen
                builder: (_) => PaymentWebView(paymentUrl: url, bookingData: bookingData), // Pass bookingData instead of donationData
              ),
            );
          } else {
            print("ToyyibPay response format unexpected: ${response.body}");
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Failed to process payment response.")),
              );
            }
          }
        } catch (e) {
          print("Error decoding ToyyibPay JSON response: $e");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Error reading payment response.")),
            );
          }
        }

      } else {
        print("ToyyibPay bill creation failed: ${response.body}");
        if (mounted) { // Check mounted before showing Snackbar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to initiate payment (Code: ${response.statusCode}).")),
          );
        }
      }
    } catch (e) {
      print("Error during HTTP request to ToyyibPay: $e");
      if (mounted) { // Check mounted before showing Snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("An error occurred while connecting to payment gateway.")),
        );
      }
    }
  }
// A reusable, “sleek” dropdown widget
  /// A reusable, “sleek” dropdown widget
  Widget _sleekDropdown({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade100),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButtonFormField<String>(
          value: value,
          dropdownColor: Colors.white,
          icon: Icon(Icons.keyboard_arrow_down, color: Colors.purple[700]),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: Colors.purple[700], fontWeight: FontWeight.w600),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: InputBorder.none,
          ),
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        backgroundColor: Colors.purple[100],
        elevation: 0,
        toolbarHeight: 80,
        centerTitle: true,

        iconTheme: IconThemeData(color: Colors.black),
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),

        // no more manual top-padding here—AppBar will center it vertically
        title: Text('Alternative transportation'),
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
    final names = _busStops.map((s) => s['name'] as String).toList();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sleekDropdown(
            label: 'From',
            value: selectedOrigin,
            items: names,
            onChanged: (v) => setState(() => selectedOrigin = v),
          ),
          SizedBox(height: 10),
          _sleekDropdown(
            label: 'To',
            value: selectedDestination,
            items: names,
            onChanged: (v) => setState(() => selectedDestination = v),
          ),
          SizedBox(height: 10),
          currentLocation != null
              ? Text(
              "Current Location: ${currentLocation!.latitude.toStringAsFixed(4)}, "
                  "${currentLocation!.longitude.toStringAsFixed(4)}")
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
      isScrollControlled: true, // Add this for potentially taller sheets
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        // Wrap the Column with SingleChildScrollView
        child: SingleChildScrollView( // <--- WRAP HERE
          child: Column(             // <--- Original Column
            mainAxisSize: MainAxisSize.min, // Keep this
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Divider(color: Colors.grey[400]),
              Text("Transportation Preferences", // Renamed from "Bus Stop Preferences"?
                  style: TextStyle(fontWeight: FontWeight.bold)),
              SwitchListTile(
                value: bicycle,
                onChanged: (value) {
                  setState(() {
                    bicycle = value;
                  });
                },
                title: Text("Bicycle (Bike Commute USM)"),
              ),
              SwitchListTile(
                value: scooter,
                onChanged: (value) {
                  setState(() {
                    scooter = value;
                  });
                },
                title: Text("Scooter (Beam)"),
              ),
              SwitchListTile(
                value: walking,
                onChanged: (value) {
                  setState(() {
                    walking = value;
                  });
                },
                title: Text("Walking"),
              ),
              // Add some bottom padding if needed inside the scroll view
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
            ],
          ),
        ), // <--- END SingleChildScrollView WRAP
      ),
    );
  }

  Widget _suggestedRoutesList() {
    if (selectedOrigin == null || selectedDestination == null) {
      return Center(child: Text("Please select both origin and destination."));
    }

    final origin = _busStops.firstWhere((s) => s['name'] == selectedOrigin);
    final destination = _busStops.firstWhere((s) => s['name'] == selectedDestination);
    final directDistance = _calculateDistance(
      origin['location'] as LatLng,
      destination['location'] as LatLng,
    );

    List<Widget> suggestions = [];

    // 1) Lowest-headcount bus
    if (lowestHeadcount) {
      final leastCrowded = _busStops.reduce((a, b) {
        final num crowdA = (a['crowd'] ?? double.infinity) as num;
        final num crowdB = (b['crowd'] ?? double.infinity) as num;
        return crowdA < crowdB ? a : b;
      });

      // 2) Shortest-time bus
    } else if (!leastWalking) {
      final fastestStop = _busStops.reduce((a, b) {
        final etaA = _estimateETA(_calculateDistance(
          origin['location'] as LatLng,
          a['location'] as LatLng,
        ));
        final etaB = _estimateETA(_calculateDistance(
          origin['location'] as LatLng,
          b['location'] as LatLng,
        ));
        return etaA < etaB ? a : b;
      });
      final fastestETA = _estimateETA(_calculateDistance(
        origin['location'] as LatLng,
        fastestStop['location'] as LatLng,
      ));

      // 3) Default (least walking)
    } else {
      final etaDefault = _estimateETA(directDistance);
    }

    // Bike
    if (bicycle) {
      suggestions.add(_routeCard(
        "Bike ETA: ${_estimateETA(directDistance, isBike: true)} mins",
        "Provider: Bike Commute USM",
        Icons.pedal_bike,
        partnerName: "Bike Commute USM",
        onBookNow: () => _navigateToPayment("Bike Commute USM", directDistance),
      ));
    }

    // Scooter
    if (scooter) {
      suggestions.add(_routeCard(
        "Scooter ETA: ${_estimateETA(directDistance, isBike: true)} mins",
        "Provider: Beam",
        Icons.electric_scooter,
        partnerName: "Beam",
        onBookNow: () => _navigateToPayment("Beam", directDistance),
      ));
    }

    // Walking
    if (walking) {
      suggestions.add(_routeCard(
        "Walk ETA: ${_estimateETA(directDistance, isWalking: true)} mins",
        "Walking from ${origin['name']} → ${destination['name']}",
        Icons.directions_walk,
      ));
    }

    return ListView(padding: EdgeInsets.all(16), children: suggestions);
  }

  Widget _routeCard(String title, String subtitle, IconData icon, {VoidCallback? onBookNow, String? partnerName}) {
    return Card(
      color: Colors.white,
      child: Padding( // Add padding for the button
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(icon, color: Colors.purple),
              title: Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(subtitle),
              onTap: () {
                // Optional: Handle tap if needed (e.g., show details)
              },
            ),
            if (onBookNow != null && partnerName != null) // Conditionally show button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: ElevatedButton(
                  onPressed: onBookNow,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green, // Choose a color
                    foregroundColor: Colors.white,
                  ),
                  child: Text("Book Now with $partnerName"),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
