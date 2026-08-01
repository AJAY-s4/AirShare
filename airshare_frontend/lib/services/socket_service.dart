import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  io.Socket? get socket => _socket;

  /// Live Render backend production URL
  static const String _liveServerUrl =
      'https://airshare-backend-ngcb.onrender.com';

  String get _serverUrl => _liveServerUrl;

  void connect() {
    if (_socket != null && (_socket!.connected || _socket!.active)) return;

    _socket = io.io(
      _serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect() // Enable auto-connect
          .build(),
    );

    _socket!.connect();

    _socket!.onConnect((_) {
      debugPrint('Connected to live Socket.IO server at $_serverUrl');
    });

    _socket!.onDisconnect((_) {
      debugPrint('Disconnected from Socket.IO server');
    });

    _socket!.onConnectError((err) {
      debugPrint('Socket Connect Error: $err');
    });
  }

  Future<String?> createRoom() async {
    connect();

    // Wait up to 10 seconds (100 attempts * 100ms) for cold starts on Render
    int attempts = 0;
    while ((_socket == null || !_socket!.connected) && attempts < 100) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (_socket == null || !_socket!.connected) {
      debugPrint('Failed to connect to socket server in time.');
      return null;
    }

    final completer = Completer<String?>();

    _socket!.emitWithAck('create-room', [], ack: (response) {
      if (!completer.isCompleted) {
        if (response != null && response is Map && response['pin'] != null) {
          completer.complete(response['pin'].toString());
        } else if (response != null && response is String) {
          completer.complete(response);
        } else {
          completer.complete(null);
        }
      }
    });

    _socket!.once('room-created', (data) {
      if (!completer.isCompleted) {
        final pin = data is Map ? data['pin'] : data;
        completer.complete(pin?.toString());
      }
    });

    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        debugPrint('createRoom timed out waiting for server response.');
        completer.complete(null);
      }
    });

    return completer.future;
  }

  Future<bool> joinRoom(String pin) async {
    connect();

    int attempts = 0;
    while ((_socket == null || !_socket!.connected) && attempts < 100) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (_socket == null || !_socket!.connected) return false;

    final completer = Completer<bool>();

    _socket!.emitWithAck('join-room', [
      {'pin': pin}
    ], ack: (response) {
      if (!completer.isCompleted) {
        if (response != null &&
            response is Map &&
            response['success'] == true) {
          completer.complete(true);
        } else {
          completer.complete(false);
        }
      }
    });

    Future.delayed(const Duration(seconds: 10), () {
      if (!completer.isCompleted) completer.complete(false);
    });

    return completer.future;
  }

  // --- WebRTC Signaling Relay Methods ---

  void sendOffer(String pin, Map<String, dynamic> offer) {
    _socket?.emit('webrtc-offer', {'pin': pin, 'offer': offer});
  }

  void sendAnswer(String pin, Map<String, dynamic> answer) {
    _socket?.emit('webrtc-answer', {'pin': pin, 'answer': answer});
  }

  void sendIceCandidate(String pin, Map<String, dynamic> candidate) {
    _socket?.emit('ice-candidate', {'pin': pin, 'candidate': candidate});
  }

  void disconnect() {
    _socket?.disconnect();
    _socket = null;
  }
}
