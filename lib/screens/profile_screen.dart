import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:smart_move/widgets/nav_bar.dart';

class ProfileScreen extends StatefulWidget {
  @override
  _ProfileScreenState createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int _selectedIndex = 0;
  User? _currentUser;
  User? _user;
  String? _userRole;
  String? _busNumber;
  // 5 example Malaysian bus plate numbers – adjust as needed.
  final List<String> _busPlates = ['WLY 1234', 'JHR 5581', 'PRK 0198', 'SEL 9201', 'KDH 7113'];
  final TextEditingController _nameController = TextEditingController();

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    if (_currentUser != null) _fetchUserRole();
    _checkSignedInUser();

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
  Future<String> _ensureBusNumber(User user) async {
    final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final docSnapshot = await docRef.get();
    String busNumber;
    if (!docSnapshot.exists ||
        docSnapshot.data()?['busNumber'] == null ||
        (docSnapshot.data()?['busNumber'] as String).isEmpty) {
      busNumber = (_busPlates..shuffle()).first;
      await docRef.set({
        'name': user.displayName ?? 'No Name',
        'email': user.email ?? 'No Email',
        'photoUrl': user.photoURL ?? '',
        'busNumber': busNumber,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print("Assigned new bus number: $busNumber");
    } else {
      busNumber = docSnapshot.data()?['busNumber'] as String;
      print("Retrieved bus number from Firestore: $busNumber");
    }
    return busNumber;
  }

  Future<void> _signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      print('Login cancelled');
      return;
    }
    final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
    final user = userCredential.user;
    if (user == null) return;

    // Ensure bus number is assigned at sign in
    String busNumber = await _ensureBusNumber(user);

    await _saveBusNumber(user.uid, busNumber);
    await _saveName(user.uid, user.displayName ?? '');

    setState(() {
      _user = user;
      _nameController.text = user.displayName ?? '';
      _busNumber = busNumber;
    });
  }

  Future<void> _updateName() async {
    if (_user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(_user!.uid).set({
          'name': _nameController.text,
          'email': _user!.email ?? 'No Email',
          'busNumber': _busNumber ?? '',
        }, SetOptions(merge: true));
        await _saveName(_user!.uid, _nameController.text);
        print("Firestore updated with new name: ${_nameController.text}");
      } catch (e) {
        print("Error updating Firestore: $e");
      }
    }
  }

  Future<void> _saveName(String uid, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name_$uid', name);
  }

  Future<String?> _loadName(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('name_$uid');
  }

  Future<void> _saveBusNumber(String uid, String busNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bus_$uid', busNumber);
  }

  Future<String?> _loadBusNumber(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('bus_$uid');
  }

  void _checkSignedInUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      String busNumber = '';
      final savedBus = await _loadBusNumber(user.uid);
      if (savedBus == null || savedBus.isEmpty) {
        // If local storage is empty, fetch (or assign) from Firestore
        busNumber = await _ensureBusNumber(user);
        await _saveBusNumber(user.uid, busNumber);
      } else {
        busNumber = savedBus;
      }
      final savedName = await _loadName(user.uid);

      setState(() {
        _user = user;
        _nameController.text = savedName ?? user.displayName ?? '';
        _busNumber = busNumber;
      });
    }
  }

  void _signOut() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
    final prefs = await SharedPreferences.getInstance();
    prefs.clear(); // Clears saved name and bus number
    setState(() {
      _user = null;
      _busNumber = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      // Modify the AppBar here
      appBar: AppBar(
        // --- Start Apply New Styles ---
        backgroundColor: Colors.purple[100], // New background color
        elevation: 0,                        // New elevation
        toolbarHeight: 80,                   // New height
        centerTitle: true,                   // Center the title
        iconTheme: IconThemeData(color: Colors.black), // Style for leading icon (if any)
        titleTextStyle: TextStyle(           // Style for the title text
          color: Colors.black,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        title: Text('Profile page'),       // Your new title text
        // --- End Apply New Styles ---

        // --- Keep the existing conditional actions ---
        actions: _user != null
            ? [
          IconButton(
            onPressed: _signOut,
            icon: Icon(
                Icons.logout,
                color: Colors.black // Explicitly set color to match iconTheme
            ),
          )
        ]
            : [], // Show no actions if user is null
        // --- End Keep the existing conditional actions ---
      ),
      body: _user == null ? _buildSignInPrompt() : _buildProfileView(),
    );


  }

  Widget _buildSignInPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.directions_bus, size: 90, color: Colors.purple[100]),
            SizedBox(height: 24),
            Text(
              'Are you a bus driver?\nSign in with your Google account to access your profile.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 30),
            ElevatedButton.icon(
              icon: Icon(Icons.login),
              label: Text('Sign in with Google'),
              onPressed: _signInWithGoogle,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple[100],
                foregroundColor: Colors.black,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildProfileView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundImage: NetworkImage(_user?.photoURL ?? ''),
          ),
          SizedBox(height: 16),
          TextField(
            controller: _nameController,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.purple),
            decoration: InputDecoration(
              border: InputBorder.none,
              suffixIcon: IconButton(
                icon: Icon(Icons.check, color: Colors.grey),
                onPressed: _updateName,
              ),
            ),
          ),
          SizedBox(height: 16),
          _infoTile(Icons.email, _user?.email ?? 'No email'),
          _infoTile(Icons.directions_bus, 'Bus Number: ${_busNumber ?? "Not assigned"}'),
        ],
      ),
    );
  }

  Widget _infoTile(IconData icon, String text) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.purple),
          SizedBox(width: 16),
          Expanded(child: Text(text, style: TextStyle(fontSize: 16))),
        ],
      ),
    );
  }
}