import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';

// ─── Firebase background handler ────────────────────────────────────────────
// Must be a top-level function — runs in a separate isolate when app is killed.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  final data = message.data;
  if (data['type'] == 'incoming_call') {
    await CallNotificationHandler.showIncomingCall(data);
  } else if (data['type'] == 'call_cancelled') {
    final roomName = data['roomName'];
    if (roomName != null) {
      await CallNotificationHandler.endCall(roomName);
    }
  }
}

// ─── Navigator key (needed for CallKit accept from background/killed) ────────
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ─── Entry point ─────────────────────────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  // Initialize SDK — requests mic + camera permissions.
  await SocialIqLiveSdk.initialize(
    serverUrl: 'wss://live.iqamasocial.com',
    socketUrl: 'https://connect.iqamasocial.com',
    apiBaseUrl: 'https://connect.iqamasocial.com',
    // socketUrl:  'http://192.168.0.100:8000',
    // apiBaseUrl: 'http://192.168.0.100:8000',
  );

  // Start listening for CallKit accept / decline taps (background → foreground).
  CallNotificationHandler.initialize();

  runApp(MyApp(navigatorKey: navigatorKey));
}

// ─── App ─────────────────────────────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SDK Demo',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const DemoHomePage(),
    );
  }
}

// ─── Demo home ────────────────────────────────────────────────────────────────
class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  // In a real app these come from your auth layer.
  final String userId = 'user_${Random().nextInt(1000)}';
  final String userName = 'Test User';
  final String userToken = 'dummy_token';

  final TextEditingController _targetUserIdCtrl = TextEditingController();

  late final SocketService _socketService;
  bool _isShowingIncomingCall = false; // guard against duplicate call screens

  // ── Lifecycle helpers ────────────────────────────────────────────────────
  void _onCallStarted() => debugPrint('▶ Call started');
  void _onCallConnected() => debugPrint('✅ Call connected — media live');
  void _onCallEnded(Duration d) => debugPrint('🔴 Call ended after $d');

  // ── Init ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    // Socket — foreground incoming calls.
    _socketService = SocketService();
    _socketService.connect(
      url: SocialIqLiveSdkConfig.socketUrl,
      authToken: userToken,
    );
    _socketService.registerUser(userId);
    // Re-register after any reconnection so the second call always arrives.
    _socketService.onConnect.listen((_) => _socketService.registerUser(userId));
    _listenForIncomingCallsViaSocket();

    // CallKit — fired when user taps Accept / Decline on the native call UI
    // (background or killed-app path via FCM).
    _listenForCallKitEvents();

    // Foreground FCM — shows native call UI even when app is in foreground so
    // both paths (socket + FCM) are unified through CallKit.
    FirebaseMessaging.onMessage.listen(_handleForegroundFcm);

    // Register FCM token with backend so it can wake this device.
    _registerFcmToken();

    // Android 13+ — request notification permission at runtime.
    FirebaseMessaging.instance.requestPermission();
  }

  // ── Socket foreground path ────────────────────────────────────────────────
  void _listenForIncomingCallsViaSocket() {
    _socketService.onIncomingCall.listen((data) {
      if (!mounted) return;
      if (_isShowingIncomingCall) return; // deduplicate
      _isShowingIncomingCall = true;

      final callType = data['callType'] == 'video'
          ? CallType.video
          : CallType.audio;
      final callerName = data['callerName'] as String? ?? 'Unknown';
      final callerAvatar = data['callerAvatar'] as String?;
      final callerId = data['callerId'] as String;
      final roomName = data['roomName'] as String;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            callerName: callerName,
            callerAvatar: callerAvatar,
            callType: callType,
            onAccept: () {
              Navigator.pop(context);
              _isShowingIncomingCall = false;
              _openCallScreen(
                callType: callType,
                callerId: callerId,
                roomName: roomName,
                callerName: callerName,
                callerAvatar: callerAvatar,
                isIncoming: true,
              );
            },
            onDecline: () {
              Navigator.pop(context);
              _isShowingIncomingCall = false;
              _socketService.rejectCall(callerId: callerId, receiverId: userId);
            },
          ),
        ),
      ).then((_) {
        _isShowingIncomingCall = false;
      });
    });
  }

  // ── CallKit path (background / killed app) ────────────────────────────────
  void _listenForCallKitEvents() {
    // Accept — navigate to the appropriate call screen.
    CallNotificationHandler.onCallAccepted.listen((data) {
      final isVideo = data['callType'] == 'video';
      final _ = isVideo ? CallType.video : CallType.audio;
      final callerId = data['callerId'] ?? '';
      final roomName = data['roomName'];
      final callerName = data['callerName'];
      final callerAvatar = data['callerAvatar'];

      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => isVideo
              ? VideoCallScreen(
                  userToken: userToken,
                  callerId: callerId,
                  receiverId: userId,
                  roomName: roomName,
                  isIncoming: true,
                  incomingCallerName: callerName,
                  incomingCallerAvatar: callerAvatar,
                  onCallStarted: _onCallStarted,
                  onCallConnected: _onCallConnected,
                  onCallEnded: _onCallEnded,
                )
              : AudioCallScreen(
                  userToken: userToken,
                  callerId: callerId,
                  receiverId: userId,
                  roomName: roomName,
                  isIncoming: true,
                  callerName: callerName,
                  callerAvatar: callerAvatar,
                  onCallStarted: _onCallStarted,
                  onCallConnected: _onCallConnected,
                  onCallEnded: _onCallEnded,
                ),
        ),
      );
    });

    // Decline — notify the caller.
    CallNotificationHandler.onCallDeclined.listen((data) {
      final callerId = data['callerId'] ?? '';
      _socketService.rejectCall(callerId: callerId, receiverId: userId);
    });
  }

  // ── Foreground FCM handler ────────────────────────────────────────────────
  void _handleForegroundFcm(RemoteMessage message) {
    final data = message.data;
    if (data['type'] == 'incoming_call') {
      // Show native CallKit UI (flutter_callkit_incoming deduplicates by roomName).
      CallNotificationHandler.showIncomingCall(data);
    } else if (data['type'] == 'call_cancelled') {
      final roomName = data['roomName'];
      if (roomName != null) {
        CallNotificationHandler.endCall(roomName);
      }
    }
  }

  // ── FCM token registration ────────────────────────────────────────────────
  Future<void> _registerFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      await _uploadFcmToken(token);

      // Re-upload if the token rotates.
      FirebaseMessaging.instance.onTokenRefresh.listen(_uploadFcmToken);
    } catch (e) {
      debugPrint('FCM token registration failed: $e');
    }
  }

  Future<void> _uploadFcmToken(String token) async {
    try {
      await http.post(
        Uri.parse('${SocialIqLiveSdkConfig.apiBaseUrl}/v1/api/fcm-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $userToken',
        },
        body: jsonEncode({
          'userId': userId,
          'token': token,
          'platform': Platform.isIOS ? 'ios' : 'android',
        }),
      );
      debugPrint('FCM token uploaded');
    } catch (e) {
      debugPrint('FCM token upload failed: $e');
    }
  }

  // ── Common call-screen opener ─────────────────────────────────────────────
  void _openCallScreen({
    required CallType callType,
    required String callerId,
    String? roomName,
    String? callerName,
    String? callerAvatar,
    String? receiverName,
    String? receiverAvatar,
    bool isIncoming = false,
  }) {
    if (callType == CallType.video) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoCallScreen(
            userToken: userToken,
            callerId: callerId,
            receiverId: userId,
            roomName: roomName,
            isIncoming: isIncoming,
            incomingCallerName: callerName,
            incomingCallerAvatar: callerAvatar,
            receiverName: receiverName,
            receiverAvatar: receiverAvatar,
            onCallStarted: _onCallStarted,
            onCallConnected: _onCallConnected,
            onCallEnded: _onCallEnded,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AudioCallScreen(
            userToken: userToken,
            callerId: callerId,
            receiverId: userId,
            roomName: roomName,
            isIncoming: isIncoming,
            callerName: callerName ?? receiverName,
            callerAvatar: callerAvatar ?? receiverAvatar,
            receiverName: receiverName,
            receiverAvatar: receiverAvatar,
            onCallStarted: _onCallStarted,
            onCallConnected: _onCallConnected,
            onCallEnded: _onCallEnded,
          ),
        ),
      );
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _socketService.dispose();
    _targetUserIdCtrl.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SDK Demo Home'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Identity card ──────────────────────────────────────────
              Card(
                margin: const EdgeInsets.only(bottom: 20),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(
                        'My User ID',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      SelectableText(
                        userId,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text('Name: $userName'),
                    ],
                  ),
                ),
              ),

              // ── Target user field ──────────────────────────────────────
              TextField(
                controller: _targetUserIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Target User ID (Host / Receiver)',
                  hintText: 'Paste the other user\'s ID here',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_search),
                ),
              ),
              const SizedBox(height: 16),

              // ── Broadcast ──────────────────────────────────────────────
              const Divider(),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Live Broadcast',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.live_tv),
                  label: const Text('Start Broadcast (Host)'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LiveBroadcastHost(
                          userToken: userToken,
                          identity: userId,
                          displayName: userName,
                          title: 'Test Broadcast',
                          onLiveEnded: (duration) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Broadcast ended after $duration',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.ondemand_video),
                  label: const Text('Join Broadcast (Viewer)'),
                  onPressed: () {
                    final target = _targetUserIdCtrl.text.trim();
                    if (target.isEmpty) {
                      _showSnack('Enter a target user ID first');
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LiveBroadcastViewer(
                          userToken: userToken,
                          identity: userId,
                          displayName: userName,
                          roomName: 'live_$target',
                          hostName: 'Host $target',
                          onLiveEnded: () => Navigator.pop(context),
                        ),
                      ),
                    );
                  },
                ),
              ),

              // ── Calls ──────────────────────────────────────────────────
              const Divider(),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '1:1 Calls',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.videocam),
                  label: const Text('Start Video Call'),
                  onPressed: () {
                    final target = _targetUserIdCtrl.text.trim();
                    if (target.isEmpty) {
                      _showSnack('Enter a target user ID first');
                      return;
                    }
                    _openCallScreen(
                      callType: CallType.video,
                      callerId: userId,
                      receiverName: 'User $target',
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.phone),
                  label: const Text('Start Audio Call'),
                  onPressed: () {
                    final target = _targetUserIdCtrl.text.trim();
                    if (target.isEmpty) {
                      _showSnack('Enter a target user ID first');
                      return;
                    }
                    _openCallScreen(
                      callType: CallType.audio,
                      callerId: userId,
                      receiverName: 'User $target',
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
