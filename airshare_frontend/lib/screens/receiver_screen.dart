import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import '../services/socket_service.dart';
import '../services/webrtc_service.dart';
import '../utils/file_utils.dart' as file_utils;
import '../utils/crypto_utils.dart';
import '../main.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final SocketService _socketService = SocketService();
  final WebRTCService _webrtcService = WebRTCService();
  final TextEditingController _pinController = TextEditingController();

  bool _isJoining = false;
  bool _isConnected = false;
  bool _isReceiving = false;
  bool _isCancelled = false;
  bool _hasSavedCurrentFile = false;
  
  String _fileName = '';
  int _expectedFileSize = 0;
  int _totalBytesReceived = 0;
  int _lastAckedBytes = 0;
  final List<Uint8List> _receivedChunks = [];
  double _progress = 0.0;
  String _statusText = "Enter PIN to connect";
  String _speedText = "0 KB/s";
  Stopwatch? _stopwatch;
  String? _currentPin;
  
  IOSink? _fileSink;
  File? _tempFile;

  Future<void> _joinRoom() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty || pin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid PIN')),
      );
      return;
    }

    setState(() {
      _currentPin = pin;
      _isJoining = true;
      _statusText = "Connecting to room...";
    });

    _socketService.connect();
    
    // Prevent duplicate listeners on retry
    _socketService.socket?.off('file-meta');
    _socketService.socket?.off('cancel-transfer');
    _socketService.socket?.off('file-complete');
    _socketService.socket?.off('file-chunk');

    // Listen for file metadata from sender
    _socketService.socket?.on('file-meta', (data) {
      if (mounted && data != null) {
        if (data is Map && data['type'] == 'single') {
           _prepareForFile(data['meta']);
        } else if (data is Map && data['type'] == 'preview') {
           // Ignored in minimal mode - Wait for single
        } else {
           // Fallback for older sender version or old backend array
           _prepareForFile(data);
        }
      }
    });

    _socketService.socket?.on('cancel-transfer', (data) {
      if (mounted) {
         setState(() {
            _isCancelled = true;
            _isReceiving = false;
            _statusText = "Transfer cancelled by sender.";
         });
      }
    });
    
    _socketService.socket?.on('file-complete', (data) {
      if (mounted) {
         setState(() {
            _isReceiving = false;
            _progress = 1.0;
            _statusText = "All transfers complete!";
         });
      }
    });

    final success = await _socketService.joinRoom(pin);

    if (!mounted) return;

    if (success) {
      setState(() {
        _statusText = "Joined room. Setting up P2P connection...";
      });

      _webrtcService.onConnectionStateChange = (connected) {
        if (mounted) {
          setState(() {
            _isConnected = connected;
            _statusText = connected
                ? "Connected! Waiting for sender..."
                : "Peer Disconnected";
          });
        }
      };

      _webrtcService.onDataReceived = (chunk) {
        _handleIncomingChunk(chunk);
      };

      _socketService.socket?.on('file-chunk', (data) {
        if (mounted && data != null && data['chunk'] != null) {
          final rawChunk = data['chunk'];
          Uint8List bytes;
          if (rawChunk is Uint8List) {
             bytes = rawChunk;
          } else if (rawChunk is List<dynamic>) {
             bytes = Uint8List.fromList(rawChunk.cast<int>());
          } else if (rawChunk is List<int>) {
             bytes = Uint8List.fromList(rawChunk);
          } else {
             return;
          }
          
          // Check for EOF before decrypting
          if (bytes.length == 27 && String.fromCharCodes(bytes) == '___EOF_AIRSHARE_TRANSFER___') {
            _handleIncomingChunk(bytes);
          } else {
            try {
              final decrypted = CryptoUtils.decryptChunk(bytes, pin);
              _handleIncomingChunk(decrypted);
            } catch (e) {
              debugPrint("Decryption error: $e");
            }
          }
        }
      });

      await _webrtcService.initPeerConnection(pin, false);
    } else {
      setState(() {
        _isJoining = false;
        _statusText = "Failed to join room. Check the PIN.";
      });
    }
  }

  void _prepareForFile(dynamic rawMeta) async {
    // rawMeta could be a List if old backend sends it, but in new backend single it's a Map.
    if (rawMeta is List && rawMeta.isNotEmpty) {
      // old fallback, grab first
      rawMeta = rawMeta[0];
    }
    if (rawMeta is! Map) return;

    final meta = rawMeta as Map<String, dynamic>;
    
    _fileName = meta['name']?.toString() ?? "received_file.bin";
    
    if (!kIsWeb) {
      try {
        _tempFile = await file_utils.FileUtils.createTempFile(_fileName);
        _fileSink = _tempFile!.openWrite();
      } catch (e) {
        debugPrint("Error creating temp file: $e");
      }
    }

    setState(() {
      final size = meta['size'];
      if (size is int) {
        _expectedFileSize = size;
      } else if (size is num) {
        _expectedFileSize = size.toInt();
      } else if (size is String) {
        _expectedFileSize = int.tryParse(size) ?? 0;
      }
      
      _receivedChunks.clear();
      _totalBytesReceived = 0;
      _lastAckedBytes = 0;
      _progress = 0.0;
      _isReceiving = false;
      _isCancelled = false;
      _hasSavedCurrentFile = false;
      
      final index = meta['index'] ?? 0;
      final total = meta['total'] ?? 1;
      _statusText = "Receiving file ${index + 1} of $total: $_fileName...";
    });
    
    // CRITICAL: Acknowledge metadata receipt so sender can start blasting WebRTC chunks safely.
    // We use chunk-ack with -1 because it's guaranteed to be relayed by older deployed backends.
    _socketService.socket?.emit('chunk-ack', {
      'pin': _currentPin,
      'ackBytes': -1
    });
  }

  void _handleIncomingChunk(Uint8List chunk) async {
    if (!mounted || _isCancelled) return;

    // Detect robust EOF signal from sender
    if (chunk.length == 27 && String.fromCharCodes(chunk) == '___EOF_AIRSHARE_TRANSFER___') {
      _isReceiving = false;
      if (!_hasSavedCurrentFile) {
        _hasSavedCurrentFile = true;
        await _saveReceivedFile();
      }
      return;
    }

    if (!_isReceiving) {
      _stopwatch = Stopwatch()..start();
      setState(() {
        _isReceiving = true;
      });
    }

    if (kIsWeb) {
      _receivedChunks.add(chunk);
    } else {
      _fileSink?.add(chunk);
    }
    
    _totalBytesReceived += chunk.length;

    // Flow control: Send ACK back to sender via Socket to release their buffer
    if (_totalBytesReceived - _lastAckedBytes >= 512 * 1024 || _totalBytesReceived == _expectedFileSize) {
       _socketService.socket?.emit('chunk-ack', {
         'pin': _currentPin,
         'ackBytes': _totalBytesReceived
       });
       _lastAckedBytes = _totalBytesReceived;
    }

    final elapsedSeconds = (_stopwatch?.elapsedMilliseconds ?? 1) / 1000;
    final speedKb = elapsedSeconds > 0 ? (_totalBytesReceived / 1024) / elapsedSeconds : 0;
    final speedMb = speedKb / 1024;

    setState(() {
      if (_expectedFileSize > 0) {
        _progress = (_totalBytesReceived / _expectedFileSize).clamp(0.0, 1.0);
      } else {
        _progress = 0.0;
      }
      _speedText = speedMb >= 1.0
          ? '${speedMb.toStringAsFixed(1)} MB/s'
          : '${speedKb.toStringAsFixed(0)} KB/s';
    });

    if (_totalBytesReceived >= _expectedFileSize && _expectedFileSize > 0) {
      _isReceiving = false;
      if (!_hasSavedCurrentFile) {
        _hasSavedCurrentFile = true;
        await _saveReceivedFile();
      }
    }
  }

  Future<void> _saveReceivedFile() async {
    // Capture state variables to prevent race conditions if next file starts
    final currentFileName = _fileName;
    final currentTempFile = _tempFile;
    final currentSink = _fileSink;
    final currentReceivedChunks = kIsWeb ? List<Uint8List>.from(_receivedChunks) : <Uint8List>[];

    try {
      if (kIsWeb) {
        final totalLength = currentReceivedChunks.fold<int>(0, (sum, element) => sum + element.length);
        final bytes = Uint8List(totalLength);
        int offset = 0;
        for (final chunk in currentReceivedChunks) {
          bytes.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        await file_utils.FileUtils.saveWebFile(bytes, currentFileName);
      } else {
        await currentSink?.flush();
        await currentSink?.close();
        
        if (currentTempFile != null && await currentTempFile.exists()) {
          await file_utils.FileUtils.moveToDownloads(currentTempFile, currentFileName);
        }
      }

      if (mounted) {
        setState(() {
          _statusText = "Saved $currentFileName to Downloads!";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = "Failed to save $currentFileName: $e";
        });
      }
    } finally {
      if (!kIsWeb) {
         await currentSink?.close();
         if (currentTempFile != null && await currentTempFile.exists()) {
           try { await currentTempFile.delete(); } catch(_) {}
         }
      }
      
      // Signal to the sender that the file is safely saved and ready for next file
      _socketService.socket?.emit('chunk-ack', {
        'pin': _currentPin,
        'ackBytes': -2
      });
    }
  }

  void _cancelTransfer() async {
    setState(() {
      _isCancelled = true;
      _isReceiving = false;
      _statusText = "Transfer cancelled.";
    });
    
    if (!kIsWeb) {
       await _fileSink?.close();
       _fileSink = null;
       if (_tempFile != null && await _tempFile!.exists()) {
         try { await _tempFile!.delete(); } catch(_) {}
       }
    }
    
    _socketService.socket?.emit('cancel-transfer', {'pin': _currentPin});
  }

  @override
  void dispose() {
    _pinController.dispose();
    _webrtcService.dispose();
    _socketService.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF09090B) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text('Receive File', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: isDark ? Colors.white : const Color(0xFF0F172A)),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: isDark ? Colors.white : const Color(0xFF0F172A), size: 28),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            elevation: 8,
            offset: const Offset(0, 40),
            onSelected: (value) {
              if (value == 'theme') {
                appThemeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                        color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF6366F1)),
                    const SizedBox(width: 12),
                    Text(isDark ? 'Light Theme' : 'Dark Theme',
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Background Aurora Effects
          Positioned(
            bottom: -100,
            left: -100,
            child: Container(
              width: 350,
              height: 350,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark ? const Color(0xFF8B5CF6) : const Color(0xFFC4B5FD)).withAlpha(isDark ? 30 : 60),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(color: Colors.transparent),
            ),
          ),
          
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B).withAlpha(150) : Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                            boxShadow: [
                              BoxShadow(
                                color: isDark ? Colors.black.withAlpha(50) : const Color(0xFF94A3B8).withAlpha(20),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              )
                            ]
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Column(
                              children: [
                                Text('ENTER SENDER PIN',
                                    style: TextStyle(color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED), fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                                const SizedBox(height: 24),
                                TextField(
                                  controller: _pinController,
                                  enabled: !_isJoining && !_isConnected,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.center,
                                  maxLength: 6,
                                  style: TextStyle(
                                    fontSize: 56,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 16,
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                  decoration: InputDecoration(
                                    counterText: "",
                                    hintText: "000000",
                                    hintStyle: TextStyle(color: isDark ? Colors.white.withAlpha(50) : const Color(0xFF0F172A).withAlpha(50), letterSpacing: 16),
                                    filled: true,
                                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 20),
                                    suffixIcon: IconButton(
                                      icon: Icon(Icons.content_paste_rounded, color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED)),
                                      tooltip: 'Paste PIN',
                                      onPressed: () async {
                                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                                        if (data != null && data.text != null) {
                                          String pasted = data.text!.replaceAll(RegExp(r'\D'), '');
                                          if (pasted.length > 6) pasted = pasted.substring(0, 6);
                                          _pinController.text = pasted;
                                        }
                                      },
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(20),
                                      borderSide: BorderSide(color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED), width: 2),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        
                        if (!_isConnected)
                          ElevatedButton.icon(
                            onPressed: _isJoining ? null : _joinRoom,
                            icon: const Icon(Icons.satellite_alt_rounded),
                            label: Text(_isJoining ? 'Connecting...' : 'Connect to Sender',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                              disabledForegroundColor: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              elevation: _isJoining ? 0 : 8,
                              shadowColor: (isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED)).withAlpha(100),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),
                          
                        const SizedBox(height: 24),
                        Center(
                          child: Text(
                            _statusText,
                            style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontSize: 16, fontWeight: FontWeight.w500),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        
                        if (_isReceiving) ...[
                          const SizedBox(height: 32),
                          Container(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(color: const Color(0xFF8A2BE2).withAlpha(76), blurRadius: 20)
                              ]
                            ),
                            child: LinearPercentIndicator(
                              padding: EdgeInsets.zero,
                              percent: _progress.clamp(0.0, 1.0),
                              lineHeight: 12.0,
                              progressColor: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED),
                              backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                              barRadius: const Radius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${(_progress * 100).toStringAsFixed(1)}%',
                                  style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16)),
                              Text(_speedText, style: TextStyle(color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED), fontWeight: FontWeight.bold, fontSize: 14)),
                              Text('${(_totalBytesReceived / (1024 * 1024)).toStringAsFixed(1)} MB',
                                  style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontWeight: FontWeight.w500, fontSize: 14)),
                            ],
                          ),
                          const SizedBox(height: 32),
                          OutlinedButton.icon(
                            onPressed: _cancelTransfer,
                            icon: const Icon(Icons.close_rounded),
                            label: const Text('Cancel Transfer', style: TextStyle(fontWeight: FontWeight.w600)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFEF4444),
                              side: const BorderSide(color: Color(0xFFEF4444)),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ],
                        
                        const SizedBox(height: 40),
                        
                        // Pro Tip
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withAlpha(10) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: isDark ? Colors.white.withAlpha(20) : const Color(0xFFE2E8F0)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.lightbulb_outline_rounded, color: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED), size: 28),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Pro Tip', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16)),
                                      const SizedBox(height: 4),
                                      Text('Once the transfer is complete, files are automatically verified for integrity. You can find them in your Downloads folder.',
                                        style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 14, height: 1.4),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
