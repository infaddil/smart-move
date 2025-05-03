// lib/screens/redeem_reward_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:smart_move/screens/success_redeem_screen.dart';
import 'package:smart_move/screens/home_screen.dart';
import 'package:smart_move/screens/profile_screen.dart';

class RedeemRewardScreen extends StatefulWidget {
  final int currentPoints;
  const RedeemRewardScreen({Key? key, required this.currentPoints})
      : super(key: key);

  @override
  _RedeemRewardScreenState createState() => _RedeemRewardScreenState();
}

class _RedeemRewardScreenState extends State<RedeemRewardScreen> {
  final _formKey    = GlobalKey<FormState>();
  final _nameCtrl   = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _phoneCtrl  = TextEditingController();

  late final int _maxRedeemable;   // e.g. 120 → 100
  int _selectedPoints = 0;
  int _navBarIndex = 2;

  @override
  void initState() {
    super.initState();
    // only full 50-point chunks up to max:
    _maxRedeemable  = (widget.currentPoints ~/ 50) * 50;
    // start slider at the maximum chunk:
    _selectedPoints = _maxRedeemable;
  }

  double get _convertedRM => _selectedPoints / 100;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _mobileCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final uid    = FirebaseAuth.instance.currentUser!.uid;
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    // atomically deduct selected points
    await userRef.update({
      'points': FieldValue.increment(-_selectedPoints),
    });

    // navigate to success screen
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => SuccessRedeemScreen(
          name:        _nameCtrl.text,
          mobile:      _mobileCtrl.text,
          redeemedPts: _selectedPoints,
        ),
      ),
    );
  }
  void _onNavBarTapped(int index) {
    // This logic needs to navigate *back* to the main structure
    // usually involving Navigator.popUntil and potentially passing the index
    // to main.dart's state. This can get complex.
    // A simpler, though less ideal, approach might be pushReplacementNamed
    // if you have named routes set up for your main screens.

    // Example: Popping back to the root (main.dart's screen)
    if (index != _navBarIndex) {
      // You'd typically pop back to the screen that handles the main IndexedStack
      // and tell *it* to switch to the desired index.
      // For now, let's just pop this screen.
      if (Navigator.canPop(context)) {
        Navigator.pop(context, index); // Pass intended index back if needed
      }
      // If you cannot pop (e.g., this was the first screen), you might
      // navigate to the home screen using pushReplacement.
      // else {
      //   Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainScreenWidget())); // Replace with your actual main screen handler
      // }
    }
    // Note: Directly managing the main screen state from here is complex.
    // The nav bar here primarily serves visual consistency.
    // Proper navigation might require a different app structure or state management (like Provider/Riverpod).
  }


  @override
  Widget build(BuildContext context) {
    final passengerItems = <BottomNavigationBarItem>[ //
      BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'), //
      BottomNavigationBarItem(icon: Icon(Icons.alt_route), label: 'Route'),
      BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'), //
    ];
    final items = passengerItems; // Replace with role logic if needed

    return Scaffold(
      backgroundColor: Colors.purple[100],
      appBar: AppBar(
        backgroundColor: Colors.purple[100],
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        toolbarHeight: 100,
        // Push the title down inside that extra space
        title: Padding(
          padding: const EdgeInsets.only(top: 24.0),
          child: Text(
            'Redeem Rewards',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ),
        iconTheme: IconThemeData(color: Colors.black),
      ),
      body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // — Name field —
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Name', style: TextStyle(fontWeight: FontWeight.bold))),
              SizedBox(height: 8),
              TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                validator: (v) => v!.isEmpty ? 'Enter your name' : null,
              ),

              SizedBox(height: 16),
              // — Mobile field —
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Mobile Number',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              SizedBox(height: 8),
              TextFormField(
                controller: _mobileCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                validator: (v) => v!.isEmpty ? 'Enter your mobile number' : null,
              ),

              SizedBox(height: 24),
              // — Slider label & conversion —
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      'Select points to redeem (${_selectedPoints} pts ＝ RM${_convertedRM.toStringAsFixed(2)})',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Slider(
                min: 0,
                max: _maxRedeemable.toDouble(),
                divisions: (_maxRedeemable ~/ 50),
                value: _selectedPoints.toDouble(),
                label: '$_selectedPoints',
                onChanged: (v) {
                  setState(() {
                    // snap to nearest 50
                    _selectedPoints = (v ~/ 50) * 50;
                  });
                },
              ),
              Text('Rate: 100 points = RM1',
                  style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic)),
              SizedBox(height: 8),
              Text(
                'Funds will be credited to your Touch ’n Go account.',
                style: TextStyle(fontSize: 14),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Image.asset(
                  'assets/tng.png',
                  width: 120,   // adjust to fit your design
                  height: 60,
                  fit: BoxFit.contain,
                ),
              ),
              // — Submit button —
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _onSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text('Submit'),
                ),
              ),
            ],
          ),
        ),
      ),),
      bottomNavigationBar: BottomNavigationBar(
        items: items, // Use the items defined above
        currentIndex: _navBarIndex, // Use the state variable
        onTap: _onNavBarTapped, // Use the handler function
        type: BottomNavigationBarType.fixed, // Match main.dart
        // Add other styling from main.dart if needed (e.g., selectedItemColor)
      ),
    );
  }
}
