import 'package:flutter/material.dart';

class SuccessRedeemScreen extends StatelessWidget {
  final String name, mobile;
  final int    redeemedPts;

  const SuccessRedeemScreen({
    Key? key,
    required this.name,
    required this.mobile,
    required this.redeemedPts,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.purple[100],
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 48),
          child: Column(
            children: [
              // ——— Big Tick
              CircleAvatar(
                radius: 60,
                backgroundColor: Colors.white,
                child: Image.asset('assets/tick.png', width: 80, height: 80),
              ),

              SizedBox(height: 24),
              Text(
                'Redeem Successful',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),

              SizedBox(height: 24),
              // ——— Details Box
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Name: $name'),
                    SizedBox(height: 8),
                    Text('Mobile: $mobile'),
                    SizedBox(height: 8),
                    Text('Amount: $redeemedPts points'),
                  ],
                ),
              ),

              Spacer(),

              // ——— OK Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // Pop all the way back to HomeScreen:
                    Navigator.popUntil(context, (route) => route.isFirst);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text('OK'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
