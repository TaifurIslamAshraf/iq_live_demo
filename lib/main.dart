import 'package:flutter/material.dart';
import 'package:social_iq_live_sdk/social_iq_live_sdk.dart';
import 'dart:math';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SocialIqLiveSdk.initialize(
    serverUrl:  'wss://live.iqamasocial.com',
    socketUrl:  'https://connect.iqamasocial.com',
    apiBaseUrl: 'https://connect.iqamasocial.com',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SDK Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  final String userId = 'user_${Random().nextInt(1000)}';
  final String userName = 'Test User';
  final String userToken = 'dummy_token';

  final TextEditingController _targetUserIdCtrl = TextEditingController();

  // Socket service for receiving incoming calls
  late final SocketService _socketService;
  bool _isShowingIncomingCall = false; // guard against duplicate call screens

  @override
  void initState() {
    super.initState();
    _socketService = SocketService();
    _socketService.connect(
      url: SocialIqLiveSdkConfig.socketUrl,
      authToken: userToken,
    );
    // Register this user so incoming calls from others can reach us
    _socketService.registerUser(userId);
    // Re-register after any reconnection so second calls always arrive
    _socketService.onConnect.listen((_) => _socketService.registerUser(userId));
    _listenForIncomingCalls();
  }

  void _listenForIncomingCalls() {
    _socketService.onIncomingCall.listen((data) {
      if (!mounted) return;
      // Guard: don't push a second incoming-call screen if one is already showing
      if (_isShowingIncomingCall) return;
      _isShowingIncomingCall = true;

      final callType = data['callType'] == 'video' ? CallType.video : CallType.audio;
      final callerName = data['callerName'] as String? ?? 'Unknown';
      final callerAvatar = data['callerAvatar'] as String?;
      final callerId = data['callerId'] as String;
      final roomName = data['roomName'] as String;

      Navigator.push(context, MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callerName: callerName,
          callerAvatar: callerAvatar,
          callType: callType,
          onAccept: () {
            Navigator.pop(context); // close incoming screen
            _isShowingIncomingCall = false;
            if (callType == CallType.video) {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => VideoCallScreen(
                  userToken: userToken,
                  callerId: callerId,
                  receiverId: userId,
                  receiverName: callerName,
                  receiverAvatar: callerAvatar,
                  roomName: roomName,
                  isIncoming: true,
                  incomingCallerName: callerName,
                  onCallEnded: (_) {},
                ),
              ));
            } else {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => AudioCallScreen(
                  userToken: userToken,
                  callerId: callerId,
                  receiverId: userId,
                  receiverName: callerName,
                  receiverAvatar: callerAvatar,
                  roomName: roomName,
                  isIncoming: true,
                  onCallEnded: (_) {},
                ),
              ));
            }
          },
          onDecline: () {
            Navigator.pop(context);
            _isShowingIncomingCall = false;
            _socketService.rejectCall(callerId: callerId, receiverId: userId);
          },
        ),
      )).then((_) {
        // Reset flag if the screen was dismissed by any means (back button, etc.)
        _isShowingIncomingCall = false;
      });
    });
  }

  @override
  void dispose() {
    _socketService.dispose();
    _targetUserIdCtrl.dispose();
    super.dispose();
  }

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
              Text('My User ID: $userId\nName: $userName', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => LiveBroadcastHost(
                      userToken: userToken,
                      identity: userId,
                      displayName: userName,
                      title: 'Test Broadcast',
                      onLiveEnded: (duration) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Broadcast ended after $duration')),
                        );
                      },
                    ),
                  ));
                },
                child: const Text('Start Broadcast (Host)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _targetUserIdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Target User ID (Host/Receiver)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () {
                  final target = _targetUserIdCtrl.text;
                  if (target.isEmpty) return;
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => LiveBroadcastViewer(
                      userToken: userToken,
                      identity: userId,
                      displayName: userName,
                      roomName: 'live_$target',
                      hostName: 'Host $target',
                      onLiveEnded: () => Navigator.pop(context),
                    ),
                  ));
                },
                child: const Text('Join Broadcast (Viewer)'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () {
                  final target = _targetUserIdCtrl.text;
                  if (target.isEmpty) return;
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => VideoCallScreen(
                      userToken: userToken,
                      callerId: userId,
                      receiverId: target,
                      receiverName: 'User $target',
                      onCallEnded: (duration) {},
                    ),
                  ));
                },
                child: const Text('Start Video Call'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () {
                  final target = _targetUserIdCtrl.text;
                  if (target.isEmpty) return;
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => AudioCallScreen(
                      userToken: userToken,
                      callerId: userId,
                      receiverId: target,
                      receiverName: 'User $target',
                      onCallEnded: (duration) {},
                    ),
                  ));
                },
                child: const Text('Start Audio Call'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
