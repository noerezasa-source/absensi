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
import '../services/attendance_service.dart';
import '../helpers/sound_helper.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/mode_confirmation_dialog.dart';
import '../services/supabase_storage_service.dart';
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
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
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
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;

  final Map<int, DateTime> _processedUserTimestamps = {};
  final Duration _userCooldown = const Duration(seconds: 3);

  List<Map<String, dynamic>> _detectedFaces = [];
  bool _hasFacesInView = false;

  bool _isOnline = true;

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
        }
      });
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

  void _showOverlayNotification(String message, {MessageType type = MessageType.warning}) {
    if (!mounted) return;
    
    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;
    
    Color primaryColor = Colors.orange;
    Color secondaryColor = Colors.orange.shade600;
    IconData iconData = Icons.warning_rounded;
    
    switch (type) {
      case MessageType.success:
        primaryColor = Colors.green;
        secondaryColor = Colors.green.shade600;
        iconData = Icons.check_circle_rounded;
        break;
      case MessageType.error:
        primaryColor = Colors.red;
        secondaryColor = Colors.red.shade600;
        iconData = Icons.error_rounded;
        break;
      case MessageType.info:
        primaryColor = Colors.blue;
        secondaryColor = Colors.blue.shade600;
        iconData = Icons.info_rounded;
        break;
      default:
        primaryColor = Colors.orange;
        secondaryColor = Colors.orange.shade600;
        iconData = Icons.warning_rounded;
    }
    
    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 100,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryColor.withOpacity(0.9), secondaryColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    iconData,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    overlayEntry.remove();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      color: Colors.white.withOpacity(0.8),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(overlayEntry);
    
    // Auto remove after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
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
        ResolutionPreset.medium,
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
      const Duration(milliseconds: 500),
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
      debugPrint('🔍 DETECTED FACES: ${faces.length} total faces');

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

      debugPrint('📊 PROCESSING: Starting to process ${faces.length} faces');
      int validUsers = 0;
      int cooldownUsers = 0;
      int unmatchedUsers = 0;

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

      // Update UI once for all detected faces
      if (_detectedFaces.length != detectedFacesMap.length) {
        setState(() {
          _detectedFaces = detectedFacesMap;
        });
      }

      final processedUsers = <Map<String, dynamic>>[];
      final facesToProcess = faces.toList();

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

          debugPrint('👤 FACE $i: Best match result: ${bestMatch != null ? "FOUND" : "NOT FOUND"}');

          if (bestMatch == null) {
            unmatchedUsers++;
            continue;
          }

          final userId = bestMatch['organization_member_id'] as int;
          final userName = bestMatch['user_name'] ?? 'Unknown';
          
          if (_processedUserTimestamps.containsKey(userId)) {
            final lastProcessTime = _processedUserTimestamps[userId]!;
            final timeSinceLastProcess = DateTime.now().difference(lastProcessTime);
            
            debugPrint('⏰ USER $userName: Time since last process: ${timeSinceLastProcess.inSeconds}s, cooldown: ${_userCooldown.inSeconds}s');
            
            if (timeSinceLastProcess < _userCooldown) {
              final remainingSeconds = (_userCooldown - timeSinceLastProcess).inSeconds;
              _showOverlayNotification(
                '$userName cooldown ${remainingSeconds}s',
                type: MessageType.warning,
              );
              cooldownUsers++;
              continue;
            }
          }

          processedUsers.add({
            'user': bestMatch,
            'imageFile': imageFile,
            'faceIndex': i,
            'template': capturedTemplate,
          });
          validUsers++;
          debugPrint('✅ USER $userName: Added to processing list (valid users: $validUsers)');
          
        } catch (e) {
          debugPrint('❌ ERROR processing face $i: $e');
          continue;
        }
      }

      debugPrint('📈 SUMMARY: Total faces: ${faces.length}, Valid users: $validUsers, Cooldown users: $cooldownUsers, Unmatched users: $unmatchedUsers');
      debugPrint('🎯 PROCESSED USERS COUNT: ${processedUsers.length}');

      if (processedUsers.isNotEmpty) {
        await _processMultipleAttendances(processedUsers);
      } else {
        if (faces.isNotEmpty) {
          // Tidak perlu notifikasi karena sudah ada petunjuk di box instruksi
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

        // Direct sync to server (no offline database for face recognition)
        debugPrint('🔄 Syncing face recognition attendance directly to server for: $userName (ID: $memberId)');
        
        // Upload photo first
        String photoUrl = '';
        if (localPhotoPath != null && localPhotoPath.isNotEmpty) {
          try {
            final photoFile = File(localPhotoPath);
            if (await photoFile.exists()) {
              debugPrint('📸 Uploading photo for member $memberId...');
              photoUrl = await _storageService.uploadAttendancePhoto(
                photoFile,
                memberId,
                attendanceType,
              );
              debugPrint('✅ Photo uploaded successfully: $photoUrl');
            }
          } catch (e) {
            debugPrint('⚠️ Failed to upload photo (continuing without photo): $e');
            // Continue without photo
          }
        }
        
        // Prepare location data
        Map<String, dynamic>? locationData;
        if (_currentPosition?.latitude != null && _currentPosition?.longitude != null) {
          locationData = {
            'latitude': _currentPosition!.latitude,
            'longitude': _currentPosition!.longitude,
          };
        }
        
        // Sync directly to Supabase
        try {
          if (attendanceType == 'check_in') {
            await _attendanceService.checkIn(
              organizationMemberId: memberId,
              photoUrl: photoUrl,
              method: 'face_recognition_kiosk',
              organizationTimezone: _organizationTimezone,
              location: locationData,
              rawData: {
                'face_recognition': true,
                'work_time_mode': workTimeMode,
              },
            );
            debugPrint('✅ Successfully synced check_in for member $memberId');
          } else {
            await _attendanceService.checkOut(
              organizationMemberId: memberId,
              photoUrl: photoUrl,
              method: 'face_recognition_kiosk',
              organizationTimezone: _organizationTimezone,
              location: locationData,
              rawData: {
                'face_recognition': true,
                'work_time_mode': workTimeMode,
              },
            );
            debugPrint('✅ Successfully synced check_out for member $memberId');
          }
        } catch (e) {
          debugPrint('❌ Failed to sync face recognition attendance: $e');
          rethrow;
        }

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

  Future<void> _loadAvailableModes() async {
    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time, description')
          .eq('organization_id', widget.organizationId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(modes);
        });
      }
    } catch (e) {
      debugPrint('Error loading modes: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memuat mode: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingModes = false);
    }
  }

  Future<void> _openModePicker() async {
    await _loadAvailableModes();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'Pilih Mode Shift',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoadingModes)
                    const Expanded(child: Center(child: CircularProgressIndicator()))
                  else if (_availableModes.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Belum ada mode shift tersedia',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _availableModes.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final mode = _availableModes[index];
                          final start = mode['start_time'] as String?;
                          final end = mode['end_time'] as String?;
                          final isSelected = _selectedMode?['id'] == mode['id'];
                          
                          return ListTile(
                            title: Text(
                              mode['name'] ?? '-',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: start != null && end != null
                                ? Text('$start - $end')
                                : null,
                            trailing: isSelected
                                ? const Icon(Icons.check_circle, color: Colors.green)
                                : null,
                            onTap: () => Navigator.of(context).pop(mode),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedMode = selected;
        _workTimeMode = selected['code'] as String? ?? selected['name'] as String?;
      });
      await _showInOutSelector();
    }
  }

  Future<void> _showInOutSelector() async {
    if (!mounted) return;
    final pickedMode = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_in'),
                        child: const Text('IN'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_out'),
                        child: const Text('OUT'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (pickedMode != null && mounted) {
      setState(() => _attendanceMode = pickedMode);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Mode ${pickedMode == 'check_in' ? 'IN' : 'OUT'} dipilih'
            '${_selectedMode != null ? ' • ${_selectedMode!['name']}' : ''}',
          ),
          backgroundColor: const Color(0xFF9333EA),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    return 'work_time';
  }

  Future<void> _handleModeChange(String newMode) async {
    if (_attendanceMode == newMode) return;

    await ModeConfirmationDialog.show(
      context: context,
      currentMode: _attendanceMode,
      newMode: newMode,
      onConfirm: () {
        setState(() => _attendanceMode = newMode);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mode diubah ke ${newMode == 'check_in' ? 'Check In' : 'Check Out'}'),
            backgroundColor: const Color(0xFF9333EA),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }


  @override
  void dispose() {
    _continuousScanTimer?.cancel();
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _cameraController?.dispose();
    _faceService.dispose();
    
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
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.exit_to_app, color: Colors.red.shade600, size: 24),
                const SizedBox(width: 8),
                const Text('Keluar?'),
              ],
            ),
            content: const Text('Yakin ingin keluar dari mode absensi?'),
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                          barrierDismissible: false,
                          builder: (dialogContext) => AlertDialog(
                            title: Row(
                              children: [
                                Icon(Icons.exit_to_app, color: Colors.red.shade600, size: 24),
                                const SizedBox(width: 8),
                                const Text('Keluar?'),
                              ],
                            ),
                            content: Text('Total diproses: $_totalProcessedToday orang\n\nYakin ingin keluar dari mode absensi?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dialogContext).pop(false),
                                child: const Text('Batal'),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.of(dialogContext).pop(true),
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
                          if (!_isOnline) ...[
                            const SizedBox(height: 6),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.cloud_off,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Offline',
                                    style: TextStyle(
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
                top: 80,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _currentMessage != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _getMessageColor(),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 6,
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
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 1.5,
                            ),
                          )
                        else if (_getMessageIcon() != null)
                          Icon(_getMessageIcon(), color: Colors.white, size: 16),
                        if (_messageType == MessageType.processing || 
                            _messageType == MessageType.loading || 
                            _getMessageIcon() != null)
                          const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _currentMessage!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Attendance List - White Table (Always Visible)
            DraggableScrollableSheet(
              minChildSize: 0.2,
              initialChildSize: 0.25,
              maxChildSize: 0.6,
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 10,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 40,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Data Absensi',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _recentAttendanceList.isEmpty
                            ? ListView(
                                controller: scrollController,
                                padding: const EdgeInsets.all(16),
                                children: [
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.people_outline,
                                        size: 32,
                                        color: Colors.grey.shade400,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Belum ada data absensi',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Arahkan wajah ke kamera untuk memulai',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : ListView.builder(
                                controller: scrollController,
                                padding: const EdgeInsets.all(8),
                                itemCount: _recentAttendanceList.length,
                                itemBuilder: (context, index) {
                                  final item = _recentAttendanceList[index];
                                  final isCheckIn = item['type'] == 'check_in';
                                  
                                  return TweenAnimationBuilder<double>(
                                    key: ValueKey(item['timestamp']),
                                    tween: Tween(begin: 0.0, end: 1.0),
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                    builder: (context, value, child) {
                                      return Transform.translate(
                                        offset: Offset(0, 10 * (1 - value)),
                                        child: Opacity(opacity: value, child: child),
                                      );
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 4),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: index % 2 == 0 ? Colors.grey.shade50 : Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.grey.shade200, width: 0.5),
                                      ),
                                      child: Row(
                                        children: [
                                          // Status Icon
                                          Container(
                                            width: 32,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color: isCheckIn 
                                                  ? Colors.green.shade100
                                                  : Colors.blue.shade100,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              isCheckIn ? Icons.login : Icons.logout,
                                              color: isCheckIn ? Colors.green.shade600 : Colors.blue.shade600,
                                              size: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          // Name and Type
                                          Expanded(
                                            flex: 2,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item['name'],
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.black87,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  isCheckIn ? 'Check In' : 'Check Out',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.grey.shade600,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          // Time
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: isCheckIn ? Colors.green.shade50 : Colors.blue.shade50,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              item['time'],
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: isCheckIn ? Colors.green.shade700 : Colors.blue.shade700,
                                              ),
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAttendanceModeToggle(),
          const SizedBox(height: 8),
          _buildWorkTimeModeSelector(),
        ],
      ),
    );
  }

  Widget _buildAttendanceModeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(25),
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

  Widget _buildWorkTimeModeSelector() {
    final currentMode = _getWorkTimeMode();
    final isWorkTime = currentMode == 'work_time';
    
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildWorkTimeButton('Waktu Kerja', 'work_time', isWorkTime),
        const SizedBox(width: 8),
        _buildWorkTimeButton('Waktu Istirahat', 'break_time', !isWorkTime),
      ],
    );
  }

  Widget _buildWorkTimeButton(String label, String mode, bool isSelected) {
    return GestureDetector(
      onTap: () {
        setState(() => _workTimeMode = mode);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Mode diubah ke $label'),
            backgroundColor: const Color(0xFF9333EA),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.transparent : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.white.withValues(alpha: 0.8) : Colors.white.withValues(alpha: 0.3),
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.7),
          ),
        ),
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
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(80, 50, 0, 0),
      items: const [
        PopupMenuItem<String>(
          value: 'mode_picker',
          child: Row(
            children: [
              Icon(Icons.tune, size: 18),
              SizedBox(width: 8),
              Text('Pilih mode'),
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
      case 'mode_picker':
        _openModePicker();
        break;
    }
  }
}