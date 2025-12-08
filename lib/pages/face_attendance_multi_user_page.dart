// lib/pages/face_attendance_multi_user_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/biometric_service.dart';
import '../services/face_recognition_tflite_service.dart';
import '../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../helpers/sound_helper.dart';
import '../widgets/mode_confirmation_dialog.dart';
import '../models/offline_attendance.dart';
import 'manual_check_page.dart';

class FaceAttendanceMultiUserPage extends StatefulWidget {
  final int organizationId;
  final String? attendanceType;

  const FaceAttendanceMultiUserPage({
    super.key,
    required this.organizationId,
    this.attendanceType,
  });

  @override
  State<FaceAttendanceMultiUserPage> createState() =>
      _FaceAttendanceMultiUserPageState();
}

enum MessageType {
  idle, processing, loading, success, error, warning, info,
}

class _FaceAttendanceMultiUserPageState
    extends State<FaceAttendanceMultiUserPage> {
  CameraController? _cameraController;
  final FaceRecognitionTFLiteService _faceService = FaceRecognitionTFLiteService();
  final BiometricService _biometricService = BiometricService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _syncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  String? _currentMessage;
  MessageType _messageType = MessageType.idle;
  Position? _currentPosition;
  String _organizationTimezone = 'Asia/Jakarta';

  Timer? _continuousScanTimer;
  Timer? _messageTimer;
  Timer? _scheduleCheckTimer;
  
  final List<Map<String, dynamic>> _recentAttendanceList = [];
  int _totalProcessedToday = 0;
  String _organizationName = '';
  int? _organizationMemberId;
  
  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  String _attendanceMode = 'check_in';

  final Map<int, DateTime> _processedUserTimestamps = {};
  final Duration _userCooldown = const Duration(seconds: 10);

  List<Map<String, dynamic>> _detectedFaces = [];
  bool _hasFacesInView = false;

  bool _isOnline = true;
  int _pendingSyncCount = 0;

  @override
  void initState() {
    super.initState();
    _enableKioskMode();
    _loadOrganizationData();
    _startScheduleCheck();
    _initializeFaceService();
    _initializeCamera();
    _getCurrentLocation();
    _checkConnectivity();
    _loadPendingSyncCount();
    _syncService.startAutoSync();
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    setState(() {
      _isOnline = result != ConnectivityResult.none;
    });

    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        setState(() {
          _isOnline = results != ConnectivityResult.none;
        });
        if (_isOnline) _loadPendingSyncCount();
      }
    });
  }

  Future<void> _loadPendingSyncCount() async {
    final count = await _offlineDb.getUnsyncedCount();
    if (mounted) {
      setState(() {
        _pendingSyncCount = count;
      });
    }
  }

  void _showMessage(String message, MessageType type, {int seconds = 3}) {
    _messageTimer?.cancel();
    
    setState(() {
      _currentMessage = message;
      _messageType = type;
    });

    _messageTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_isProcessing) {
        setState(() {
          _currentMessage = null;
          _messageType = MessageType.idle;
        });
      }
    });
  }

  void _clearMessage() {
    _messageTimer?.cancel();
    if (mounted) {
      setState(() {
        _currentMessage = null;
        _messageType = MessageType.idle;
      });
    }
  }

  Future<void> _loadOrganizationData() async {
    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', widget.organizationId)
          .maybeSingle();

      if (org != null && mounted) {
        setState(() {
          _organizationTimezone = org['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = org['name'] as String? ?? '';
        });
      }
      
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final member = await _supabase
            .from('organization_members')
            .select('id')
            .eq('organization_id', widget.organizationId)
            .eq('user_id', userId)
            .eq('is_active', true)
            .maybeSingle();
        
        if (member != null) {
          final memberId = member['id'] as int;
          setState(() {
            _organizationMemberId = memberId;
          });
          await _loadMemberSchedule(memberId);
        }
      }
    } catch (e) {
      debugPrint('Error loading org data: $e');
    }
  }

  Future<void> _enableKioskMode() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } catch (e) {
      debugPrint('Error kiosk mode: $e');
    }
  }

  Future<void> _initializeFaceService() async {
    try {
      _showMessage('Memuat AI model...', MessageType.loading);
      await _faceService.initialize();
      _clearMessage();
    } catch (e) {
      debugPrint('Failed to init TFLite: $e');
      if (mounted) {
        _showMessage('Gagal memuat AI model', MessageType.error, seconds: 5);
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();
      
      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('Auto-focus not supported: $e');
      }

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
        _startContinuousScan();
      }
    } catch (e) {
      debugPrint('Camera error: $e');
      if (mounted) {
        _showMessage('Kamera error', MessageType.error, seconds: 5);
      }
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      if (permission == LocationPermission.deniedForever) return;

      _currentPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      debugPrint('Failed to get location: $e');
    }
  }

  void _startContinuousScan() {
    _continuousScanTimer = Timer.periodic(
      const Duration(seconds: 2),
      (timer) {
        if (!_isProcessing && _isCameraInitialized) {
          _scanForFaces();
        }
      },
    );
  }

  Future<Size?> _getImageSize(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (ui.Image img) {
        completer.complete(img);
      });
      final image = await completer.future;
      return Size(image.width.toDouble(), image.height.toDouble());
    } catch (e) {
      debugPrint('Failed to decode image size: $e');
      return null;
    }
  }

  Future<void> _scanForFaces() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final image = await _cameraController!.takePicture();
      final imageFile = File(image.path);
      
      final faces = await _faceService.detectFaces(image.path);

      if (faces.isEmpty) {
        await imageFile.delete();
        
        setState(() {
          _detectedFaces = [];
        });

        if (_hasFacesInView) {
          _showMessage('Wajah tidak terdeteksi', MessageType.info, seconds: 2);
          _hasFacesInView = false;
        }
        
        return;
      }

      if (!_hasFacesInView) {
        _hasFacesInView = true;
        _showMessage('${faces.length} wajah terdeteksi - Memproses...', MessageType.processing);
      }

      final imageSize = await _getImageSize(imageFile);
      final imageWidth = imageSize?.width ??
          _cameraController?.value.previewSize?.height ?? 1080.0;
      final imageHeight = imageSize?.height ??
          _cameraController?.value.previewSize?.width ?? 1920.0;

      final detectedFacesMap = faces.map((face) {
        final boundingBox = face.boundingBox;
        final left = (boundingBox.left / imageWidth).clamp(0.0, 1.0);
        final top = (boundingBox.top / imageHeight).clamp(0.0, 1.0);
        final width = (boundingBox.width / imageWidth).clamp(0.0, 1.0);
        final height = (boundingBox.height / imageHeight).clamp(0.0, 1.0);

        return {
          'left': left,
          'top': top,
          'width': width,
          'height': height,
        };
      }).toList();

      setState(() {
        _detectedFaces = detectedFacesMap;
      });

      final processedUsers = <Map<String, dynamic>>[];
      final facesToProcess = faces.take(5).toList();

      for (int i = 0; i < facesToProcess.length; i++) {
        try {
          final capturedTemplate = await _faceService.buildTemplateFromFace(
            facesToProcess[i],
            image.path,
          );
          
          final bestMatch = await _biometricService.identifyBestMatchWithUserInfo(
            capturedTemplate: capturedTemplate,
            organizationId: widget.organizationId,
            threshold: 0.75,
          );

          if (bestMatch == null) {
            continue;
          }

          final userId = bestMatch['organization_member_id'] as int;
          final userName = bestMatch['user_name'] ?? 'Unknown';
          
          if (_processedUserTimestamps.containsKey(userId)) {
            final lastProcessTime = _processedUserTimestamps[userId]!;
            final timeSinceLastProcess = DateTime.now().difference(lastProcessTime);
            
            if (timeSinceLastProcess < _userCooldown) {
              final remainingSeconds = (_userCooldown - timeSinceLastProcess).inSeconds;
              _showMessage(
                '$userName baru saja absen (tunggu ${remainingSeconds}s)',
                MessageType.warning,
                seconds: 3,
              );
              continue;
            }
          }

          processedUsers.add({
            'user': bestMatch,
            'imageFile': imageFile,
            'faceIndex': i,
            'template': capturedTemplate,
          });
          
        } catch (e) {
          debugPrint('Error processing face $i: $e');
          continue;
        }
      }

      if (processedUsers.isNotEmpty) {
        await _processMultipleAttendances(processedUsers);
      } else {
        if (faces.isNotEmpty) {
          _showMessage(
            'Wajah tidak terdaftar atau dalam cooldown',
            MessageType.warning,
            seconds: 3,
          );
        }
        
        await SystemSound.play(SystemSoundType.alert);
        
        setState(() {
          _detectedFaces = [];
        });
      }

      try {
        if (await imageFile.exists()) {
          await imageFile.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete temp file: $e');
      }

    } catch (e) {
      debugPrint('ERROR in multi-face scan: $e');
      _showMessage('Error: ${e.toString()}', MessageType.error, seconds: 3);
      
      setState(() {
        _detectedFaces = [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _processMultipleAttendances(
    List<Map<String, dynamic>> usersData,
  ) async {
    final successfulAttendances = <String>[];
    final failedAttendances = <String>[];

    for (var userData in usersData) {
      try {
        final user = userData['user'];
        final imageFile = userData['imageFile'] as File;
        final template = userData['template'] as Map<String, dynamic>;
        final memberId = user['organization_member_id'] as int;
        final userName = user['user_name'] ?? 'Unknown';
        
        final isCheckIn = _attendanceMode == 'check_in';
        final attendanceType = isCheckIn ? 'check_in' : 'check_out';
        final workTimeMode = _getWorkTimeMode();
        
        // Save photo locally for offline support
        String? localPhotoPath;
        try {
          final tempDir = Directory.systemTemp;
          final fileName = 'face_${memberId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final localFile = File('${tempDir.path}/$fileName');
          await imageFile.copy(localFile.path);
          localPhotoPath = localFile.path;
        } catch (e) {
          debugPrint('Failed to save photo locally: $e');
        }

        // Save to offline database
        final offlineAttendance = OfflineAttendance(
          cardNumber: 'FACE_$memberId',
          faceEmbedding: jsonEncode(template),
          eventType: attendanceType,
          method: 'face_recognition_kiosk',
          timestamp: DateTime.now().toUtc().toIso8601String(),
          photoPath: localPhotoPath,
          latitude: _currentPosition?.latitude,
          longitude: _currentPosition?.longitude,
          workTimeMode: workTimeMode,
          organizationMemberId: memberId,
          userName: userName,
        );
        
        await _offlineDb.insertAttendance(offlineAttendance);
        await _loadPendingSyncCount();

        await _biometricService.updateLastUsed(user['biometric_id']);

        _processedUserTimestamps[memberId] = DateTime.now();

        if (mounted) {
          setState(() {
            _totalProcessedToday++;
            
            final now = DateTime.now();
            final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            
            _recentAttendanceList.insert(0, {
              'name': userName,
              'time': timeStr,
              'type': attendanceType,
              'timestamp': now,
            });

            if (_recentAttendanceList.length > 10) {
              _recentAttendanceList.removeLast();
            }
          });
        }

        successfulAttendances.add('$userName (${isCheckIn ? "Masuk" : "Keluar"})');

      } catch (e) {
        final userName = userData['user']['user_name'] ?? 'Unknown';
        debugPrint('ERROR processing $userName: $e');
        failedAttendances.add(userName);
      }
    }

    if (successfulAttendances.isNotEmpty) {
      await SoundHelper.playSuccessSound();
      
      final message = successfulAttendances.length == 1
          ? 'Berhasil: ${successfulAttendances.first}'
          : 'Berhasil: ${successfulAttendances.length} orang';
      
      _showMessage(message, MessageType.success, seconds: 3);
    }

    if (failedAttendances.isNotEmpty) {
      _showMessage(
        'Gagal: ${failedAttendances.join(", ")}',
        MessageType.error,
        seconds: 4,
      );
    }

    setState(() {
      _detectedFaces = [];
    });

    _cleanupOldTimestamps();
  }

  void _cleanupOldTimestamps() {
    final now = DateTime.now();
    _processedUserTimestamps.removeWhere((userId, timestamp) {
      return now.difference(timestamp) > _userCooldown;
    });
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted && _workTimeMode == null) {
        setState(() {});
      }
    });
  }

  Future<void> _loadMemberSchedule(int memberId) async {
    try {
      final today = DateTime.now();
      final todayStr = today.toIso8601String().split('T')[0];
      
      final schedule = await _supabase
          .from('member_schedules')
          .select('id, work_schedule_id, shift_id, effective_date, end_date')
          .eq('organization_member_id', memberId)
          .eq('is_active', true)
          .lte('effective_date', todayStr)
          .or('end_date.is.null,end_date.gte.$todayStr')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (schedule != null) {
        setState(() {
          _memberSchedule = schedule;
        });
      }
    } catch (e) {
      debugPrint('Error loading schedule: $e');
    }
  }

  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    return 'work_time';
  }

  Future<void> _handleModeChange(String newMode) async {
    if (_attendanceMode == newMode) return;

    final confirmed = await ModeConfirmationDialog.show(
      context: context,
      currentMode: _attendanceMode,
      newMode: newMode,
      onConfirm: () {
        setState(() => _attendanceMode = newMode);
      },
    );

    if (confirmed != true) return;
  }

  Future<void> _showSyncDialog() async {
    final stats = await _syncService.getSyncStats();
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Sinkronisasi Data'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total pending: ${stats['pending'] ?? 0}'),
            Text('Berhasil: ${stats['synced'] ?? 0}'),
            Text('Gagal: ${stats['failed'] ?? 0}'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _syncService.syncAllPendingAttendances();
                await _loadPendingSyncCount();
              },
              child: const Text('Mulai Sinkronisasi'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _continuousScanTimer?.cancel();
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _cameraController?.dispose();
    _faceService.dispose();
    _syncService.stopAutoSync();
    
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    super.dispose();
  }

  Color _getMessageColor() {
    switch (_messageType) {
      case MessageType.success:
        return Colors.green.withValues(alpha: 0.9);
      case MessageType.error:
        return Colors.red.withValues(alpha: 0.9);
      case MessageType.warning:
        return Colors.orange.withValues(alpha: 0.9);
      case MessageType.processing:
        return Colors.blue.withValues(alpha: 0.9);
      case MessageType.loading:
        return Colors.purple.withValues(alpha: 0.9);
      case MessageType.info:
        return Colors.grey.withValues(alpha: 0.7);
      case MessageType.idle:
        return Colors.black.withValues(alpha: 0.5);
    }
  }

  IconData? _getMessageIcon() {
    switch (_messageType) {
      case MessageType.success:
        return Icons.check_circle;
      case MessageType.error:
        return Icons.error;
      case MessageType.warning:
        return Icons.warning;
      case MessageType.processing:
        return Icons.face;
      case MessageType.loading:
        return Icons.hourglass_empty;
      case MessageType.info:
        return Icons.info;
      case MessageType.idle:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Keluar dari Mode Kiosk?'),
            content: Text(
              'Total diproses hari ini: $_totalProcessedToday\n\nYakin ingin keluar?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Batal'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Keluar'),
              ),
            ],
          ),
        );
        
        if (shouldExit == true && context.mounted) {
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Camera Preview
            if (_isCameraInitialized && _cameraController != null)
              Positioned.fill(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _cameraController!.value.previewSize?.height ?? 1,
                    height: _cameraController!.value.previewSize?.width ?? 1,
                    child: CameraPreview(_cameraController!),
                  ),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Face Detection Overlays
            if (_detectedFaces.isNotEmpty && _cameraController != null)
              ..._detectedFaces.map((face) {
                final cameraAspectRatio = _cameraController!.value.aspectRatio;
                final screenWidth = screenSize.width;
                final screenHeight = screenSize.height;
                
                double previewWidth, previewHeight;
                if (screenWidth / screenHeight > cameraAspectRatio) {
                  previewHeight = screenHeight;
                  previewWidth = screenHeight * cameraAspectRatio;
                } else {
                  previewWidth = screenWidth;
                  previewHeight = screenWidth / cameraAspectRatio;
                }
                
                final offsetX = (screenWidth - previewWidth) / 2;
                final offsetY = (screenHeight - previewHeight) / 2;
                
                final left = offsetX + (face['left'] as num).toDouble() * previewWidth;
                final top = offsetY + (face['top'] as num).toDouble() * previewHeight;
                final width = (face['width'] as num).toDouble() * previewWidth;
                final height = (face['height'] as num).toDouble() * previewHeight;

                return Positioned(
                  left: left,
                  top: top,
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.greenAccent, width: 3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }),

            // Top App Bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 40, 16, 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () async {
                        final shouldExit = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Keluar?'),
                            content: Text('Total: $_totalProcessedToday'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dialogContext).pop(false),
                                child: const Text('Batal'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.of(dialogContext).pop(true),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                child: const Text('Keluar'),
                              ),
                            ],
                          ),
                        );
                        
                        if (shouldExit == true && context.mounted) {
                          Navigator.of(context).pop(true);
                        }
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _organizationName.isEmpty ? 'Absensi Wajah' : _organizationName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _getWorkTimeMode() == 'break_time' ? 'Break time' : 'Work time',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 12),
                              _buildModeToggle(),
                            ],
                          ),
                          if (!_isOnline || _pendingSyncCount > 0) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: _isOnline 
                                    ? Colors.orange.withValues(alpha: 0.8)
                                    : Colors.red.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _isOnline ? Icons.cloud_queue : Icons.cloud_off,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isOnline 
                                        ? '$_pendingSyncCount pending'
                                        : 'Offline',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_organizationMemberId != null)
                          IconButton(
                            icon: const Icon(Icons.edit_note, color: Colors.white),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ManualCheckPage(
                                    organizationMemberId: _organizationMemberId!,
                                    memberData: {
                                      'organization_id': widget.organizationId,
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.more_vert, color: Colors.white),
                          onPressed: () => _showMenu(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Status Message Overlay
            if (_currentMessage != null)
              Positioned(
                top: 120,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _currentMessage != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: _getMessageColor(),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_messageType == MessageType.processing || 
                            _messageType == MessageType.loading)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        else if (_getMessageIcon() != null)
                          Icon(_getMessageIcon(), color: Colors.white, size: 20),
                        if (_messageType == MessageType.processing || 
                            _messageType == MessageType.loading || 
                            _getMessageIcon() != null)
                          const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            _currentMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Attendance List
            if (_recentAttendanceList.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  height: screenSize.height * 0.4,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.5),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Riwayat Hari Ini',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                '$_totalProcessedToday',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: _recentAttendanceList.length,
                          itemBuilder: (context, index) {
                            final item = _recentAttendanceList[index];
                            final isCheckIn = item['type'] == 'check_in';
                            
                            return TweenAnimationBuilder<double>(
                              key: ValueKey(item['timestamp']),
                              tween: Tween(begin: 0.0, end: 1.0),
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeOut,
                              builder: (context, value, child) {
                                return Transform.translate(
                                  offset: Offset(0, 20 * (1 - value)),
                                  child: Opacity(opacity: value, child: child),
                                );
                              },
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: isCheckIn 
                                            ? Colors.green.withValues(alpha: 0.3)
                                            : Colors.blue.withValues(alpha: 0.3),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isCheckIn ? Colors.green : Colors.blue,
                                          width: 2,
                                        ),
                                      ),
                                      child: Icon(
                                        isCheckIn ? Icons.login : Icons.logout,
                                        color: isCheckIn ? Colors.greenAccent : Colors.blueAccent,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item['name'],
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.white,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_getWorkTimeMode() == 'break_time' ? 'Break time' : 'Work time'} - ${isCheckIn ? 'Check In' : 'Check Out'}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.white.withValues(alpha: 0.7),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      item['time'],
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: isCheckIn ? Colors.greenAccent : Colors.blueAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleButton('In', 'check_in', Colors.green),
          _buildToggleButton('Out', 'check_out', Colors.red),
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, String mode, Color activeColor) {
    final isSelected = _attendanceMode == mode;
    return GestureDetector(
      onTap: () => _handleModeChange(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.8) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final currentMode = _getWorkTimeMode();
    final isAutoMode = _workTimeMode == null;
    
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(80, 50, 0, 0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'work_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'work_time' && !isAutoMode 
                    ? Icons.radio_button_checked 
                    : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Work time', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'break_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'break_time' && !isAutoMode 
                    ? Icons.radio_button_checked 
                    : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Break time', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'auto',
          child: Row(
            children: [
              Icon(
                isAutoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Auto (berdasarkan jadwal)', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'sign_data',
          child: Row(
            children: [
              Icon(
                _pendingSyncCount > 0 ? Icons.sync_problem : Icons.sync,
                color: _pendingSyncCount > 0 ? Colors.orange : const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Sinkronisasi data${_pendingSyncCount > 0 ? ' ($_pendingSyncCount)' : ''}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value != null) _handleMenuSelection(value);
    });
  }

  void _handleMenuSelection(String value) {
    switch (value) {
      case 'work_time':
        setState(() => _workTimeMode = 'work_time');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Work time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'break_time':
        setState(() => _workTimeMode = 'break_time');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Break time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'auto':
        setState(() => _workTimeMode = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Auto (berdasarkan jadwal)'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'sign_data':
        _showSyncDialog();
        break;
    }
  }
}