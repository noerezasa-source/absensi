import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import '../services/face_recognition_service.dart';
import '../services/biometric_service.dart';
import '../services/attendance_service.dart';
import '../services/supabase_storage_service.dart';

class FaceAttendanceMultiUserPage extends StatefulWidget {
  final int organizationId;
  final String attendanceType;

  const FaceAttendanceMultiUserPage({
    super.key,
    required this.organizationId,
    required this.attendanceType,
  });

  @override
  State<FaceAttendanceMultiUserPage> createState() =>
      _FaceAttendanceMultiUserPageState();
}

class _FaceAttendanceMultiUserPageState
    extends State<FaceAttendanceMultiUserPage> {
  CameraController? _cameraController;
  final FaceRecognitionService _faceService = FaceRecognitionService();
  final BiometricService _biometricService = BiometricService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  String _currentStep = 'Ready - Position your face in the frame';
  Position? _currentPosition;

  Timer? _continuousScanTimer;
  
  // Success notifications queue (max 10)
  final List<Map<String, dynamic>> _successQueue = [];
  int _totalProcessedToday = 0;

  // Track processed users with timestamp (cooldown 10 detik)
  final Map<int, DateTime> _processedUserTimestamps = {};
  final Duration _userCooldown = const Duration(seconds: 10);

  // Detected faces on screen (converted to Map for UI)
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
    _initializeCamera();
    _getCurrentLocation();
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
    // Scan setiap 2 detik untuk multi-face detection
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
      debugPrint('=== STARTING MULTI-FACE SCAN ===');
      
      final image = await _cameraController!.takePicture();
      final imageFile = File(image.path);
      
      // Detect ALL faces
      final faces = await _faceService.detectFaces(image.path);
      
      debugPrint('Total faces detected: ${faces.length}');

      if (faces.isEmpty) {
        setState(() {
          _detectedFaces = [];
          _currentStep = 'No face detected - Please position your face';
        });
        
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && !_isProcessing) {
            setState(() {
              _currentStep = 'Ready - Position your face in the frame';
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

      // Convert Face objects to Map for UI display
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

      // Update detected faces untuk UI overlay
      setState(() {
        _detectedFaces = detectedFacesMap;
        _currentStep = 'Detected ${faces.length} face(s) - Processing...';
      });

      // Process each face (max 5 faces sekaligus)
      final facesToProcess = faces.take(5).toList();
      final processedUsers = <Map<String, dynamic>>[];

      for (int i = 0; i < facesToProcess.length; i++) {
        try {
          debugPrint('Processing face ${i + 1}/${facesToProcess.length}');
          
          // Extract features untuk setiap wajah
          // Note: Gunakan image.path langsung karena extractFaceFeatures 
          // akan handle detection sendiri per face
          final capturedTemplate = _faceService.buildTemplateFromFace(
            facesToProcess[i],
          );
          
          // Identify user
          final bestMatch = await _biometricService.identifyBestMatchWithUserInfo(
            capturedTemplate: capturedTemplate,
            organizationId: widget.organizationId,
            threshold: 0.75, // 75% threshold
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

            // Add to process queue
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

      // Process attendance untuk semua recognized users
      if (processedUsers.isNotEmpty) {
        await _processMultipleAttendances(processedUsers);
      } else {
        setState(() {
          _currentStep = 'No recognized faces - Please register first';
        });
        
        await SystemSound.play(SystemSoundType.alert);
        
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && !_isProcessing) {
            setState(() {
              _currentStep = 'Ready - Position your face in the frame';
              _detectedFaces = [];
            });
          }
        });
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
            _currentStep = 'Ready - Position your face in the frame';
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
        
        // Upload photo
        final photoUrl = await _storageService.uploadAttendancePhoto(
          imageFile,
          user['organization_member_id'],
          widget.attendanceType,
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
        if (widget.attendanceType == 'check_in') {
          await _attendanceService.checkIn(
            organizationMemberId: user['organization_member_id'],
            photoUrl: photoUrl,
            method: 'face_recognition_kiosk',
            location: locationData,
          );
        } else {
          await _attendanceService.checkOut(
            organizationMemberId: user['organization_member_id'],
            photoUrl: photoUrl,
            method: 'face_recognition_kiosk',
            location: locationData,
          );
        }

        // Update last used
        await _biometricService.updateLastUsed(user['biometric_id']);

        // Update timestamp
        final userId = user['organization_member_id'] as int;
        _processedUserTimestamps[userId] = DateTime.now();

        // Add to success queue
        if (mounted) {
          setState(() {
            _totalProcessedToday++;
            
            final notificationTimestamp = DateTime.now();
            _successQueue.insert(0, {
              'name': user['user_name'] ?? 'Unknown',
              'similarity': user['similarity'],
              'timestamp': notificationTimestamp,
              'count': _totalProcessedToday,
            });

            // Keep max 10 notifications
            if (_successQueue.length > 10) {
              _successQueue.removeLast();
            }
            
            // Remove notification after 5 seconds
            Future.delayed(const Duration(seconds: 5), () {
              if (mounted) {
                setState(() {
                  _successQueue.removeWhere(
                    (item) => item['timestamp'] == notificationTimestamp,
                  );
                });
              }
            });
          });
        }

        debugPrint('✅ Attendance recorded: ${user['user_name']}');

      } catch (e) {
        debugPrint('!!! ERROR processing user: $e');
      }
    }

    // Play success sound once
    await SystemSound.play(SystemSoundType.click);

    // Reset after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isProcessing) {
        setState(() {
          _currentStep = 'Ready - Position your face in the frame';
          _detectedFaces = [];
        });
      }
    });

    // Cleanup old timestamps
    _cleanupOldTimestamps();
  }

  void _cleanupOldTimestamps() {
    final now = DateTime.now();
    _processedUserTimestamps.removeWhere((userId, timestamp) {
      return now.difference(timestamp) > _userCooldown;
    });
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
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Exit Kiosk Mode?'),
            content: Text(
              'Total processed today: $_totalProcessedToday\n\nAre you sure you want to exit?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Exit'),
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
              SizedBox.expand(
                child: CameraPreview(_cameraController!),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Face Detection Overlays (Green Boxes)
            if (_detectedFaces.isNotEmpty)
              ..._detectedFaces.asMap().entries.map((entry) {
                final face = entry.value;
                final screenSize = MediaQuery.of(context).size;
                
                // Convert face bounds to screen coordinates
                final left = (face['left'] as num).toDouble() * screenSize.width;
                final top = (face['top'] as num).toDouble() * screenSize.height;
                final width = (face['width'] as num).toDouble() * screenSize.width;
                final height = (face['height'] as num).toDouble() * screenSize.height;

                return Positioned(
                  left: left,
                  top: top,
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.green,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }),

            // Top Info Bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 50, 20, 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                          onPressed: () async {
                            if (!context.mounted) return;
                            
                            final shouldExit = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Exit Kiosk Mode?'),
                                content: Text(
                                  'Total processed: $_totalProcessedToday',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(dialogContext).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(dialogContext).pop(true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    child: const Text('Exit'),
                                  ),
                                ],
                              ),
                            );
                            
                            if (shouldExit == true && context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                          },
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: widget.attendanceType == 'check_in'
                                ? Colors.green
                                : Colors.red,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                widget.attendanceType == 'check_in'
                                    ? Icons.login
                                    : Icons.logout,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                widget.attendanceType == 'check_in'
                                    ? 'CHECK IN'
                                    : 'CHECK OUT',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.check_circle,
                                color: Colors.white,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '$_totalProcessedToday',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _isProcessing 
                            ? Colors.blue.withValues(alpha: 0.8)
                            : Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isProcessing)
                            const SizedBox(
                              width: 20,
                              height: 20,
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
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Success Notifications (max 10, format: "1 of 125: Name")
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _successQueue.map((notification) {
                  final index = _successQueue.indexOf(notification);
                  return TweenAnimationBuilder<double>(
                    key: ValueKey(notification['timestamp']),
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    builder: (context, value, child) {
                      return Transform.translate(
                        offset: Offset(0, 30 * (1 - value)),
                        child: Opacity(
                          opacity: value * (1.0 - (index * 0.08)),
                          child: child,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.green,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${notification['count']} of $_totalProcessedToday: ${notification['name']}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.verified,
                                        color: Colors.white70,
                                        size: 12,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Match: ${(notification['similarity'] * 100).toStringAsFixed(0)}%',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}