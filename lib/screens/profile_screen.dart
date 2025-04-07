import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DriverProfileScreen extends StatefulWidget {
  @override
  _DriverProfileScreenState createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  User? _user;
  String? _busNumber;
  final List<String> _busPlates = ['PEN 1234', 'USM 5581', 'BUS 0198', 'KTM 9201', 'JPN 7113'];
  final TextEditingController _nameController = TextEditingController();

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
    final docRef = FirebaseFirestore.instance.collection('users').doc(user!.uid);
    final docSnapshot = await docRef.get();

    String busNumber;
    if (!docSnapshot.exists) {
      busNumber = (_busPlates..shuffle()).first;
      await docRef.set({
        'name': user.displayName ?? 'No Name',
        'email': user.email ?? 'No Email',
        'photoUrl': user.photoURL ?? '',
        'busNumber': busNumber,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } else {
      busNumber = docSnapshot.data()?['busNumber'] ?? (_busPlates..shuffle()).first;
    }

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
        print("Firestore updated with name, email, and busNumber.");
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

  @override
  void initState() {
    super.initState();
    _checkSignedInUser();
  }

  void _checkSignedInUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final savedBus = await _loadBusNumber(user.uid);
      final savedName = await _loadName(user.uid);

      setState(() {
        _user = user;
        _nameController.text = savedName ?? user.displayName ?? '';
        _busNumber = savedBus;
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
      appBar: AppBar(
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        title: Text('Driver Profile'),
        actions: _user != null
            ? [IconButton(onPressed: _signOut, icon: Icon(Icons.logout))]
            : [],
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
            Icon(Icons.directions_bus, size: 90, color: Colors.purple),
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
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
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
          _infoTile(Icons.directions_bus, 'Bus Number: $_busNumber'),
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