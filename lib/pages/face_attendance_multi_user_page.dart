import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/face_recognition_service.dart';
import '../services/biometric_service.dart';
import '../services/attendance_service.dart';
import '../services/supabase_storage_service.dart';
import '../services/face_recognition_tflite_service.dart';
import '../helpers/timezone_helper.dart';

class FaceAttendanceMultiUserPage extends StatefulWidget {
  final int organizationId;
  final String? attendanceType; // Optional, akan auto-detect

  const FaceAttendanceMultiUserPage({
    super.key,
    required this.organizationId,
    this.attendanceType,
  });

  @override
  State<FaceAttendanceMultiUserPage> createState() =>
      _FaceAttendanceMultiUserPageState();
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
  String _currentStep = 'Siap - Posisikan wajah Anda';
  Position? _currentPosition;
  String _organizationTimezone = 'Asia/Jakarta'; // Default timezone

  Timer? _continuousScanTimer;
  
  // Recent attendance list (max 10, shows who already checked in/out today)
  final List<Map<String, dynamic>> _recentAttendanceList = [];
  int _totalProcessedToday = 0;

  // Track processed users with timestamp (cooldown 10 detik)
  final Map<int, DateTime> _processedUserTimestamps = {};
  final Duration _userCooldown = const Duration(seconds: 10);

  // Detected faces on screen
  List<Map<String, dynamic>> _detectedFaces = [];

  Future<Size?> _getImageSize(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (ui.Image img) {
        completer.complete(img);
      });
      final image = await completer.future;
      return Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );
    } catch (e) {
      debugPrint('Failed to decode image size: $e');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _enableKioskMode();
    _initializeFaceService();
    _initializeCamera();
    _getCurrentLocation();
    _loadOrganizationTimezone();
  }

  Future<void> _loadOrganizationTimezone() async {
    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone')
          .eq('id', widget.organizationId)
          .maybeSingle();

      if (org != null && org['timezone'] != null) {
        setState(() {
          _organizationTimezone = org['timezone'] as String;
        });
        debugPrint('Organization timezone loaded: $_organizationTimezone');
      }
    } catch (e) {
      debugPrint('Error loading organization timezone: $e');
    }
  }

  Future<void> _enableKioskMode() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
      );
      
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } catch (e) {
      debugPrint('Error enabling kiosk mode: $e');
    }
  }

  Future<void> _initializeFaceService() async {
  try {
    setState(() {
      _currentStep = 'Loading AI model...';
    });
    
    await _faceService.initialize();
    
    debugPrint('✅ TFLite model initialized');
    
    setState(() {
      _currentStep = 'Siap - Posisikan wajah Anda';
    });
  } catch (e) {
    debugPrint('!!! Failed to initialize TFLite: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load AI model: $e'),
          backgroundColor: Colors.red,
        ),
      );
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
      debugPrint('Camera initialization error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera error: $e'),
            backgroundColor: Colors.red,
          ),
        );
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
    debugPrint('=== STARTING MULTI-FACE SCAN (TFLite) ===');
    
    final image = await _cameraController!.takePicture();
    final imageFile = File(image.path);
    
    // Detect faces using ML Kit
    final faces = await _faceService.detectFaces(image.path);
    
    debugPrint('Total faces detected: ${faces.length}');

    if (faces.isEmpty) {
      // Clean up temp file
      await imageFile.delete();
      
      setState(() {
        _detectedFaces = [];
        _currentStep = 'Tidak ada wajah terdeteksi';
      });
      
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && !_isProcessing) {
          setState(() {
            _currentStep = 'Siap - Posisikan wajah Anda';
          });
        }
      });
      return;
    }

    final imageSize = await _getImageSize(imageFile);
    final imageWidth = imageSize?.width ??
        _cameraController?.value.previewSize?.height ??
        1080.0;
    final imageHeight = imageSize?.height ??
        _cameraController?.value.previewSize?.width ??
        1920.0;

    // Map face bounding boxes for overlay
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
      _currentStep = 'Terdeteksi ${faces.length} wajah - Memproses AI...';
    });

    // Process up to 5 faces
    final facesToProcess = faces.take(5).toList();
    final processedUsers = <Map<String, dynamic>>[];

    for (int i = 0; i < facesToProcess.length; i++) {
      try {
        debugPrint('Processing face ${i + 1}/${facesToProcess.length} with TFLite');
        
        // Extract features using TFLite (requires image path)
        final capturedTemplate = await _faceService.buildTemplateFromFace(
          facesToProcess[i],
          image.path,
        );
        
        debugPrint('Extracted embedding size: ${capturedTemplate['embeddingSize']}');
        
        // Identify user with higher threshold for TFLite
        final bestMatch = await _biometricService.identifyBestMatchWithUserInfo(
          capturedTemplate: capturedTemplate,
          organizationId: widget.organizationId,
          threshold: 0.80, // Higher threshold for better accuracy
        );

        if (bestMatch != null) {
          final userId = bestMatch['organization_member_id'] as int;
          
          // Check cooldown
          if (_processedUserTimestamps.containsKey(userId)) {
            final lastProcessTime = _processedUserTimestamps[userId]!;
            final timeSinceLastProcess = DateTime.now().difference(lastProcessTime);
            
            if (timeSinceLastProcess < _userCooldown) {
              debugPrint('User $userId in cooldown, skipping');
              continue;
            }
          }

          processedUsers.add({
            'user': bestMatch,
            'imageFile': imageFile,
            'faceIndex': i,
          });
        }
      } catch (e) {
        debugPrint('Error processing face $i: $e');
        continue;
      }
    }

    if (processedUsers.isNotEmpty) {
      await _processMultipleAttendances(processedUsers);
    } else {
      setState(() {
        _currentStep = 'Wajah tidak dikenali - Silakan daftar terlebih dahulu';
      });
      
      await SystemSound.play(SystemSoundType.alert);
      
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && !_isProcessing) {
          setState(() {
            _currentStep = 'Siap - Posisikan wajah Anda';
            _detectedFaces = [];
          });
        }
      });
    }

    // Clean up temp file after processing
    try {
      if (await imageFile.exists()) {
        await imageFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to delete temp file: $e');
    }

  } catch (e) {
    debugPrint('!!! ERROR in multi-face scan: $e');
    setState(() {
      _currentStep = 'Error: ${e.toString()}';
      _detectedFaces = [];
    });
    
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_isProcessing) {
        setState(() {
          _currentStep = 'Siap - Posisikan wajah Anda';
        });
      }
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
    debugPrint('=== PROCESSING ${usersData.length} ATTENDANCES ===');

    for (var userData in usersData) {
      try {
        final user = userData['user'];
        final imageFile = userData['imageFile'] as File;
        final memberId = user['organization_member_id'] as int;
        
        // Auto-detect: Check if already checked in today
        final isCheckIn = await _shouldCheckIn(memberId);
        final attendanceType = isCheckIn ? 'check_in' : 'check_out';
        
        // Upload photo
        final photoUrl = await _storageService.uploadAttendancePhoto(
          imageFile,
          memberId,
          attendanceType,
        );

        // Prepare location data
        Map<String, dynamic>? locationData;
        if (_currentPosition != null) {
          locationData = {
            'latitude': _currentPosition!.latitude,
            'longitude': _currentPosition!.longitude,
            'accuracy': _currentPosition!.accuracy,
          };
        }

        // Record attendance
        if (isCheckIn) {
          await _attendanceService.checkIn(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'face_recognition_kiosk',
            organizationTimezone: _organizationTimezone,
            location: locationData,
          );
        } else {
          await _attendanceService.checkOut(
            organizationMemberId: memberId,
            photoUrl: photoUrl,
            method: 'face_recognition_kiosk',
            organizationTimezone: _organizationTimezone,
            location: locationData,
          );
        }

        // Update last used
        await _biometricService.updateLastUsed(user['biometric_id']);

        // Update timestamp
        _processedUserTimestamps[memberId] = DateTime.now();

        // Add to list
        if (mounted) {
          setState(() {
            _totalProcessedToday++;
            
            final now = DateTime.now();
            final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            
            // Add to top of list
            _recentAttendanceList.insert(0, {
              'name': user['user_name'] ?? 'Unknown',
              'time': timeStr,
              'type': isCheckIn ? 'check_in' : 'check_out',
              'timestamp': now,
            });

            // Keep max 10
            if (_recentAttendanceList.length > 10) {
              _recentAttendanceList.removeLast();
            }
          });
        }

        debugPrint('✅ Attendance recorded: ${user['user_name']} - $attendanceType');

      } catch (e) {
        debugPrint('!!! ERROR processing user: $e');
      }
    }

    await SystemSound.play(SystemSoundType.click);

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isProcessing) {
        setState(() {
          _currentStep = 'Siap - Posisikan wajah Anda';
          _detectedFaces = [];
        });
      }
    });

    _cleanupOldTimestamps();
  }

  void _cleanupOldTimestamps() {
    final now = DateTime.now();
    _processedUserTimestamps.removeWhere((userId, timestamp) {
      return now.difference(timestamp) > _userCooldown;
    });
  }

  /// Check if user should check in (true) or check out (false)
  Future<bool> _shouldCheckIn(int organizationMemberId) async {
  try {
    final supabase = Supabase.instance.client;
    // Use organization timezone for date calculation
    final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);

    debugPrint('=== CHECKING ATTENDANCE STATUS ===');
    debugPrint('Member ID: $organizationMemberId');
    debugPrint('Date: $todayStr');

    final record = await supabase
        .from('attendance_records')
        .select('status, actual_check_in, actual_check_out') // ✅ Nama kolom yang benar
        .eq('organization_member_id', organizationMemberId)
        .eq('attendance_date', todayStr)
        .maybeSingle();

    if (record == null) {
      debugPrint('✅ No record today → CHECK IN');
      return true;
    }

    final status = record['status'] as String?;
    final actualCheckIn = record['actual_check_in'];
    final actualCheckOut = record['actual_check_out'];
    
    debugPrint('Current status: $status');
    debugPrint('Check in: $actualCheckIn');
    debugPrint('Check out: $actualCheckOut');

    // If checked in but NOT checked out yet → CHECK OUT
    if (actualCheckIn != null && actualCheckOut == null) {
      debugPrint('✅ Already checked in, not checked out → CHECK OUT');
      return false;
    }

    // If both check in and check out exist → CHECK IN (new shift)
    if (actualCheckIn != null && actualCheckOut != null) {
      debugPrint('✅ Already checked out → CHECK IN (new shift)');
      return true;
    }

    // Status-based fallback
    if (status == 'present' || status == 'checked_in') {
      debugPrint('✅ Status is present/checked_in → CHECK OUT');
      return false;
    }

    if (status == 'checked_out' || status == 'absent') {
      debugPrint('✅ Status is checked_out/absent → CHECK IN');
      return true;
    }

    // Default: check in
    debugPrint('✅ Default → CHECK IN');
    return true;
    
  } catch (e) {
    debugPrint('!!! ERROR checking attendance status: $e');
    
    // Don't default to check in - throw error instead
    throw Exception('Cannot determine attendance status: $e');
  }
}

  @override
  void dispose() {
    _continuousScanTimer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
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
            // ===== FULL CAMERA BACKGROUND =====
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

            // ===== FACE DETECTION OVERLAYS =====
            if (_detectedFaces.isNotEmpty && _cameraController != null)
              ..._detectedFaces.map((face) {
                // Get camera preview dimensions
                final cameraAspectRatio = _cameraController!.value.aspectRatio;
                final screenWidth = screenSize.width;
                final screenHeight = screenSize.height;
                
                // Calculate actual preview dimensions maintaining aspect ratio
                double previewWidth, previewHeight;
                if (screenWidth / screenHeight > cameraAspectRatio) {
                  previewHeight = screenHeight;
                  previewWidth = screenHeight * cameraAspectRatio;
                } else {
                  previewWidth = screenWidth;
                  previewHeight = screenWidth / cameraAspectRatio;
                }
                
                // Calculate offsets to center the preview
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
                      border: Border.all(
                        color: Colors.greenAccent,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }),

            // ===== TOP APP BAR (TRANSPARAN) =====
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
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
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
                    const Text(
                      'Absensi Wajah',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 48), // Balance
                  ],
                ),
              ),
            ),

            // ===== STATUS OVERLAY (TRANSPARAN) =====
            Positioned(
              top: 120,
              left: 0,
              right: 0,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _isProcessing 
                      ? Colors.blue.withValues(alpha: 0.8)
                      : Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isProcessing)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      ),
                    if (_isProcessing) const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _currentStep,
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

            // ===== ATTENDANCE LIST (TRANSPARAN, MUNCUL JIKA ADA DATA) =====
            if (_recentAttendanceList.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  height: screenSize.height * 0.4, // 40% dari screen
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
                      // List Header
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
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

                      // Attendance List
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
                                  child: Opacity(
                                    opacity: value,
                                    child: child,
                                  ),
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
                                    // Avatar
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
                                        color: isCheckIn 
                                            ? Colors.greenAccent
                                            : Colors.blueAccent,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // Name
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
                                            isCheckIn ? 'Check In' : 'Check Out',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.white.withValues(alpha: 0.7),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Time
                                    Text(
                                      item['time'],
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: isCheckIn 
                                            ? Colors.greenAccent
                                            : Colors.blueAccent,
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
}