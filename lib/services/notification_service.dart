import 'dart:async';
import 'dart:math'; // For Random ID generation
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

// Assume the rest of the NotificationService class (initialize, constants, etc.) is defined above

class NotificationService {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();
  StreamSubscription? _busActivitySubscription;
  LatLng? _currentUserLocation;
  final Set<String> _recentlyNotifiedEvents = {};
  Timer? _clearCacheTimer;

  // Constants
  static const double PROXIMITY_THRESHOLD_METERS = 1000.0;
  static const int LOW_CROWD_THRESHOLD = 20;
  static const String ANDROID_CHANNEL_ID = 'smart_move_bus_channel';
  static const String ANDROID_CHANNEL_NAME = 'SmartMove Bus Alerts';
  static const String ANDROID_CHANNEL_DESCRIPTION =
      'Notifications for nearby bus arrivals';

  // --- METHOD THAT PROCESSES THE DATA ---
  void _processSnapshot(QuerySnapshot snapshot, LatLng userLocation) {
    // print("[NotificationService] Received ${snapshot.docs.length} activity docs."); // Optional debug log
    for (var doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) continue;

      final busCode = data['busCode'] as String?;
      final stopsListRaw = data['stops'] as List?;

      if (busCode == null || stopsListRaw == null) {
        continue;
      }

      for (var stopDataRaw in stopsListRaw) {
        if (stopDataRaw is Map<String, dynamic>) {
          final stopName = stopDataRaw['name'] as String?;
          final etaRaw = stopDataRaw['eta'];
          final crowdRaw = stopDataRaw['crowd'];
          final locationRaw = stopDataRaw['location'] as GeoPoint?;

          final int? eta = (etaRaw is num) ? etaRaw.toInt() : null;
          final int? crowd = (crowdRaw is num) ? crowdRaw.toInt() : null;
          final LatLng? stopLocation = locationRaw != null
              ? LatLng(locationRaw.latitude, locationRaw.longitude)
              : null;

          if (stopName != null &&
              eta != null &&
              crowd != null &&
              stopLocation != null) {
            bool isEtaOneMinute = (eta == 1);
            bool isCrowdLow = (crowd < LOW_CROWD_THRESHOLD);

            double distanceInMeters = Geolocator.distanceBetween(
              userLocation.latitude,
              userLocation.longitude,
              stopLocation.latitude,
              stopLocation.longitude,
            );
            bool isNearUser = (distanceInMeters < PROXIMITY_THRESHOLD_METERS);

            if (isEtaOneMinute && isCrowdLow && isNearUser) {
              String eventKey = "${busCode}_${stopName}_${doc.id}";
              if (_recentlyNotifiedEvents.contains(eventKey)) {
                continue;
              }

              print(
                  "[NotificationService] *** Conditions MET for $stopName (Bus $busCode) ***");
              String notificationTitle = "Bus $busCode Approaching!";
              String notificationBody =
                  "Bus $busCode will come at $stopName in 1 minute. Consider go to this stop as it has only $crowd people and near to your current location";

              _sendNotification(
                  title: notificationTitle, body: notificationBody);

              _recentlyNotifiedEvents.add(eventKey);
            }
          }
        }
      }
    }
  }

  // --- METHOD THAT SENDS THE NOTIFICATION ---
  Future<void> _sendNotification(
      {required String title, required String body}) async {

    // Use a consistent high-priority channel
    AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      ANDROID_CHANNEL_ID,
      ANDROID_CHANNEL_NAME,
      channelDescription: ANDROID_CHANNEL_DESCRIPTION,
      importance: Importance.max,
      priority: Priority.high,
      // --- ADD THIS STYLE INFORMATION ---
      styleInformation: BigTextStyleInformation(
        body, // Use the full body text here
        htmlFormatBigText: false, // Set to true if body contains HTML
        contentTitle: title, // Optional: Repeat title in expanded view
        htmlFormatContentTitle: false,
        summaryText: 'Bus Alert', // Optional: Text when collapsed in shade
        htmlFormatSummaryText: false,
      ),
      // --- END STYLE INFORMATION ---
      ticker: 'Bus Alert',
    );

    // Basic iOS details (can be customized further)
    DarwinNotificationDetails iOSDetails = const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: iOSDetails,
    );

    int notificationId = Random().nextInt(2147483647);

    try {
      print(
          "[NotificationService] Sending notification (ID: $notificationId)...");
      await _flutterLocalNotificationsPlugin.show(
        notificationId,
        title,
        body, // The standard body is still needed for the initial banner line
        platformDetails,
      );
      print("[NotificationService] Notification sent successfully.");
    } catch (e) {
      print("[NotificationService] Error sending notification: $e");
    }
  }
  Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');
    final DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings(
      requestAlertPermission: true, // Set true for foreground alerts on iOS
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    final InitializationSettings initializationSettings =
    InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    await _flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
    );
    await _createNotificationChannel();
    await _requestPermissions();
    await _updateUserLocationAndStartListener();
    _clearCacheTimer?.cancel();
    _clearCacheTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      if (_recentlyNotifiedEvents.isNotEmpty) {
        print("[NotificationService] Clearing recently notified cache.");
        _recentlyNotifiedEvents.clear();
      }
    });
    print("[NotificationService] Initialized successfully.");
  }

  Future<void> _createNotificationChannel() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      ANDROID_CHANNEL_ID,
      ANDROID_CHANNEL_NAME,
      description: ANDROID_CHANNEL_DESCRIPTION,
      importance: Importance.max,
    );
    await _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    print("[NotificationService] Android Notification Channel ensured.");
  }

  Future<void> _requestPermissions() async {
    bool locationGranted = await Permission.location.isGranted;
    if (!locationGranted) {
      print("[NotificationService] Requesting location permission...");
      await Permission.location.request();
    }
    bool notificationGranted = await Permission.notification.isGranted;
    if (!notificationGranted) {
      print("[NotificationService] Requesting notification permission...");
      await Permission.notification.request();
    }
  }

  Future<void> _updateUserLocationAndStartListener() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      print("[NotificationService] Location services are disabled.");
      return;
    }
    PermissionStatus permission = await Permission.location.status;
    if (permission.isDenied || permission.isPermanentlyDenied) {
      print("[NotificationService] Location permission not granted.");
      return;
    }
    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 15));
      _currentUserLocation = LatLng(position.latitude, position.longitude);
      print("[NotificationService] User location updated: $_currentUserLocation");
      startListening();
    } catch (e) {
      print("[NotificationService] Error getting location: $e");
    }
  }

  void startListening() {
    if (_currentUserLocation == null) {
      print("[NotificationService] Cannot start listening: User location unknown.");
      return;
    }
    if (_busActivitySubscription != null) {
      print("[NotificationService] Firestore listener already active.");
      return;
    }
    print("[NotificationService] Starting Firestore listener...");
    _busActivitySubscription = FirebaseFirestore.instance
        .collection('busActivity')
        .snapshots()
        .listen((snapshot) {
      if (_currentUserLocation == null) {
        print(
            "[NotificationService] Skipping snapshot processing: User location became null.");
        return;
      }
      _processSnapshot(snapshot, _currentUserLocation!);
    }, onError: (error) {
      print("[NotificationService] Firestore Listener Error: $error");
      _busActivitySubscription?.cancel();
      _busActivitySubscription = null;
      Future.delayed(const Duration(seconds: 30), () => startListening());
    });
  }

  void stopListening() {
    print("[NotificationService] Stopping Firestore listener.");
    _busActivitySubscription?.cancel();
    _busActivitySubscription = null;
    _clearCacheTimer?.cancel();
    _clearCacheTimer = null;
  }

  void dispose() {
    stopListening();
    print("[NotificationService] Disposed.");
  }

  Future<void> manualSendTestNotification() async {
    print("[NotificationService] Manually triggering test notification.");
    await _sendNotification(
      title: "Test Notification",
      body: "If you see this, the plugin is working!",
    );
  }

} // End of NotificationService class