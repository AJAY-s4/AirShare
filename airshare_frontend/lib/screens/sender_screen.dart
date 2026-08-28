import 'dart:async';
import 'dart:io' show File;
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import '../services/socket_service.dart';
import '../services/webrtc_service.dart';
import '../utils/file_utils.dart';
import '../utils/crypto_utils.dart';
import '../main.dart'; // To access appThemeNotifier

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final SocketService _socketService = SocketService();
  final WebRTCService _webrtcService = WebRTCService();

  String? _pin;
  final List<PlatformFile> _selectedPlatformFiles = [];
  int _currentFileIndex = 0;
  bool _isConnected = false;
  bool _isTransferring = false;
  bool _isCancelled = false;
  bool _isTransferComplete = false;
  bool _receiverReadyForTransfer = false;
  bool _receiverSavedFile = false;
  int _acknowledgedBytes = 0;

  double _progress = 0.0;
  String _speedText = '0 KB/s';
  String _statusText = 'Select files or Drag & Drop';

  static const int chunkSize =
      16 * 1024; // 16 KB (Safe for WebRTC max message size)

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      withReadStream: kIsWeb,
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _selectedPlatformFiles.addAll(result.files);
        if (_pin == null) {
          _statusText = 'Generating PIN...';
        }
      });
      if (_pin == null) {
        _socketService.connect();
        await _initRoom();
      }
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    List<PlatformFile> droppedFiles = [];
    for (var xfile in details.files) {
      final length = await xfile.length();
      Stream<List<int>>? readStream;
      if (kIsWeb) {
        readStream = xfile.openRead();
      }
      droppedFiles.add(PlatformFile(
        name: xfile.name,
        size: length,
        path: xfile.path,
        readStream: readStream,
      ));
    }
    if (droppedFiles.isNotEmpty) {
      setState(() {
        _selectedPlatformFiles.addAll(droppedFiles);
        if (_pin == null) {
          _statusText = 'Generating PIN...';
        }
      });
      if (_pin == null) {
        _socketService.connect();
        await _initRoom();
      }
    }
  }

  Future<void> _initRoom() async {
    final pin = await _socketService.createRoom();
    if (!mounted) return;

    if (pin != null) {
      setState(() {
        _pin = pin;
        _statusText = 'Waiting for receiver to enter PIN...';
      });

      _webrtcService.onConnectionStateChange = (connected) {
        if (mounted) {
          setState(() {
            _isConnected = connected;
            _statusText = connected
                ? 'Peer Connected! Ready to send.'
                : 'Peer Disconnected';
          });
        }
      };

      _socketService.socket?.off('chunk-ack');
      _socketService.socket?.on('chunk-ack', (data) {
        if (mounted && data != null && data['ackBytes'] != null) {
          if (data['ackBytes'] == -1) {
            _receiverReadyForTransfer = true;
          } else if (data['ackBytes'] == -2) {
            _receiverSavedFile = true;
          } else {
            _acknowledgedBytes = data['ackBytes'];
          }
        }
      });

      _socketService.socket?.off('receiver-joined');
      _socketService.socket?.on('receiver-joined', (_) async {
        if (mounted) {
          setState(() {
            _statusText = 'User joined. Initializing P2P...';
          });
          await _webrtcService.initPeerConnection(_pin!, true);
          await _webrtcService.createAndSendOffer(_pin!);

          // 10s Timeout for WebRTC connection
          Future.delayed(const Duration(seconds: 10), () {
            if (mounted && !_isConnected && _selectedPlatformFiles.isNotEmpty && !_isTransferring) {
              setState(() {
                _statusText = 'P2P timeout. Falling back to relay...';
              });
              _startTransferLoop();
            }
          });
        }
      });  _socketService.socket?.off('cancel-transfer');
      _socketService.socket?.on('cancel-transfer', (_) {
        if (mounted && _isTransferring) {
          setState(() {
            _isCancelled = true;
            _isTransferring = false;
            _statusText = 'Transfer cancelled by receiver.';
          });
        }
      });
    } else {
      setState(() {
        _statusText = 'Failed to connect to backend server.';
      });
    }
  }

  Future<void> _startSending() async {
    if (_selectedPlatformFiles.isEmpty || _pin == null || _isTransferring) {
      return;
    }

    setState(() {
      _isTransferring = true;
      _isCancelled = false;
      _currentFileIndex = 0;
      _statusText = 'Starting transfer...';
    });

    // Jump straight to sending files (entering PIN is enough confirmation)
    _startTransferLoop();
  }

  Future<void> _startTransferLoop() async {
    if (_isTransferring) return;
    setState(() => _isTransferring = true);

    for (int i = _currentFileIndex; i < _selectedPlatformFiles.length; i++) {
      if (_isCancelled) break;

      _currentFileIndex = i;
      final file = _selectedPlatformFiles[i];

      // Tell receiver we are starting a specific file
      _socketService.socket?.emit('file-meta', {
        'pin': _pin,
        'meta': {
          'name': file.name,
          'size': file.size,
          'index': i,
          'total': _selectedPlatformFiles.length
        },
        'type': 'single'
      });

      setState(() {
        _statusText =
            'Transferring ${i + 1} of ${_selectedPlatformFiles.length}: ${file.name}';
        _progress = 0.0;
      });

      // Wait for receiver to explicitly acknowledge metadata before sending chunks
      // This prevents the WebRTC race condition where chunks arrive before metadata
      _receiverReadyForTransfer = false;

      int waitMs = 0;
      while (!_receiverReadyForTransfer && waitMs < 15000) {
        // Wait up to 15s
        if (_isCancelled) break;
        await Future.delayed(const Duration(milliseconds: 50));
        waitMs += 50;
      }

      if (!_receiverReadyForTransfer && !_isCancelled) {
        setState(() {
          _statusText = 'Receiver timeout. Transfer failed.';
          _isCancelled = true;
          _isTransferring = false;
        });
        break;
      }

      _receiverSavedFile = false;
      await _transferSingleFile(file);

      if (_isCancelled) break;

      // Wait for receiver to explicitly acknowledge file saved before moving to the next file
      int savedWaitMs = 0;
      while (!_receiverSavedFile && savedWaitMs < 60000) {
        if (_isCancelled) break;
        await Future.delayed(const Duration(milliseconds: 50));
        savedWaitMs += 50;
      }

      // Wait a moment between files
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (mounted && !_isCancelled) {
      setState(() {
        _progress = 1.0;
        _statusText = 'All Transfers Complete!';
        _isTransferring = false;
        _isTransferComplete = true;
        _socketService.socket?.emit('file-complete', {'pin': _pin});
      });
    }
  }

  Future<void> _transferSingleFile(PlatformFile file) async {
    final totalBytes = file.size;
    int bytesSent = 0;
    _acknowledgedBytes = 0;
    final stopwatch = Stopwatch()..start();

    // Determine transport method for the ENTIRE file to prevent out-of-order chunks
    final bool useWebRTC = _isConnected;

    try {
      Stream<List<int>>? stream;
      if (kIsWeb && file.readStream != null) {
        stream = file.readStream;
      } else if (file.path != null) {
        final f = File(file.path!);
        stream = f.openRead();
      }

      if (stream != null) {
        await for (List<int> bytes in stream) {
          if (_isCancelled) return;
          for (int i = 0; i < bytes.length; i += (useWebRTC ? chunkSize : 512 * 1024)) {
            if (_isCancelled) return;

            int currentChunkSize = useWebRTC ? chunkSize : 512 * 1024;
            int end =
                (i + currentChunkSize < bytes.length) ? i + currentChunkSize : bytes.length;
            Uint8List chunk = Uint8List.fromList(bytes.sublist(i, end));

            if (useWebRTC) {
              bool sent = _webrtcService.sendChunk(chunk);
              if (!sent) {
                throw Exception("WebRTC channel closed during transfer");
              }
              bytesSent += chunk.length;

              // Flow control: Use WebRTC's internal bufferedAmount to prevent overwhelming the SCTP queue
              // A limit of 256KB guarantees the underlying OS network buffer is never overfilled, preventing silent packet drops
              while (_webrtcService.bufferedAmount > 256 * 1024) {
                if (_isCancelled) return;
                await Future.delayed(const Duration(milliseconds: 5));
              }
            } else {
              // Encrypt and Route via rock-solid Socket.IO TCP relay
              final encryptedChunk = CryptoUtils.encryptChunk(chunk, _pin!);
              _socketService.socket?.emit('file-chunk', {
                'pin': _pin,
                'chunk': encryptedChunk,
              });

              bytesSent += chunk.length;

              // Flow control: Wait if we are more than 8MB ahead of ACKs to prevent backend RAM bloat
              while (bytesSent - _acknowledgedBytes > 8 * 1024 * 1024) {
                if (_isCancelled) return;
                await Future.delayed(const Duration(milliseconds: 5));
              }
            }

            _updateProgress(bytesSent, totalBytes, stopwatch);
          }
        }

        // Send robust EOF signal over the same channel
        final eofChunk =
            Uint8List.fromList('___EOF_AIRSHARE_TRANSFER___'.codeUnits);
        if (useWebRTC) {
          _webrtcService.sendChunk(eofChunk);
        } else {
          _socketService.socket?.emit('file-chunk', {
            'pin': _pin,
            'chunk': eofChunk,
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = 'Transfer error: $e';
        });
      }
    }
    stopwatch.stop();
  }

  void _updateProgress(int bytesSent, int totalBytes, Stopwatch stopwatch) {
    if (!mounted) return;
    final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000;
    final speedKb =
        elapsedSeconds > 0 ? (bytesSent / 1024) / elapsedSeconds : 0;
    final speedMb = speedKb / 1024;

    setState(() {
      _progress =
          totalBytes > 0 ? (bytesSent / totalBytes).clamp(0.0, 1.0) : 0.0;
      _speedText = speedMb >= 1.0
          ? '${speedMb.toStringAsFixed(1)} MB/s'
          : '${speedKb.toStringAsFixed(0)} KB/s';
    });
  }

  void _cancelTransfer() {
    setState(() {
      _isCancelled = true;
      _isTransferring = false;
      _isTransferComplete = false;
      _statusText = 'Transfer cancelled.';
    });
    _socketService.socket?.emit('cancel-transfer', {'pin': _pin});
  }

  void _resetAndSendAnother() {
    _webrtcService.dispose();
    _socketService.disconnect();
    setState(() {
      _selectedPlatformFiles.clear();
      _pin = null;
      _currentFileIndex = 0;
      _isTransferComplete = false;
      _progress = 0.0;
      _statusText = 'Select files or Drag & Drop';
      _isConnected = false;
      _isTransferring = false;
      _isCancelled = false;
    });
  }

  @override
  void dispose() {
    _webrtcService.dispose();
    _socketService.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalSize =
        _selectedPlatformFiles.fold<int>(0, (prev, file) => prev + file.size);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF09090B) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text('Send File', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold)),
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
      body: DropTarget(
        onDragDone: _isTransferring ? (_) {} : _handleDrop,
        child: Stack(
          children: [
            Positioned(
              top: -100,
              right: -100,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isDark ? const Color(0xFF3B82F6) : const Color(0xFF93C5FD)).withAlpha(isDark ? 30 : 60),
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
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_isTransferComplete)
                          _buildSuccessState(isDark, totalSize)
                        else
                          _buildTransferState(isDark, totalSize),
                          
                        if (!_isTransferComplete) ...[
                          const SizedBox(height: 32),
                          ElevatedButton.icon(
                            onPressed: (_pin == null || !_isConnected || _isTransferring) ? null : _startSending,
                            icon: const Icon(Icons.rocket_launch_rounded),
                            label: Text(_isTransferring ? 'Sending...' : 'Start Transfer',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                              disabledForegroundColor: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                              padding: const EdgeInsets.symmetric(vertical: 20),
                              elevation: (_pin == null || !_isConnected || _isTransferring) ? 0 : 8,
                              shadowColor: (isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB)).withAlpha(100),
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
                        ],
                        
                        const SizedBox(height: 32),
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
                                Icon(Icons.lightbulb_outline_rounded, color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), size: 28),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Pro Tip', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16)),
                                      const SizedBox(height: 4),
                                      Text('Keep this screen open until the transfer completely finishes. Airshare uses end-to-end encryption for privacy.',
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
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessState(bool isDark, int totalSize) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF10B981).withAlpha(50), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF10B981).withAlpha(isDark ? 20 : 30),
            blurRadius: 24,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 64),
          ),
          const SizedBox(height: 24),
          Text(
            'Transfer Complete!',
            style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            '${_selectedPlatformFiles.length} files (${FileUtils.formatBytes(totalSize)}) were delivered securely.',
            style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569), fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _resetAndSendAnother,
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send Another File', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferState(bool isDark, int totalSize) {
    return Container(
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
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            if (_selectedPlatformFiles.isEmpty) ...[
              Text('SELECT FILES',
                  style: TextStyle(color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), fontWeight: FontWeight.w700, letterSpacing: 1.5)),
              const SizedBox(height: 24),
              InkWell(
                onTap: _pickFile,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                      style: BorderStyle.solid,
                      width: 2, 
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: (isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB)).withAlpha(20),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.cloud_upload_rounded, size: 48, color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)),
                        ),
                        const SizedBox(height: 16),
                        Text('Drag & Drop files here',
                            style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontSize: 16, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        Text('or click to browse',
                            style: TextStyle(color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8), fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ] else ...[
              Text('CONNECTION PIN',
                  style: TextStyle(color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), fontWeight: FontWeight.w700, letterSpacing: 1.5)),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 32),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _pin ?? '------',
                        style: TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 16,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (_pin != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 16.0),
                          child: IconButton(
                            icon: const Icon(Icons.copy_rounded),
                            color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                            tooltip: 'Copy PIN',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _pin!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text('PIN copied to clipboard!'),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Selected Files (${_selectedPlatformFiles.length})',
                      style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 16, fontWeight: FontWeight.bold)),
                  if (!_isTransferring)
                    TextButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add More'),
                      style: TextButton.styleFrom(
                        foregroundColor: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _selectedPlatformFiles.length,
                  separatorBuilder: (context, index) => Divider(height: 1, color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                  itemBuilder: (context, index) {
                    final f = _selectedPlatformFiles[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: (isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)).withAlpha(20),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(FileUtils.getFileIcon(f.name), color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)),
                      ),
                      title: Text(f.name, style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                      subtitle: Text(FileUtils.formatBytes(f.size), style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontSize: 12)),
                      trailing: (!_isTransferring)
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded, size: 20),
                              color: const Color(0xFFEF4444),
                              onPressed: () {
                                setState(() {
                                  _selectedPlatformFiles.removeAt(index);
                                  if (_selectedPlatformFiles.isEmpty) _pin = null;
                                });
                              },
                            ) 
                          : null,
                    );
                  }
                ),
              ),
              
              if (!_isTransferring)
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('Total size: ', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontSize: 14)),
                      Text(FileUtils.formatBytes(totalSize), style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              
              if (_isTransferring) ...[
                const SizedBox(height: 40),
                LinearPercentIndicator(
                  padding: EdgeInsets.zero,
                  percent: _progress.clamp(0.0, 1.0),
                  lineHeight: 12.0,
                  progressColor: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                  backgroundColor: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                  barRadius: const Radius.circular(6),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${(_progress * 100).toStringAsFixed(1)}%',
                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(_speedText, style: TextStyle(color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('${(_acknowledgedBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
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
              ]
            ]
          ],
        ),
      ),
    );
  }
}
