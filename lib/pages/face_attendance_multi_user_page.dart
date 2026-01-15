// lib/pages/face_attendance_multi_user_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math'; // ✅ Valid element for sqrt
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
import 'package:flutter/foundation.dart'; // For compute
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:intl/intl.dart'; 
import 'package:path_provider/path_provider.dart'; // ✅ Added for debug path
import '../services/attendance_service.dart';
import '../helpers/sound_helper.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/mode_confirmation_dialog.dart';
import '../services/supabase_storage_service.dart';
import '../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../models/offline_attendance.dart';
import 'manual_check_page.dart';
import '../models/face_tracking_state.dart'; // ✅ NEW: State Machine Enum

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


  // ✅ NEW: Face Tracking State Machine
  final Map<int, FaceTrackingState> _faceStates = {};
  final Map<int, int> _stabilityCounters = {};
  final Map<int, Rect> _lastFaceRects = {};
  final Map<int, DateTime> _cooldowns = {};
  
  // Configuration
  static const int _requiredStableFrames = 0; // Optimized for Instant Recognition
  static const double _stabilityThreshold = 120.0; // High tolerance for movement
  static const Duration _recognitionCooldown = Duration(seconds: 3);
  
  // ✅ Multi-Frame Averaging Configuration (Optimized)
  static const int _multiFrameCount = 2; // Reduced from 3 to 2 for speed
  static const Duration _multiFrameInterval = Duration(milliseconds: 100); // Reduced from 150ms
  static const double _maxMovementThreshold = 50.0; // Max pixel movement between frames
  
  // ✅ Same-Mode Attendance Cooldown (5 minutes)
  static const Duration _sameModeCooldown = Duration(minutes: 5);
  final Map<String, DateTime> _lastAttendanceTime = {}; // Key: "memberId_mode"

  bool _isOnline = true;
  String? _debugExternalDir; // Cache for debug path
  DateTime _lastDebugSave = DateTime.fromMillisecondsSinceEpoch(0); // For throttling debug saves

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
        method: 'face_recognition',
        timestamp: TimezoneHelper.formatUtcForSupabase(DateTime.now()),
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

      // Get debug path once
      try {
        final dir = await getApplicationDocumentsDirectory();
        _debugExternalDir = dir.path;
      } catch (e) {
        debugPrint('Failed to get debug dir: $e');
      }

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
        ResolutionPreset.high, // ✅ UPGRADED: High resolution for better accuracy
        // ✅ FIXED: Stream requires YUV420 on Android, BGRA8888 on iOS
      imageFormatGroup: Platform.isAndroid 
          ? ImageFormatGroup.yuv420 
          : ImageFormatGroup.bgra8888,
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

  bool _isStreaming = false;

  void _startContinuousScan() {
    if (_cameraController == null || !_cameraController!.value.isInitialized || _isStreaming) {
      return;
    }

    try {
      _isStreaming = true;
      _cameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('Error starting image stream: $e');
      _isStreaming = false;
    }
  }

  Future<void> _stopStream() async {
    if (_cameraController != null && _cameraController!.value.isStreamingImages) { // Check value.isStreamingImages if available or just try catch
        try {
          await _cameraController!.stopImageStream();
        } catch (e) {
           debugPrint('Error stopping stream: $e');
        }
    }
    _isStreaming = false;
  }

  int _lastProcessingTime = 0;
  bool _isIdleMode = true; // Start in idle
  int _consecutiveNoFaceFrames = 0;

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing || _isTakingPicture || _isQueueProcessing) return;

    final currentTime = DateTime.now().millisecondsSinceEpoch;
    
    // ✅ DYNAMIC THROTTLING
    int throttleDuration;
    if (_cooldowns.isNotEmpty) {
      throttleDuration = 200; // Slower cooldown check
    } else if (_isIdleMode) {
      throttleDuration = 500; // Idle check
    } else {
      throttleDuration = 80; // ✅ FAST POLLING: 80ms for instant feel
    }
    
    if (currentTime - _lastProcessingTime < throttleDuration) return;
    _lastProcessingTime = currentTime;

    _isProcessing = true;

    try {
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }
      
      if (inputImage.bytes != null) {
        _lastStreamBytes = inputImage.bytes;
        _lastStreamWidth = image.width;
        _lastStreamHeight = image.height;
        if (inputImage.metadata?.rotation != null) {
           _lastStreamRotation = _rotationEnumValueToInt(inputImage.metadata!.rotation);
        }
      }

      final faces = await _faceService.detectFacesFromInputImage(inputImage);
      
      // ✅ Mode Switching Logic (Hysteresis)
      if (faces.isEmpty) {
        _consecutiveNoFaceFrames++;
        if (_consecutiveNoFaceFrames >= 10 && !_isIdleMode) {
          if (mounted) setState(() => _isIdleMode = true);
          debugPrint('📴 Entering idle mode (no faces)');
        }
      } else {
        _consecutiveNoFaceFrames = 0;
        if (_isIdleMode) {
          if (mounted) setState(() => _isIdleMode = false);
          debugPrint('📡 Entering active mode (${faces.length} faces)');
        }
      }
      
      _handleStreamFaces(faces, Size(image.height.toDouble(), image.width.toDouble()));

    } catch (e) {
      debugPrint('Error processing stream: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage?> _inputImageFromCameraImage(CameraImage image) async {
    if (_cameraController == null) return null;

    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;
    
    // Determine rotation
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        // Front camera
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // Back camera
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // Format
    InputImageFormat? format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // Bytes
  // Bytes
  final Uint8List bytes;
  int bytesPerRow;

  if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
     // ✅ OPTIMIZATION: Run heavy conversion in background isolate
     try {
       final planesData = image.planes.map((p) => _PlaneData(
         bytes: p.bytes,
         bytesPerRow: p.bytesPerRow,
         bytesPerPixel: p.bytesPerPixel,
       )).toList();

       bytes = await compute(_yuv420ToNv21Compute, _NV21ConvertParams(
         width: image.width,
         height: image.height,
         planes: planesData,
       ));
       
       format = InputImageFormat.nv21;
       bytesPerRow = image.width;
     } catch (e) {
       debugPrint('Error in NV21 conversion: $e');
       return null;
     }
  } else {
     bytes = _concatenatePlanes(image.planes);
     bytesPerRow = image.planes.first.bytesPerRow;
  }

  return InputImage.fromBytes(
    bytes: bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: bytesPerRow, // ✅ Use correct stride
    ),
  );
}


  // Hook to capture bytes from processCameraImage
  Uint8List? _lastStreamBytes;
  int _lastStreamWidth = 0;
  int _lastStreamHeight = 0;
  int _lastStreamRotation = 0; // NEW: Rotation in degrees

  int _rotationEnumValueToInt(InputImageRotation rotation) {
    switch (rotation) {
      case InputImageRotation.rotation0deg: return 0;
      case InputImageRotation.rotation90deg: return 90;
      case InputImageRotation.rotation180deg: return 180;
      case InputImageRotation.rotation270deg: return 270;
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };


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

  // ✅ REFACTORED: State Machine Core Logic
  Future<void> _handleStreamFaces(List<Face> faces, Size imageSize) async {
    final now = DateTime.now();
    
    // 1. Clean up stale states (faces that left the frame)
    final currentTrackingIds = faces.map((f) => f.trackingId ?? -1).toSet();
    _faceStates.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);
    _stabilityCounters.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);
    _lastFaceRects.removeWhere((id, _) => !currentTrackingIds.contains(id) && id != -1);
    
    // Check global cooldowns
    final activeCooldowns = Map<int, DateTime>.from(_cooldowns);
    activeCooldowns.forEach((id, time) {
      if (now.isAfter(time)) {
        _cooldowns.remove(id);
        _faceStates[id] = FaceTrackingState.idle;
      }
    });

    if (faces.isEmpty) {
      _hasFacesInView = false;
      if (mounted) setState(() => _detectedFaces = []);
      return;
    }

    _hasFacesInView = true;
    final displayFaces = <Map<String, dynamic>>[];

    for (final face in faces) {
      final id = face.trackingId ?? -1;
      if (id == -1) continue; // Skip untracked faces

      // Initialize state if new
      _faceStates.putIfAbsent(id, () => FaceTrackingState.idle);
      final currentState = _faceStates[id]!;
      
      // Early exit if in cooldown
      if (_cooldowns.containsKey(id)) {
        if (now.isBefore(_cooldowns[id]!)) {
           // Still in cooldown, just show box (gray)
           displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.cooldown));
           continue; 
        } else {
           _cooldowns.remove(id);
           _faceStates[id] = FaceTrackingState.idle;
        }
      }

      // STATE MACHINE LOGIC
      switch (currentState) {
        case FaceTrackingState.idle:
          // ✅ INSTANT RECOGNITION: Bypass Tracking, go straight to LOCKED/INFERENCE
          _faceStates[id] = FaceTrackingState.locked;
          _stabilityCounters[id] = 0;
          _lastFaceRects[id] = face.boundingBox;
           // Trigger Inference Immediately
          _triggerRecognition(face, imageSize);
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.locked));
          break;

        case FaceTrackingState.tracking:
          // Check Stability
          final lastRect = _lastFaceRects[id] ?? face.boundingBox;
          final movement = (face.boundingBox.center - lastRect.center).distance;
          
          if (movement < _stabilityThreshold) {
            _stabilityCounters[id] = (_stabilityCounters[id] ?? 0) + 1;
          } else {
            _stabilityCounters[id] = 0; // Reset if moved too much
          }
          _lastFaceRects[id] = face.boundingBox;

          // Check if stable enough to LOCK
          if ((_stabilityCounters[id] ?? 0) >= _requiredStableFrames) {
             _faceStates[id] = FaceTrackingState.locked;
             // Trigger Inference
             _triggerRecognition(face, imageSize);
          }
          
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.tracking));
          break;

        case FaceTrackingState.locked:
          // Waiting for inference to complete
          // Don't process anymore, just show LOCKED UI
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.locked));
          break;

        case FaceTrackingState.cooldown:
          displayFaces.add(_buildFaceDisplayData(face, FaceTrackingState.cooldown));
          break;
      }
    }

    if (mounted) {
      setState(() {
        _detectedFaces = displayFaces;
      });
    }
  }

  Map<String, dynamic> _buildFaceDisplayData(Face face, FaceTrackingState state) {
     // Determine color/status based on state
     Color boxColor;
     String? statusText;
     
     switch (state) {
       case FaceTrackingState.idle:
       case FaceTrackingState.tracking:
         boxColor = Colors.yellow;
         statusText = null; // Clean UI
         break;
       case FaceTrackingState.locked:
         boxColor = Colors.blue; 
         statusText = null; // Clean UI
         break;
       case FaceTrackingState.cooldown:
         // Look up result from persistent tracker
         final trackedData = _persistentFaceTracker[face.trackingId];
         if (trackedData != null) {
            final name = trackedData['name'] as String;
            if (name == 'Unknown') {
               boxColor = Colors.red;
               statusText = null; // Clean UI
            } else {
               boxColor = Colors.green;
               statusText = name;
            }
         } else {
            boxColor = Colors.grey;
            statusText = 'Done';
         }
         break;
     }

     return {
       'rect': face.boundingBox,
       'color': boxColor,
       'name': statusText,
       'trackingId': face.trackingId,
     };
  }

  /// ✅ Multi-Frame Averaging: Capture embeddings from multiple frames and average them
  Future<Map<String, dynamic>?> _captureMultiFrameEmbedding(Face face, int id) async {
    debugPrint('🎬 Starting multi-frame capture for face $id (${_multiFrameCount} frames)');
    
    final embeddings = <List<double>>[];
    Map<String, dynamic>? lastTemplate;
    Rect? previousFaceRect;
    
    try {
      // Capture multiple frames
      for (int i = 0; i < _multiFrameCount; i++) {
        // Wait for next frame (except first)
        if (i > 0) {
          await Future.delayed(_multiFrameInterval);
        }
        
        // Check if stream bytes are still available
        if (_lastStreamBytes == null) {
          debugPrint('⚠️ Stream bytes unavailable at frame $i');
          break; // Exit early instead of continue
        }
        
        // ✅ Movement Detection: Check if face moved too much
        if (previousFaceRect != null) {
          final currentRect = face.boundingBox;
          final movement = _calculateRectMovement(previousFaceRect, currentRect);
          
          if (movement > _maxMovementThreshold) {
            debugPrint('⚠️ Face moved too much (${movement.toStringAsFixed(1)}px), canceling multi-frame');
            break; // Cancel and use what we have
          }
        }
        previousFaceRect = face.boundingBox;
        
        // Deep copy bytes to avoid race conditions
        final bytes = Uint8List.fromList(_lastStreamBytes!);
        final width = _lastStreamWidth;
        final height = _lastStreamHeight;
        final rotation = _lastStreamRotation;
        
        // Extract embedding from this frame
        try {
          final template = await _faceService.buildTemplateFromBytes(
            bytes, width, height, rotation, face,
            allowSidePose: false,
            debugPath: _debugExternalDir,
          );
          
          // Extract embedding array
          final embedding = template['embedding'] as List<dynamic>?;
          if (embedding != null) {
            embeddings.add(embedding.map((e) => (e as num).toDouble()).toList());
            lastTemplate = template; // Keep last template for metadata
            debugPrint('✅ Frame ${i + 1}/${_multiFrameCount} captured');
          }
        } catch (e) {
          debugPrint('⚠️ Failed to extract embedding from frame $i: $e');
          break; // Exit on error
        }
      }
      
      // Check if we have enough frames
      if (embeddings.isEmpty) {
        debugPrint('❌ No embeddings captured, aborting');
        return null;
      }
      
      if (embeddings.length < 2) {
        debugPrint('⚠️ Only 1 frame captured, using single-frame embedding');
        return lastTemplate;
      }
      
      // Average embeddings
      final avgEmbedding = _averageEmbeddings(embeddings);
      debugPrint('✅ Averaged ${embeddings.length} embeddings');
      
      // Return template with averaged embedding
      return {
        ...?lastTemplate,
        'embedding': avgEmbedding,
        'frame_count': embeddings.length,
        'multi_frame': true,
      };
      
    } catch (e) {
      debugPrint('❌ Multi-frame capture error: $e');
      return null;
    }
  }

  /// ✅ Average multiple embeddings (element-wise mean)
  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    
    final embeddingSize = embeddings.first.length;
    final averaged = List<double>.filled(embeddingSize, 0.0);
    
    // Sum all embeddings
    for (final embedding in embeddings) {
      for (int i = 0; i < embeddingSize; i++) {
        averaged[i] += embedding[i];
      }
    }
    
    // Divide by count to get mean
    final count = embeddings.length.toDouble();
    for (int i = 0; i < embeddingSize; i++) {
      averaged[i] /= count;
    }
    
    return averaged;
  }

  /// ✅ Calculate movement distance between two face rectangles
  double _calculateRectMovement(Rect prev, Rect current) {
    final dx = (prev.center.dx - current.center.dx).abs();
    final dy = (prev.center.dy - current.center.dy).abs();
    return sqrt(dx * dx + dy * dy); // Euclidean distance
  }

  Future<void> _triggerRecognition(Face face, Size imageSize) async {
    final id = face.trackingId ?? -1;
    if (id == -1) return;

    try {
        // ✅ Multi-Frame Averaging: Capture and average embeddings from 3 frames
        debugPrint('🎯 Starting multi-frame recognition for face $id');
        
        if (_lastStreamBytes == null) {
           debugPrint('⚠️ No stream bytes available for recognition');
           _faceStates[id] = FaceTrackingState.idle; // Reset
           return;
        }

        // Capture multi-frame averaged embedding
        final template = await _captureMultiFrameEmbedding(face, id);
        
        if (template == null) {
           debugPrint('❌ Multi-frame capture failed, aborting recognition');
           _faceStates[id] = FaceTrackingState.idle;
           return;
        }
        
        final frameCount = template['frame_count'] ?? 1;
        debugPrint('✅ Using ${frameCount}-frame averaged embedding for matching');

        // Capture current bytes for attendance photo
        final bytes = Uint8List.fromList(_lastStreamBytes!);

        final result = await _biometricService.identifyBestMatchWithUserInfo(
           capturedTemplate: template,
           organizationId: widget.organizationId,
           strict: true, // Enforce strict matching
           threshold: 0.75, // ✅ STRONGER: Increased from 0.65 for better accuracy
        );

        if (result != null) {
           final name = result['user_name'];
           final memberId = result['organization_member_id'];
           final similarity = (result['similarity'] as double) * 100;
           
           // Update Persistent Tracker for UI
           _persistentFaceTracker[id] = {
             'name': name,
             'member_id': memberId,
             'similarity': similarity,
             'timestamp': DateTime.now(),
           };
           
           // Process Attendance Logic (Throttle/Queue)
           // ✅ FIXED: Pass context data to handler
           _handleAttendance(result, bytes, template);
           
           if (mounted) {
              SoundHelper.playSuccessSound(); 
           }
           // ✅ SUCCESS: Long Cooldown to prevent spam
           _cooldowns[id] = DateTime.now().add(_recognitionCooldown);

        } else {
           _persistentFaceTracker[id] = {
             'name': 'Unknown',
             'member_id': null,
             'similarity': 0.0,
             'timestamp': DateTime.now(),
           };
           if (mounted) {
              // Silenced error sound per user request
           }
           // ✅ UNKNOWN: Short Cooldown to RETRY quickly (Machine Gun Mode)
           // This allows moving subjects to be re-evaluated effectively
           _cooldowns[id] = DateTime.now().add(const Duration(milliseconds: 200));
        }

    } catch (e) {
       debugPrint('Recognition error: $e');
       _persistentFaceTracker[id] = {
          'name': 'Error',
          'member_id': null
       };
       // Error Cooldown
       _cooldowns[id] = DateTime.now().add(const Duration(seconds: 1));
    } finally {
       // Transition to COOLDOWN state (duration determined above)
       _faceStates[id] = FaceTrackingState.cooldown;
    }
  }


  // Reuse logic but modify to update persistent tracker

  
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

  // ✅ NEW: Centralized Attendance Handling with State Machine Validation
  Future<void> _handleAttendance(
    Map<String, dynamic> result,
    Uint8List imageBytes,
    Map<String, dynamic> template,
  ) async {
    _addToProcessingQueue(() async {
        try {
            final user = result; // result IS the user map from biometric service
            final memberId = user['organization_member_id'] as int;
            final userName = user['user_name'] ?? 'Unknown';
            final biometricId = user['biometric_id'] as int;
            final profilePhotoUrl = user['profile_photo_url'] as String?;
             
            final isCheckIn = _attendanceMode == 'check_in';
            final attendanceType = isCheckIn ? 'check_in' : 'check_out'; // Fixed logic
            
            // Check duplicates (offline DB)
            final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
            
            final alreadyRecorded = await _offlineDb.hasDuplicateAttendance(
                organizationMemberId: memberId,
                eventType: attendanceType,
                attendanceDate: todayStr,
            );
            
            if (alreadyRecorded) {
                debugPrint('⏭️ USER $userName: Already recorded in offline DB, skipping');
                return;
            }
            
            // ✅ Check Same-Mode Cooldown (5 minutes)
            final cooldownKey = '${memberId}_$attendanceType';
            final lastTime = _lastAttendanceTime[cooldownKey];
            
            if (lastTime != null) {
                final timeSinceLastAttendance = DateTime.now().difference(lastTime);
                final remainingCooldown = _sameModeCooldown - timeSinceLastAttendance;
                
                if (remainingCooldown.isNegative == false) {
                    // Still in cooldown
                    final remainingMinutes = remainingCooldown.inMinutes;
                    final remainingSeconds = remainingCooldown.inSeconds % 60;
                    
                    debugPrint('⏳ USER $userName: Same-mode cooldown active. Wait ${remainingMinutes}m ${remainingSeconds}s');
                    
                    if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    '$userName sudah ${attendanceType == 'check_in' ? 'Check-In' : 'Check-Out'}. '
                                    'Ganti mode atau tunggu ${remainingMinutes}m ${remainingSeconds}s',
                                ),
                                backgroundColor: Colors.orange,
                                duration: const Duration(seconds: 3),
                            ),
                        );
                    }
                    return;
                }
            }
            
            // Get Profile Photo Base64
            final profilePhotoBase64 = await _getProfilePhotoBase64(
                memberId,
                profilePhotoUrl,
            ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);

            // Save Offline (Save bytes to file for proof?)
            // For Kiosk mode, maybe we don't save every file to disk to save space?
            // Or only on success. 
            // We use imageBytes directly to encode for DB if needed, but offline DB expects file path.
            // Let's Skip file saving for speed unless required. 
            // Saving Base64 directly to DB is supported by _saveOfflineAttendance logic if we modify it, 
            // but currently it takes localPhotoPath.
            
            // Workaround: Use bytes to creating a temp file is expensive.
            // Just pass null for localPhotoPath and rely on template embedding?
            // Or base64 encode bytes.
            
            String? capturedBase64;
            // capturedBase64 = base64Encode(imageBytes); // Can be large
            
            final offlineId = await _saveOfflineAttendance(
                memberId: memberId,
                userName: userName,
                attendanceType: attendanceType,
                template: template,
                localPhotoPath: null, // Skipping file save for speed
                profilePhotoBase64: profilePhotoBase64,
            );
            
            // ✅ Update Last Attendance Time for Cooldown Tracking
            if (offlineId != null && offlineId != -1) {
                _lastAttendanceTime[cooldownKey] = DateTime.now();
                debugPrint('✅ Updated cooldown tracker for $userName ($attendanceType)');
            }
            
            // Trigger Sync
             if (_isOnline && offlineId != null && offlineId != -1) {
                // Delayed sync
                Timer(const Duration(seconds: 5), () {
                     AttendanceSyncService().syncPendingAttendances();
                });
            }
            
            // Update Biometric Usage
            await _biometricService.updateLastUsed(biometricId);
            
            // Update UI list
            if (mounted) {
                setState(() {
                  _totalProcessedToday++;
                  final now = DateTime.now();
                  final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
                  
                  _recentAttendanceList.insert(0, {
                    'name': userName,
                    'department': user['department_name'] ?? '-',
                    'photo_base64': profilePhotoBase64,
                    'time': timeStr,
                    'type': attendanceType,
                    'timestamp': now,
                  });
                   if (_recentAttendanceList.length > 10) _recentAttendanceList.removeLast();
                });
            }
            
            _showMessage(
                'Sukses: $userName (${isCheckIn ? "MASUK" : "KELUAR"})',
                MessageType.success,
                seconds: 2,
            );

        } catch(e) {
           debugPrint('Error in handleAttendance: $e');
        }
    });
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
                  scale = screenWidth / videoWidth;
                } else {
                  scale = screenHeight / videoHeight;
                }
                
                final scaledWidth = videoWidth * scale;
                final scaledHeight = videoHeight * scale;
                
                final offsetX = (screenWidth - scaledWidth) / 2;
                final offsetY = (screenHeight - scaledHeight) / 2;
                
                // ✅ UPDATED: Use Rect from State Machine
                final rect = face['rect'] as Rect;
                final boxColor = face['color'] as Color;
                final name = face['name'] as String?; // Status text or User Name

                // Get normalized coordinates (assuming rect is already normalized?? NO, rect is usually raw or normalized?)
                // Wait, ML Kit returns absolute coordinates based on image size?
                // In _handleStreamFaces, 'rect' is face.boundingBox.
                // face.boundingBox is in IMAGE COORDINATES (e.g. 0..720, 0..1280).
                
                // We need to normalize them first IF they are absolute.
                // params.width/height in detection were image dimensions.
                // Let's assume we need to normalize relative to Image Size.
                
                // ACTUALLY: The previous code expected 'left', 'top' as normalized (0..1)?
                // Let's check previous code.
                // "double nLeft = (face['left'] as num).toDouble();"
                // If it was normalized, fine.
                
                // But `InputImage` from `CameraImage`... ML Kit returns pixel coordinates.
                // So we must normalize them by `videoWidth` and `videoHeight` (sensor size).
                
                // However, `videoWidth` here is `previewSize.height` (720).
                // `videoHeight` is `previewSize.width` (1280).
                // The image source was also NV21 with these dims.
                
                double nLeft = rect.left / videoWidth; 
                double nTop = rect.top / videoHeight;
                double nWidth = rect.width / videoWidth;
                double nHeight = rect.height / videoHeight;

                // ✅ MIRRORING FIX: Flip X for front camera
                nLeft = 1.0 - (nLeft + nWidth);
                
                // Map to screen coordinates
                final left = offsetX + nLeft * scaledWidth;
                final top = offsetY + nTop * scaledHeight;
                final width = nWidth * scaledWidth;
                final height = nHeight * scaledHeight;
                
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
                        // Border Box
                        Container(
                          width: width,
                          height: height,
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            border: Border.all(
                              color: boxColor,
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        // Status/Name Label
                        if (name != null)
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
                                color: boxColor.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.4),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Text(
                                name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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


// ✅ ISOLATE WRAPPERS (Top-Level)
class _PlaneData {
  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
  _PlaneData({required this.bytes, required this.bytesPerRow, this.bytesPerPixel});
}

class _NV21ConvertParams {
  final int width;
  final int height;
  final List<_PlaneData> planes;
  _NV21ConvertParams({required this.width, required this.height, required this.planes});
}

Uint8List _yuv420ToNv21Compute(_NV21ConvertParams params) {
  final int width = params.width;
  final int height = params.height;
  final List<_PlaneData> planes = params.planes;
  
  final int ySize = width * height;
  final int uvSize = width * height ~/ 2;
  final Uint8List nv21 = Uint8List(ySize + uvSize);

  // Y Plane
  final _PlaneData yData = planes[0];
  final Uint8List yBytes = yData.bytes;
  final int yStride = yData.bytesPerRow;

  for (int y = 0; y < height; y++) {
    final int srcPos = y * yStride;
    final int dstPos = y * width;
    for (int x = 0; x < width; x++) {
       nv21[dstPos + x] = yBytes[srcPos + x];
    }
  }

  // UV Planes
  final _PlaneData uData = planes[1];
  final _PlaneData vData = planes[2];
  final Uint8List uBytes = uData.bytes;
  final Uint8List vBytes = vData.bytes;
  final int uStride = uData.bytesPerRow;
  final int vStride = vData.bytesPerRow;
  final int pixelStride = uData.bytesPerPixel ?? 1;

  int uvIndex = ySize;
  for (int y = 0; y < height ~/ 2; y++) {
    for (int x = 0; x < width ~/ 2; x++) {
      final int uIndex = y * uStride + x * pixelStride;
      final int vIndex = y * vStride + x * pixelStride;
      
      if (vIndex < vBytes.length && uIndex < uBytes.length) {
         nv21[uvIndex++] = vBytes[vIndex];
         nv21[uvIndex++] = uBytes[uIndex];
      }
    }
  }
  return nv21;
}