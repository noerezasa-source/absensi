// lib/pages/face_attendance_multi_user_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/biometric_service.dart';
import '../services/face_recognition_tflite_service.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/attendance_service.dart';
import '../helpers/sound_helper.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/mode_confirmation_dialog.dart';
import '../services/supabase_storage_service.dart';
import '../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
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
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _attendanceSyncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isTakingPicture = false; // ✅ NEW: Prevent concurrent camera captures
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

  final Map<String, DateTime> _processedUserTimestamps = {};
  final Duration _userCooldown = const Duration(minutes: 5); // ✅ INCREASED: 5 minutes cooldown to prevent duplicate processing

  List<Map<String, dynamic>> _detectedFaces = [];
  bool _hasFacesInView = false;
  
  // ✅ NEW: Store face data with user info for better UI
  final Map<int, Map<String, dynamic>> _faceDataMap = {};
  int _faceIdCounter = 0;
  
  // ✅ NEW: Processing queue to prevent lag
  final List<Future<void>> _processingQueue = [];
  bool _isQueueProcessing = false;

  // ✅ NEW: Persistent Face Tracking
  // Map<trackingId, {name, similarity, memberId, timestamp}>
  final Map<int, Map<String, dynamic>> _persistentFaceTracker = {};


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
    _attendanceSyncService.startAutoSync();
  }

  @override
  void dispose() {
    _continuousScanTimer?.cancel();
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _isProcessing = false;
    _isQueueProcessing = false;
    _processingQueue.clear();
    _faceDataMap.clear();
    _detectedFaces.clear();
    _cameraController?.dispose();
    _attendanceSyncService.stopAutoSync();
    _faceService.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
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


  Future<String?> _getProfilePhotoBase64(int memberId, String? remoteUrl) async {
    try {
      final cached = await _offlineDb.findMemberByOrgIdInCache(memberId);
      final cachedProfile = cached?['organization_members']?['user_profiles'] as Map<String, dynamic>?;
      final cachedBase64 = cachedProfile?['profile_photo_base64'] as String?;
      if (cachedBase64 != null && cachedBase64.isNotEmpty) {
        return cachedBase64;
      }

      if (_isOnline && remoteUrl != null && remoteUrl.isNotEmpty) {
        return await _downloadAsBase64(remoteUrl);
      }
    } catch (e) {
      debugPrint('Failed to get profile base64: $e');
    }
    return null;
  }

  Future<String?> _downloadAsBase64(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await consolidateHttpClientResponseBytes(response);
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Download to base64 failed: $e');
      return null;
    }
  }

  Future<String?> _encodeFileToBase64(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('Encode file to base64 failed: $e');
      return null;
    }
  }

  Future<int?> _saveOfflineAttendance({
    required int memberId,
    required String userName,
    required String attendanceType,
    required Map<String, dynamic> template,
    String? localPhotoPath,
    String? profilePhotoBase64,
  }) async {
    try {
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      final isDuplicate = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      );
      if (isDuplicate) {
        debugPrint('⚠️ Duplicate offline attendance ignored for member $memberId, type $attendanceType, date $todayStr');
        return -1; // sentinel for duplicate
      }

      final capturedBase64 = await _encodeFileToBase64(localPhotoPath);
      
      // ✅ MULTI-SHIFT: Encode full shift details if available
      String modeToSave = _getWorkTimeMode();
      if (_selectedMode != null) {
        try {
          // Combine the code with full details
          final shiftData = Map<String, dynamic>.from(_selectedMode!);
          shiftData['mode_code'] = modeToSave; // Ensure the simple code is preserved
          modeToSave = jsonEncode(shiftData);
        } catch (e) {
          debugPrint('Failed to encode shift data: $e');
        }
      }

      final record = OfflineAttendance(
        cardNumber: 'FACE_$memberId',
        faceEmbedding: jsonEncode(template),
        eventType: attendanceType,
        method: 'face_recognition_kiosk',
        timestamp: DateTime.now().toUtc().toIso8601String(),
        photoPath: localPhotoPath,
        capturedPhotoBase64: capturedBase64,
        profilePhotoBase64: profilePhotoBase64,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
        workTimeMode: modeToSave,
        organizationMemberId: memberId,
        userName: userName,
        isSynced: false,
      );

      return await _offlineDb.insertAttendance(record);
    } catch (e) {
      debugPrint('Failed to save offline attendance: $e');
      return null;
    }
  }


  void _showMessage(String message, MessageType type, {int seconds = 2}) {
    _messageTimer?.cancel();
    
    setState(() {
      _currentMessage = message;
      _messageType = type;
    });

    _messageTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) {
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
      _showMessage('Menyiapkan...', MessageType.loading);
      await _faceService.initialize();
      _clearMessage();
    } catch (e) {
      debugPrint('Failed to init TFLite: $e');
      if (mounted) {
        _showMessage('Gagal inisialisasi', MessageType.error, seconds: 5);
      }
    }
  }

  Future<void> _initializeCamera() async {
    // ✅ FIXED: Prevent multiple initializations
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      debugPrint('⚠️ Camera already initialized, skipping');
      return;
    }
    
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }
      
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      // ✅ FIXED: Dispose old controller if exists
      if (_cameraController != null) {
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high, // ✅ UPDATED: High resolution for HD preview asked by user
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Camera initialization timeout');
        },
      );
      
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
        _showMessage('Gagal Kamera', MessageType.error, seconds: 5);
        setState(() {
          _isCameraInitialized = false;
        });
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
    // ✅ OPTIMIZED: 100ms for real-time face tracking (reduced from 300ms)
    // ✅ FIXED: Prevent camera restart by checking if camera is still initialized
    _continuousScanTimer = Timer.periodic(
      const Duration(milliseconds: 100), // ✅ OPTIMIZED: 100ms for real-time tracking
      (timer) {
        if (!_isProcessing && 
            !_isTakingPicture && // ✅ NEW: Prevent concurrent captures
            _isCameraInitialized && 
            _cameraController != null &&
            _cameraController!.value.isInitialized &&
            !_isQueueProcessing) {
          _scanForFaces();
        }
      },
    );
  }

  // ✅ OPTIMIZED: Get image size without full decode (much faster)
  Future<Size?> _getImageSize(File imageFile) async {
    try {
      // Use camera preview size directly instead of decoding image
      if (_cameraController != null && _cameraController!.value.previewSize != null) {
        final previewSize = _cameraController!.value.previewSize!;
        // Camera preview is rotated, so swap width/height
        return Size(previewSize.height.toDouble(), previewSize.width.toDouble());
      }
      return null;
    } catch (e) {
      debugPrint('Failed to get image size: $e');
      return null;
    }
  }

  Future<void> _scanForFaces() async {
    // ✅ IMPROVED: Comprehensive camera state validation
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isProcessing ||
        _isTakingPicture ||
        _isQueueProcessing) {
      return;
    }

    // ✅ IMPROVED: Prevent concurrent operations
    _isProcessing = true;
    _isTakingPicture = true;

    File? imageFile;
    
    try {
      // ✅ IMPROVED: Validate camera state before capture
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        debugPrint('⚠️ Camera not ready, skipping scan');
        return;
      }

      // ✅ IMPROVED: 800ms timeout with better error handling
      final image = await _cameraController!.takePicture().timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {
          throw TimeoutException('Camera takePicture timeout');
        },
      );
      imageFile = File(image.path);
      
      // ✅ IMPROVED: Validate file before processing
      if (!await imageFile.exists()) {
        debugPrint('⚠️ Captured image file does not exist');
        return;
      }
      
      // ✅ IMPROVED: Face detection with better timeout handling
      final faces = await _faceService.detectFaces(image.path).timeout(
        const Duration(milliseconds: 700),
        onTimeout: () {
          debugPrint('⚠️ Face detection timeout');
          return <Face>[];
        },
      );
      
      debugPrint('🔍 DETECTED FACES: ${faces.length} total faces');

      if (faces.isEmpty) {
        // ✅ IMPROVED: Safe cleanup with error handling
        try {
          await imageFile.delete();
        } catch (e) {
          debugPrint('Failed to delete temp file: $e');
        }
        
        // ✅ IMPROVED: Clear persistent tracker when no faces detected
        _persistentFaceTracker.clear();
        
        // ✅ IMPROVED: Safe setState with mounted check
        if (mounted && _detectedFaces.isNotEmpty) {
           setState(() {
             _detectedFaces = [];
             _faceDataMap.clear();
           });
        }
        
        _hasFacesInView = false;
        return;
      }

      if (!_hasFacesInView) {
        _hasFacesInView = true;
        // _showMessage('${faces.length} wajah terdeteksi - Memproses...', MessageType.processing);
      }

      debugPrint('📊 PROCESSING: Starting to process ${faces.length} faces');
      int validUsers = 0;
      int cooldownUsers = 0;
      int unmatchedUsers = 0;

      // ✅ OPTIMIZED: Get image size without blocking
      final imageSize = _getImageSize(imageFile);
      final imageWidth = (await imageSize)?.width ??
          _cameraController?.value.previewSize?.height ?? 1080.0;
      final imageHeight = (await imageSize)?.height ??
          _cameraController?.value.previewSize?.width ?? 1920.0;

      // ✅ NEW: Create face data map with IDs for better tracking
      final detectedFacesMap = <Map<String, dynamic>>[];
      final newFaceDataMap = <int, Map<String, dynamic>>{};
      
      for (int i = 0; i < faces.length; i++) {
        final face = faces[i];
        final boundingBox = face.boundingBox;
        
        // ✅ DYNAMIC EXPANSION: Adjust box size based on face distance
        // Calculate face size ratio to determine distance
        final faceArea = boundingBox.width * boundingBox.height;
        final imageArea = imageWidth * imageHeight;
        final faceRatio = faceArea / imageArea;
        
        // Dynamic expansion factor based on face size:
        // Dynamic scaling based on face distance (face-to-image ratio)
      // Large ratio (> 0.25) means face is close -> Use TIGHT box for accuracy (User request: "jangan terlalu besar")
      // Small ratio (< 0.12) means face is far -> Use slight expansion to catch movements
      double expansionFactor = 0.05; // Default small
      
      if (faceRatio > 0.25) {
        expansionFactor = 0.0; // ✅ TIGHT FIT (No expansion) when face is close
      } else if (faceRatio > 0.12) {
        expansionFactor = 0.05; // ✅ Minimal expansion for medium distance
      } else {
        expansionFactor = 0.10; // ✅ Moderate expansion only for very far faces
      }
      
      final double expansionX = boundingBox.width * expansionFactor;
      final double expansionY = boundingBox.height * expansionFactor;
      
      final expandedLeft = (boundingBox.left - expansionX).clamp(0.0, imageWidth - 1);
      final expandedTop = (boundingBox.top - expansionY * 1.5).clamp(0.0, imageHeight - 1); // Less top expansion
      final expandedRight = (boundingBox.right + expansionX).clamp(0.0, imageWidth - 1);
      final expandedBottom = (boundingBox.bottom + expansionY).clamp(0.0, imageHeight - 1); 

        final left = (expandedLeft / imageWidth).clamp(0.0, 1.0);
        final top = (expandedTop / imageHeight).clamp(0.0, 1.0);
        final width = ((expandedRight - expandedLeft) / imageWidth).clamp(0.0, 1.0);
        final height = ((expandedBottom - expandedTop) / imageHeight).clamp(0.0, 1.0);

        final trackingId = face.trackingId;
        Map<String, dynamic>? knownFace;

        // Check persistent tracker for match info
        if (trackingId != null && _persistentFaceTracker.containsKey(trackingId)) {
          knownFace = _persistentFaceTracker[trackingId];
          knownFace!['lastSeen'] = DateTime.now();
        }

        // Check if we already have this face in the UI list to preserve animation state
        int existingFaceIndex = -1;
        if (trackingId != null) {
          existingFaceIndex = _detectedFaces.indexWhere((f) => f['trackingId'] == trackingId);
        }

        int faceId;
        if (existingFaceIndex != -1) {
           faceId = _detectedFaces[existingFaceIndex]['id']; // Reuse ID
        } else {
           faceId = _faceIdCounter++;
        }

        final newFaceData = {
          'id': faceId,
          'trackingId': trackingId, 
          'left': left,
          'top': top,
          'width': width,
          'height': height,
          // matched > processing > detecting > unmatched
          'status': knownFace != null ? 'matched' : (existingFaceIndex != -1 ? _detectedFaces[existingFaceIndex]['status'] : 'detecting'),
          'userName': knownFace != null ? knownFace['name'] : (existingFaceIndex != -1 ? _detectedFaces[existingFaceIndex]['userName'] : null),
          'similarity': knownFace != null ? knownFace['similarity'] : null,
        };

        detectedFacesMap.add(newFaceData);
        
        newFaceDataMap[faceId] = {
          'face': face,
          'imagePath': image.path,
          'imageFile': imageFile,
          'faceIndex': i,
        };
      }

      // ✅ OPTIMIZED: Update UI carefully to prevent flickering
      if (mounted) {
        setState(() {
           // Instead of hard replacing, we might want to animate transition, 
           // but since we reused IDs where possible, flutter should handle it.
           // However, let's keep the list stable.
           _detectedFaces = detectedFacesMap;
        });
      }

      final processedUsers = <Map<String, dynamic>>[];
      final facesToProcess = faces.toList();

      // ✅ OPTIMIZED: Process faces in parallel to reduce lag
      final futures = <Future<void>>[];
      
      for (int i = 0; i < facesToProcess.length; i++) {
        final faceId = detectedFacesMap[i]['id'] as int;
        final trackingId = facesToProcess[i].trackingId;
        
        // ✅ OPTIMIZATION: Skip processing if we already know who this is (via trackingId)
        // This keeps the green box stable without re-running heavy recognition
        final existingFace = detectedFacesMap[i];
        if ((existingFace['status'] == 'success' || existingFace['status'] == 'cooldown') && 
             existingFace['name'] != null) {
           debugPrint('⏭️ Skipped recognition for trackingId $trackingId (${existingFace['name']})');
           // Face is already recognized and displayed green, no need to re-process
           continue; 
        }
        if (trackingId != null && _persistentFaceTracker.containsKey(trackingId)) {
           // We already have this face in our tracker, UI is already updated above.
           // We just need to ensure we don't re-process duplicate attendance if not needed.
           // For UX, just keeping the box green is enough.
           debugPrint('⏭️ Skipped recognition for trackingId $trackingId (${_persistentFaceTracker[trackingId]?['name']})');
           continue;
        }

        futures.add(_processFaceAsync(
          facesToProcess[i],
          image.path,
          imageFile,
          i,
          faceId,
          processedUsers,
          (valid, cooldown, unmatched) {
            validUsers = valid;
            cooldownUsers = cooldown;
            unmatchedUsers = unmatched;
          },
        ));
      }
      
      // ✅ OPTIMIZED: Wait for all faces with timeout to prevent hanging
      await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('⚠️ Face processing timeout');
          return <void>[];
        },
      );

      debugPrint('📈 SUMMARY: Total faces: ${faces.length}, Valid users: $validUsers, Cooldown users: $cooldownUsers, Unmatched users: $unmatchedUsers');
      debugPrint('🎯 PROCESSED USERS COUNT: ${processedUsers.length}');

      if (processedUsers.isNotEmpty) {
        // ✅ OPTIMIZED: Process attendance in queue to prevent lag
        _addToProcessingQueue(() => _processMultipleAttendances(processedUsers));
        
        // ✅ NEW: Don't clear face boxes! Keep them tracking.
        // The user requested: "tetap ada menyesuaikan orangnya sampai orangnya keluar kamera"
        // So we keep _detectedFaces as is. It will be updated by the next scan cycle.
      } else {
        if (faces.isNotEmpty) {
          // Update face status to unmatched
          if (mounted) {
            setState(() {
              for (var face in _detectedFaces) {
                if (face['status'] == 'detecting' || face['status'] == 'processing') {
                  face['status'] = 'unmatched';
                }
              }
            });
          }
          
          // ✅ NEW: Don't clear unmatched faces. Keep them tracking (red box).
          // Future.delayed... removed.
        }
        
        // ✅ OPTIMIZED: Play sound in background
        SystemSound.play(SystemSoundType.alert).catchError((e) {});
      }

      // ✅ OPTIMIZED: Delete file in background without blocking
      imageFile.delete().catchError((e) => debugPrint('Failed to delete temp file: $e'));

    } catch (e) {
      debugPrint('ERROR in multi-face scan: $e');
      if (e is TimeoutException) {
        debugPrint('⚠️ Camera timeout - skipping this frame');
      } else {
        // _showMessage('Terjadi kesalahan', MessageType.error, 3);
      }
      
      // ✅ IMPROVED: Safe cleanup of temp file on error
      if (imageFile != null) {
        try {
          await imageFile.delete();
        } catch (deleteError) {
          debugPrint('Failed to delete temp file on error: $deleteError');
        }
      }
      
      if (mounted) {
        setState(() {
          _detectedFaces = [];
          _faceDataMap.clear();
        });
      }
    } finally {
      // ✅ IMPROVED: Always reset flags to allow next scan
      _isProcessing = false;
      _isTakingPicture = false;
    }
  }
  
  // ✅ NEW: Processing queue to prevent lag
  void _addToProcessingQueue(Future<void> Function() task) {
    _processingQueue.add(task());
    _processQueue();
  }
  
  Future<void> _processQueue() async {
    if (_isQueueProcessing || _processingQueue.isEmpty) return;
    
    _isQueueProcessing = true;
    try {
      while (_processingQueue.isNotEmpty) {
        final task = _processingQueue.removeAt(0);
        await task.timeout(const Duration(seconds: 10), onTimeout: () {
          debugPrint('⚠️ Queue task timeout');
        });
        // Minimal delay between tasks for better performance
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _isQueueProcessing = false;
    }
  }

  // ✅ NEW: Process face asynchronously to prevent blocking
  Future<void> _processFaceAsync(
    Face face,
    String imagePath,
    File imageFile,
    int faceIndex,
    int faceId,
    List<Map<String, dynamic>> processedUsers,
    Function(int, int, int) updateCounters,
  ) async {
    // ✅ NEW: Update face status to processing
    if (mounted) {
      setState(() {
        final faceData = _detectedFaces.firstWhere(
          (f) => f['id'] == faceId,
          orElse: () => {},
        );
        if (faceData.isNotEmpty) {
          faceData['status'] = 'processing';
        }
      });
    }
    try {
      final capturedTemplate = await _faceService.buildTemplateFromFace(
        face,
        imagePath,
      );
      
      final bestMatch = await _biometricService.identifyBestMatchWithUserInfo(
        capturedTemplate: capturedTemplate,
        organizationId: widget.organizationId,

        threshold: 0.73, // ✅ BALANCED: 0.73 for good recognition rate with accuracy
        strict: false, // Always non-strict for better UX in motion
      );

      debugPrint('👤 FACE $faceIndex: Best match result: ${bestMatch != null ? "FOUND" : "NOT FOUND"}');
      
      if (bestMatch != null) {
        final similarity = (bestMatch['similarity'] as num?)?.toDouble() ?? 0.0;
        debugPrint('👤 FACE $faceIndex: Match similarity: ${(similarity * 100).toStringAsFixed(2)}%');
      }

      if (bestMatch == null) {
        // ✅ NEW: Update face status to unmatched
        if (mounted) {
          setState(() {
            final faceData = _detectedFaces.firstWhere(
              (f) => f['id'] == faceId,
              orElse: () => {},
            );
            if (faceData.isNotEmpty) {
              faceData['status'] = 'unmatched';
            }
          });
        }
        updateCounters(0, 0, 1);
        return;
      }

      final userId = bestMatch['organization_member_id'] as int;
      final userName = bestMatch['user_name'] ?? 'Unknown';
      final similarity = (bestMatch['similarity'] as num?)?.toDouble() ?? 0.0;
      
      // ✅ BALANCED: Require minimum similarity of 73% for good recognition
      if (similarity < 0.73) {
        debugPrint('❌ FACE $faceIndex: Match rejected - similarity ${(similarity * 100).toStringAsFixed(2)}% below 73% threshold');
        // ✅ NEW: Update face status to unmatched
        if (mounted) {
          setState(() {
            final faceData = _detectedFaces.firstWhere(
              (f) => f['id'] == faceId,
              orElse: () => {},
            );
            if (faceData.isNotEmpty) {
              faceData['status'] = 'unmatched';
            }
          });
        }
        updateCounters(0, 0, 1);
        return;
      }
      
      // ✅ NEW: Update face status to matched with user info
      if (mounted) {
        setState(() {
          final faceData = _detectedFaces.firstWhere(
            (f) => f['id'] == faceId,
            orElse: () => {},
          );
          if (faceData.isNotEmpty) {
            faceData['status'] = 'matched';
            faceData['userName'] = userName;
            faceData['similarity'] = similarity;
          }
        });
      }

      // ✅ TRACKING: Save to persistent tracker
      if (face.trackingId != null) {
        _persistentFaceTracker[face.trackingId!] = {
          'name': userName,
          'similarity': similarity,
          'memberId': userId,
          'lastSeen': DateTime.now(),
        };
      }
      
      // ✅ NEW: Check if this face already matched with a different user in this scan
      // Prevent 1 face from matching multiple people
      final existingMatch = processedUsers.firstWhere(
        (u) => u['faceIndex'] == faceIndex,
        orElse: () => {},
      );
      
      if (existingMatch.isNotEmpty) {
        final existingUserId = existingMatch['user']?['organization_member_id'] as int?;
        if (existingUserId != null && existingUserId != userId) {
          debugPrint('⚠️ FACE $faceIndex: Already matched with user $existingUserId, rejecting new match with $userId');
          updateCounters(0, 0, 1);
          return;
        }
        // Same user, skip duplicate
        if (existingUserId == userId) {
          debugPrint('⏭️ FACE $faceIndex: Already processing user $userName, skipping duplicate');
          updateCounters(0, 1, 0);
          return;
        }
      }
      
      // ✅ IMPROVED: Check cooldown first with composite key (User + Type)
      final isCheckIn = _attendanceMode == 'check_in'; // Defined earlier, used here
      final cooldownKey = '${userId}_${isCheckIn ? "in" : "out"}';

      if (_processedUserTimestamps.containsKey(cooldownKey)) {
        final lastProcessTime = _processedUserTimestamps[cooldownKey]!;
        final timeSinceLastProcess = DateTime.now().difference(lastProcessTime);
        
        if (timeSinceLastProcess < _userCooldown) {
          final remainingSeconds = (_userCooldown - timeSinceLastProcess).inSeconds;
          debugPrint('⏰ USER $userName: Still in cooldown for ${isCheckIn ? "IN" : "OUT"} (${remainingSeconds}s remaining)');
          
          // ✅ FIX: Keep showing green box ("success") for user in cooldown so box stays stable
          if (mounted) {
            setState(() {
              final faceData = _detectedFaces.firstWhere(
                (f) => f['id'] == faceId,
                orElse: () => {},
              );
              if (faceData.isNotEmpty) {
                faceData['status'] = 'success'; // Show as success (green)
                faceData['name'] = userName;    // Keep showing name
                // Optionally add specific info like "Sudah Absen"
              }
            });
          }
          
          updateCounters(0, 1, 0);
          return;
        }
      }

      // ✅ NEW: Check if already recorded today BEFORE processing
      // final isCheckIn = _attendanceMode == 'check_in'; // Already defined
      final attendanceType = isCheckIn ? 'check_in' : 'check_out';
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      
      // Check offline database first (faster)
      final alreadyRecordedOffline = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: userId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      ).timeout(const Duration(seconds: 1), onTimeout: () => false);
      
      if (alreadyRecordedOffline) {
        debugPrint('⏭️ USER $userName: Already recorded in offline DB, skipping');
        
        // ✅ FIX: Keep showing green box for offline recorded user
        if (mounted) {
          setState(() {
            final faceData = _detectedFaces.firstWhere(
              (f) => f['id'] == faceId,
              orElse: () => {},
            );
            if (faceData.isNotEmpty) {
              faceData['status'] = 'success';
              faceData['name'] = userName;
            }
          });
        }
        
        // Update timestamp to prevent repeated checks
        _processedUserTimestamps[cooldownKey] = DateTime.now();
        updateCounters(0, 1, 0);
        return;
      }
      
      // ❌ REMOVED ONLINE CHECK to ensure speed
      // if (_isOnline) { ... }

      // ✅ IMPROVED: Set timestamp BEFORE adding to list to prevent duplicate processing
      _processedUserTimestamps[cooldownKey] = DateTime.now();

      // Thread-safe add to list
      processedUsers.add({
        'user': bestMatch,
        'imageFile': imageFile,
        'faceIndex': faceIndex,
        'template': capturedTemplate,
      });
      updateCounters(1, 0, 0);
      debugPrint('✅ USER $userName: Added to processing list');
      
    } catch (e) {
      debugPrint('❌ ERROR processing face $faceIndex: $e');
      updateCounters(0, 0, 1);
    }
  }

  // ✅ NEW: Process single attendance asynchronously
  Future<void> _processSingleAttendance(
    Map<String, dynamic> userData,
    List<String> successfulAttendances,
    List<String> failedAttendances,
    Function(bool) updateHasQueuedOffline,
  ) async {
    try {
      final user = userData['user'];
      final imageFile = userData['imageFile'] as File;
      final template = userData['template'] as Map<String, dynamic>;
      final memberId = user['organization_member_id'] as int;
      final userName = user['user_name'] ?? 'Unknown';
      
      final isCheckIn = _attendanceMode == 'check_in';
      final attendanceType = isCheckIn ? 'check_in' : 'check_out';
      final workTimeMode = _getWorkTimeMode();
      
      // ✅ OPTIMIZED: Defer heavy operations with timeout (300ms)
      // If network is slow, we skip the photo to keep UI fast
      final profilePhotoBase64 = await _getProfilePhotoBase64(
        memberId,
        user['profile_photo_url'] as String?,
      ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      final departmentName = user['department_name'] as String?;

      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      bool alreadyRecorded = false;
      
      // ✅ OPTIMIZED: Check duplicate faster (offline ONLY)
      // We explicitly skip online check here to ensure instant feedback.
      // The background sync service will handle true duplicates later.
      alreadyRecorded = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      ).timeout(const Duration(seconds: 1), onTimeout: () => false);
      
      // ❌ REMOVED ONLINE CHECK to ensure speed regardless of signal
      // if (!alreadyRecorded && _isOnline) { ... }
      
      if (alreadyRecorded) {
        return; // Skip without message to reduce UI updates
      }
      
      if (alreadyRecorded) {
        return; // Skip without message to reduce UI updates
      }
      
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

      // Always persist to offline database for parity with RFID
      final offlineId = await _saveOfflineAttendance(
        memberId: memberId,
        userName: userName,
        attendanceType: attendanceType,
        template: template,
        localPhotoPath: localPhotoPath,
        profilePhotoBase64: profilePhotoBase64,
      );

      final isDuplicateSkip = offlineId != null && offlineId == -1;
      if (isDuplicateSkip) {
        return;
      }

      // ✅ FAST: Schedule background sync after 30 seconds (as requested)
      // This ensures UI is updated immediately without waiting for server
      if (_isOnline) {
        Timer(const Duration(seconds: 30), () {
          debugPrint('⏰ Triggering delayed sync for member $memberId');
          AttendanceSyncService().syncPendingAttendances();
        });
      }
      
      // Update biometric timestamp regardless of sync status (since it was used)
      try {
         await _biometricService.updateLastUsed(user['biometric_id']).timeout(const Duration(seconds: 1), onTimeout: () => 0);
      } catch (_) {}

      // ✅ NOTE: Timestamp already set in _processFaceAsync before processing
      // This ensures user won't be processed again even if attendance fails
      // Using composite key logic again (redundant but safe)
      final cooldownKey = '${memberId}_${isCheckIn ? "in" : "out"}';
      if (!_processedUserTimestamps.containsKey(cooldownKey)) {
        _processedUserTimestamps[cooldownKey] = DateTime.now();
      }

      if (mounted) {
        setState(() {
          _totalProcessedToday++;
          
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          
          _recentAttendanceList.insert(0, {
            'name': userName,
            'department': departmentName ?? '-',
            'photo_base64': profilePhotoBase64,
            'photo_url': user['profile_photo_url'],
            'time': timeStr,
            'type': attendanceType,
            'timestamp': now,
          });

          if (_recentAttendanceList.length > 10) {
            _recentAttendanceList.removeLast();
          }
        });
      }

      successfulAttendances.add('$userName (${isCheckIn ? "MASUK" : "KELUAR"})');
      // Treat everything as queued initially until background sync picks it up
      updateHasQueuedOffline(true);

    } catch (e) {
      final userName = userData['user']['user_name'] ?? 'Unknown';
      debugPrint('ERROR processing $userName: $e');
      failedAttendances.add(userName);
    }
  }

  Future<void> _processMultipleAttendances(
    List<Map<String, dynamic>> usersData,
  ) async {
    // ✅ OPTIMIZED: Show immediate feedback
    if (usersData.isNotEmpty) {
      final firstUser = usersData.first['user'];
      final firstName = firstUser['user_name'] ?? 'Unknown';
      // _showMessage('Memproses absen untuk $firstName...', MessageType.processing);
    }

    final successfulAttendances = <String>[];
    final failedAttendances = <String>[];
    bool hasQueuedOffline = false;

    // ✅ OPTIMIZED: Process users in parallel batches (max 2 at a time to prevent overload)
    const batchSize = 5;
    for (int i = 0; i < usersData.length; i += batchSize) {
      final batch = usersData.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((userData) => _processSingleAttendance(
          userData,
          successfulAttendances,
          failedAttendances,
          (hasOffline) => hasQueuedOffline = hasOffline,
        )),
      );
    }

    if (successfulAttendances.isNotEmpty) {
      await SoundHelper.playSuccessSound();
      
      var message = successfulAttendances.length == 1
          ? '${hasQueuedOffline ? "Offline" : "Sukses"}: ${successfulAttendances.first}'
          : '${hasQueuedOffline ? "Offline" : "Sukses"}: ${successfulAttendances.length} orang';
      if (hasQueuedOffline) {
        message = '$message (Simpan)';
      }
      
      _showMessage(message, MessageType.success, seconds: 2);
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
      _faceDataMap.clear();
    });

    _cleanupOldTimestamps();
  }

  void _cleanupOldTimestamps() {
    final now = DateTime.now();
    _processedUserTimestamps.removeWhere((key, timestamp) {
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

  // Reverting to dynamic shift selector based on User Request
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

    // ✅ MULTI-SHIFT: Auto-select based on current time
    _autoSelectCurrentShift();

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
                          'Shift tidak tersedia',
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

  void _autoSelectCurrentShift() {
    if (_availableModes.isEmpty) return;

    final now = TimeOfDay.fromDateTime(TimezoneHelper.getCurrentUtcTime().add(const Duration(hours: 7))); // Assuming WIB for simplicity, strict logic uses org timezone helper
    // Better: use DateTime.now() since we are in local app context
    // Actually orgTimezone is safer.
    final nowDateTime = DateTime.now();
    final currentTime = TimeOfDay.fromDateTime(nowDateTime);

    Map<String, dynamic>? bestMatch;

    for (final mode in _availableModes) {
      final startStr = mode['start_time'] as String?;
      final endStr = mode['end_time'] as String?;
      
      if (startStr != null && endStr != null) {
        if (_isTimeInRange(currentTime, startStr, endStr)) {
          bestMatch = mode;
          // If we found a "Break" (Istirahat), prioritize it?
          // Or usually shifts don't overlap much.
          // Let's bias towards shorter durations (likely breaks)?
          // For now, first match is good.
          break;
        }
      }
    }

    if (bestMatch != null) {
      setState(() {
        _selectedMode = bestMatch;
        // Optionally update _workTimeMode too so it shows selected immediately
         _workTimeMode = bestMatch!['code'] as String? ?? bestMatch!['name'] as String?;
      });
    }
  }

  bool _isTimeInRange(TimeOfDay current, String startStr, String endStr) {
    try {
      final startParts = startStr.split(':');
      final endParts = endStr.split(':');
      
      final start = TimeOfDay(hour: int.parse(startParts[0]), minute: int.parse(startParts[1]));
      final end = TimeOfDay(hour: int.parse(endParts[0]), minute: int.parse(endParts[1]));
      
      final nowMinutes = current.hour * 60 + current.minute;
      final startMinutes = start.hour * 60 + start.minute;
      final endMinutes = end.hour * 60 + end.minute;

      if (endMinutes < startMinutes) {
        // Crosses midnight (e.g. 22:00 to 06:00)
        return nowMinutes >= startMinutes || nowMinutes <= endMinutes;
      } else {
        return nowMinutes >= startMinutes && nowMinutes <= endMinutes;
      }
    } catch (e) {
      debugPrint('Error parsing time range: $startStr - $endStr');
      return false;
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
      final modeName = _selectedMode != null ? _selectedMode!['name'] : 'Standar';
      final typeName = pickedMode == 'check_in' ? 'MASUK' : 'KELUAR';
      _showMessage(
        'Mode: $modeName - $typeName',
        MessageType.success,
        seconds: 2,
      );
    }
  }

  // Helper moved from below
  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    return 'work_time';
  }

  // Old methods removed to resolve duplication with new Shift Mode implementation

  Future<void> _handleModeChange(String newMode) async {
    if (_attendanceMode == newMode) return;

    await ModeConfirmationDialog.show(
      context: context,
      currentMode: _attendanceMode,
      newMode: newMode,
      onConfirm: () {
        setState(() => _attendanceMode = newMode);
        _showMessage(
          'Berhasil mengubah mode ke ${newMode == 'check_in' ? 'Check In' : 'Check Out'}',
          MessageType.success,
          seconds: 2,
        );
      },
    );
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

            // ✅ IMPROVED: Face Detection Overlays - Pas dengan ukuran wajah dan tampilkan nama
            if (_detectedFaces.isNotEmpty && _cameraController != null)
              ..._detectedFaces.map((face) {
                // ✅ FIXED: Correct Aspect Ratio & Mirroring Logic for BoxFit.cover
                final screenWidth = screenSize.width;
                final screenHeight = screenSize.height;
                final previewSize = _cameraController!.value.previewSize!;
                // Swap width/height because we are in portrait but previewSize is landscape (sensor)
                final videoWidth = previewSize.height;
                final videoHeight = previewSize.width;
                
                final screenRatio = screenWidth / screenHeight;
                final videoRatio = videoWidth / videoHeight;
                
                double scale;
                if (screenRatio > videoRatio) {
                  // Screen is wider than video -> Match width
                  scale = screenWidth / videoWidth;
                } else {
                  // Screen is taller than video -> Match height
                  scale = screenHeight / videoHeight;
                }
                
                final scaledWidth = videoWidth * scale;
                final scaledHeight = videoHeight * scale;
                
                // Center the video in the screen
                final offsetX = (screenWidth - scaledWidth) / 2;
                final offsetY = (screenHeight - scaledHeight) / 2;
                
                // Get normalized coordinates from detection
                double nLeft = (face['left'] as num).toDouble();
                double nTop = (face['top'] as num).toDouble();
                double nWidth = (face['width'] as num).toDouble();
                double nHeight = (face['height'] as num).toDouble();
                
                // ✅ MIRRORING: Flip X for front camera
                // Since we use a file (non-mirrored) but preview is mirrored
                nLeft = 1.0 - (nLeft + nWidth);
                
                // Map to screen coordinates
                final left = offsetX + nLeft * scaledWidth;
                final top = offsetY + nTop * scaledHeight;
                final width = nWidth * scaledWidth;
                final height = nHeight * scaledHeight;
                
                final status = face['status'] as String? ?? 'detecting';
                // ✅ FIXED: Support both key naming conventions
                final userName = (face['userName'] as String?) ?? (face['name'] as String?);
                final similarity = face['similarity'] as double?;
                
                // ✅ NEW: Different colors based on status
                Color borderColor;
                Color glowColor;
                IconData? statusIcon;
                String? statusText;
                
                switch (status) {
                  case 'detecting':
                    borderColor = Colors.blue;
                    glowColor = Colors.blue.withOpacity(0.4);
                    statusIcon = Icons.search;
                    statusText = null; // ✅ HIDDEN
                    break;
                  case 'processing':
                    borderColor = Colors.orange;
                    glowColor = Colors.orange.withOpacity(0.4);
                    statusIcon = Icons.hourglass_empty;
                    statusText = null; // ✅ HIDDEN
                    break;
                  case 'matched':
                  case 'success': // ✅ ADDED: Validation success
                  case 'cooldown': // ✅ ADDED: User in cooldown
                    borderColor = Colors.green;
                    glowColor = Colors.green.withOpacity(0.6); // Stronger glow
                    statusIcon = Icons.check_circle;
                    // ✅ FIXED: Show name if available, otherwise generic success
                    statusText = userName ?? 'Berhasil';
                    break;
                  case 'unmatched':
                    borderColor = Colors.red;
                    glowColor = Colors.red.withOpacity(0.3);
                    statusIcon = Icons.person_off;
                    statusText = 'Tidak dikenali';
                    break;
                  default:
                    borderColor = Colors.grey;
                    glowColor = Colors.grey.withOpacity(0.3);
                    statusIcon = null;
                    statusText = null;
                }

                return Positioned(
                  left: left,
                  top: top,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    builder: (context, value, child) {
                      return Opacity(
                        opacity: value,
                        child: Transform.scale(
                          scale: 0.9 + (0.1 * value),
                          child: child,
                        ),
                      );
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // ✅ FIXED: Main border - completely transparent center with only colored borders
                        Container(
                          width: width,
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.transparent, // ✅ TRANSPARENT CENTER - NO BACKGROUND
                            border: Border.all(
                              color: borderColor,
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        // ✅ IMPROVED: Status label dengan nama user di bawah wajah
                        if (statusText != null)
                          Positioned(
                            top: height + 8,
                            left: -20,
                            right: -20,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: width + 40,
                                minWidth: 80,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: borderColor.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.4),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (statusIcon != null) ...[
                                    Icon(
                                      statusIcon,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(
                                      statusText,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.3,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  if (similarity != null && status == 'matched') ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.25),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '${(similarity * 100).toStringAsFixed(0)}%',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      ],
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
                                  final photoBase64 = item['photo_base64'] as String?;
                                  final photoUrl = item['photo_url'] as String?;
                                  ImageProvider? avatar;
                                  if (photoBase64 != null && photoBase64.isNotEmpty) {
                                    avatar = MemoryImage(base64Decode(photoBase64));
                                  } else if (photoUrl != null && photoUrl.isNotEmpty) {
                                    avatar = NetworkImage(photoUrl);
                                  }
                                  
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
                                      margin: const EdgeInsets.only(bottom: 2), // Reduced margin
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), // Reduced padding
                                      decoration: BoxDecoration(
                                        color: index % 2 == 0 ? Colors.grey.shade50 : Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: Colors.grey.shade200, width: 0.5),
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 14, // Reduced radius
                                            backgroundImage: avatar,
                                            child: avatar == null
                                                ? const Icon(Icons.person, size: 14, color: Colors.white70) // Reduced icon
                                                : null,
                                          ),
                                          const SizedBox(width: 8),
                                          // Name and Department
                                          Expanded(
                                            flex: 2,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item['name'],
                                                  style: const TextStyle(
                                                    fontSize: 11, // Reduced font
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.black87,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  item['department'] ?? '-',
                                                  style: TextStyle(
                                                    fontSize: 10, // Reduced font
                                                    color: Colors.grey.shade600,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                          // Time
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), // Compact padding
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade100,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  item['time'],
                                                  style: TextStyle(
                                                    fontSize: 10, // Reduced font
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.grey.shade800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 2), // Reduced gap
                                              if (item['type'] != null)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), // Compact padding
                                                  decoration: BoxDecoration(
                                                    color: item['type'] == 'check_in' 
                                                        ? Colors.green.withOpacity(0.1)
                                                        : Colors.orange.withOpacity(0.1),
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(
                                                      color: item['type'] == 'check_in'
                                                          ? Colors.green.withOpacity(0.5)
                                                          : Colors.orange.withOpacity(0.5),
                                                      width: 0.5,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    item['type'] == 'check_in' ? 'Masuk' : 'Pulang',
                                                    style: TextStyle(
                                                      fontSize: 9, // Reduced font
                                                      fontWeight: FontWeight.w600,
                                                      color: item['type'] == 'check_in'
                                                          ? Colors.green.shade700
                                                          : Colors.orange.shade800,
                                                    ),
                                                  ),
                                                ),
                                            ],
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
        _showMessage(
          'Mode: $label',
          MessageType.success,
          seconds: 2,
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
    // Direct link to the dynamic mode picker
    _openModePicker();
  }
  
  // NOTE: The _openModePicker method is now defined earlier in the class (restored)
  
  // Helper methods for the hardcoded UI are no longer needed
  // Removing buildModeOption to cleanup
}