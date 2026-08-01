import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'socket_service.dart';

class WebRTCService {
  final SocketService _socketService = SocketService();
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  bool _isDataChannelOpen = false;

  // Buffer ICE candidates if they arrive before remote description is ready
  final List<RTCIceCandidate> _remoteIceCandidatesBuffer = [];
  bool _isRemoteDescriptionSet = false;

  Function(bool connected)? onConnectionStateChange;
  Function(Uint8List chunk)? onDataReceived;
  Function(String text)? onMessageReceived;

  Future<void> initPeerConnection(String pin, bool isSender) async {
    _remoteIceCandidatesBuffer.clear();
    _isRemoteDescriptionSet = false;

    final configuration = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject'
        },
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'credential': 'openrelayproject'
        }
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    // ICE Candidate Callback
    _peerConnection?.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _socketService.sendIceCandidate(pin, candidate.toMap());
      }
    };

    // Connection State Listener
    _peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint("WebRTC Connection State: $state");
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnectionStateChange?.call(true);
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onConnectionStateChange?.call(false);
        _isDataChannelOpen = false;
      }
    };

    if (isSender) {
      // Sender creates DataChannel
      RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
        ..binaryType = 'binary'
        ..ordered = true;
      _dataChannel = await _peerConnection?.createDataChannel(
          'fileTransfer', dataChannelDict);
      _setupDataChannel();
    } else {
      // Receiver listens for DataChannel
      _peerConnection?.onDataChannel = (channel) {
        _dataChannel = channel;
        _setupDataChannel();
      };
    }

    _registerSignalingEvents(pin);
  }

  void _setupDataChannel() {
    // Initial check
    _isDataChannelOpen = _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
    
    _dataChannel?.onDataChannelState = (RTCDataChannelState state) {
      debugPrint("Data Channel State changed to: $state");
      _isDataChannelOpen = (state == RTCDataChannelState.RTCDataChannelOpen);
    };

    _dataChannel?.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary && onDataReceived != null) {
        onDataReceived!(message.binary);
      } else if (!message.isBinary && onMessageReceived != null) {
        onMessageReceived!(message.text);
      }
    };
  }

  bool sendString(String text) {
    if (_dataChannel != null && _isDataChannelOpen) {
      try {
        _dataChannel?.send(RTCDataChannelMessage(text));
        return true;
      } catch (e) {
        debugPrint("Error sending string: $e");
        return false;
      }
    }
    return false;
  }

  void _registerSignalingEvents(String pin) {
    // 1. OFFER
    _socketService.socket?.on('webrtc-offer', (data) async {
      if (data != null && data['offer'] != null) {
        final offerData = data['offer'];
        var offer = RTCSessionDescription(
          offerData['sdp'],
          offerData['type'],
        );
        await _peerConnection?.setRemoteDescription(offer);
        _isRemoteDescriptionSet = true;
        await _processBufferedIceCandidates();

        var answer = await _peerConnection?.createAnswer();
        await _peerConnection?.setLocalDescription(answer!);
        _socketService.sendAnswer(pin, answer!.toMap());
      }
    });

    // 2. ANSWER
    _socketService.socket?.on('webrtc-answer', (data) async {
      if (data != null && data['answer'] != null) {
        final answerData = data['answer'];
        var answer = RTCSessionDescription(
          answerData['sdp'],
          answerData['type'],
        );
        await _peerConnection?.setRemoteDescription(answer);
        _isRemoteDescriptionSet = true;
        await _processBufferedIceCandidates();
      }
    });

    // 3. ICE CANDIDATE
    _socketService.socket?.on('ice-candidate', (data) async {
      if (data != null && data['candidate'] != null) {
        final candidateData = data['candidate'];
        var candidate = RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        );

        if (_isRemoteDescriptionSet && _peerConnection != null) {
          await _peerConnection!.addCandidate(candidate);
        } else {
          _remoteIceCandidatesBuffer.add(candidate);
        }
      }
    });
  }

  Future<void> _processBufferedIceCandidates() async {
    for (var candidate in _remoteIceCandidatesBuffer) {
      await _peerConnection?.addCandidate(candidate);
    }
    _remoteIceCandidatesBuffer.clear();
  }

  Future<void> createAndSendOffer(String pin) async {
    if (_peerConnection == null) return;
    RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    _socketService.sendOffer(pin, offer.toMap());
  }

  bool sendChunk(Uint8List chunk) {
    if (_dataChannel != null && _isDataChannelOpen) {
      try {
        _dataChannel?.send(RTCDataChannelMessage.fromBinary(chunk));
        return true;
      } catch (e) {
        debugPrint("Error sending chunk: $e");
        return false;
      }
    }
    return false;
  }

  int get bufferedAmount => _dataChannel?.bufferedAmount ?? 0;

  void dispose() {
    _socketService.socket?.off('webrtc-offer');
    _socketService.socket?.off('webrtc-answer');
    _socketService.socket?.off('ice-candidate');
    _dataChannel?.close();
    _peerConnection?.close();
  }
}
