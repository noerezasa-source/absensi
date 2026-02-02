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
  late FaceRecognitionTFLiteService _faceService; // ✅ Use SHARED instance from BiometricService
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
  
  // ✅ Store face data with user info for better UI
  final Map<int, Map<String, dynamic>> _faceDataMap = {};
  int _faceIdCounter = 0;

  // ✅ NEW: Persistent Face Tracking
  // Map<trackingId, {name, similarity, memberId, timestamp}>
  final Map<int, Map<String, dynamic>> _persistentFaceTracker = {};


  // ✅ NEW: Face Tracking State Machine
  final Map<int, FaceTrackingState> _faceStates = {};
  final Map<int, int> _stabilityCounters = {};
  final Map<int, Rect> _lastFaceRects = {};
  final Map<int, DateTime> _cooldowns = {};
  
  // Configuration
  static const int _requiredStableFrames = 1; // ⚡ REDUCED: Was 2 (Requires 3 frames total). Now 1 (Requires 2 frames total).
  static const double _stabilityThreshold = 300.0; // 🚀 INCREASED: More tolerant of motion (was 200.0)
  static const Duration _recognitionCooldown = Duration(seconds: 2); // ✅ FASTER: 2s cooldown for quicker re-recognition
  
  // ✅ Adaptive Multi-Frame Configuration (Speed + Accuracy Balance)
  static const int _multiFrameCount = 2; // ✅ REDUCED: 2 frames for faster response while maintaining liveness
  static const Duration _multiFrameInterval = Duration(milliseconds: 10); // ✅ FASTER: 10ms interval (Rapid burst)
  static const double _maxMovementThreshold = 100.0; // ✅ INCREASED: Allow more movement while walking (was 50.0)
  
  // ✅ Same-Mode Attendance Cooldown (5 minutes)
  static const Duration _sameModeCooldown = Duration(minutes: 5);
  final Map<String, DateTime> _lastAttendanceTime = {}; // Key: "memberId_mode"

  bool _isOnline = true;
  String? _debugExternalDir; // Cache for debug path
  DateTime _lastDebugSave = DateTime.fromMillisecondsSinceEpoch(0); // For throttling debug saves
  DateTime _lastCameraProcess = DateTime.fromMillisecondsSinceEpoch(0); // ✅ NEW: Throttle detection loop
  static const Duration _cameraThrottle = Duration(milliseconds: 85); // ✅ 85ms = ~12 FPS processing (Smooth & Efficient)

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
    _faceDataMap.clear();
    _detectedFaces.clear();
    _cameraController?.dispose();
    // ❌ REMOVED: _faceService.dispose(); // KEEP MODEL PERSISTENT IN MEMORY
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
    if (url.isEmpty) return null;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
         // debugPrint('⚠️ Invalid URI skipped: $url');
         return null;
      }
      
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await consolidateHttpClientResponseBytes(response);
      return base64Encode(bytes);
    } catch (e) {
      // debugPrint('Download to base64 failed: $e');
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
      // ✅ USE SHARED SERVICE: Prevents 2-3s delay from reloading models
      _faceService = await _biometricService.getFaceService();
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
        ResolutionPreset.veryHigh, // ✅ UPGRADED: Full HD for maximum clarity
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
    if (_isProcessing || _isTakingPicture) return;

    // ✅ THROTTLE: Don't process every frame (~12 FPS)
    final now = DateTime.now();
    if (now.difference(_lastCameraProcess) < _cameraThrottle) return;
    _lastCameraProcess = now;
    
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
            } else if (name == 'Error') {
               boxColor = Colors.red.withOpacity(0.5);
               statusText = 'Error';
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
    final templates = <Map<String, dynamic>>[]; // ✅ Added for Phase 4/5 logic
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
          );
          
          // Extract embedding array
          final embedding = template['embedding'] as List<dynamic>?;
          if (embedding != null) {
            embeddings.add(embedding.map((e) => (e as num).toDouble()).toList());
            templates.add(template); // Store full template for liveness analysis
            lastTemplate = template; 
            debugPrint('✅ Frame ${i + 1}/${_multiFrameCount} captured');

            // --- TURBO FAST-ACCEPT LOGIC (Phase 7/11) ---
            if (i == 0) {
               final liveness = _checkBehavioralLiveness([embedding.map((e) => (e as num).toDouble()).toList()], [template]);
               final bestMatch = await _biometricService.identifyBestMatchWithUserInfo(
                  capturedTemplate: template, 
                  organizationId: widget.organizationId,
                  threshold: 0.70,
                  strict: true,
               );
               
               if (liveness['isLive'] && bestMatch != null) {
                  final similarity = bestMatch['similarity'] as double? ?? 0.0;
                  final secondSim = bestMatch['second_similarity'] as double? ?? 0.0;
                  final gap = similarity - secondSim;
                  
                  // --- TURBO FAST-ACCEPT CRITERIA ---
                  bool isClearMatch = similarity > 0.85 || (similarity > 0.72 && gap > 0.05);

                  if (isClearMatch) {
                    debugPrint('⚡ TURBO: Immediate Accept (Sim: ${similarity.toStringAsFixed(3)}, Gap: ${gap.toStringAsFixed(3)})');
                    return {
                      ...template,
                      'embedding': embedding.map((e) => (e as num).toDouble()).toList(),
                      'frame_count': 1,
                      'multi_frame': false,
                      'turbo_mode': true,
                      'liveness_verified': true,
                      'liveness_detail': liveness,
                      'matched_user': bestMatch,
                    };
                  }
               }
            }
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
      
      // 2. Behavioral Liveness Check
      final livenessResult = _checkBehavioralLiveness(embeddings, templates);
      debugPrint('📊 Liveness Result: ${livenessResult['isLive']} - Reason: ${livenessResult['reason']}');
      
      if (!livenessResult['isLive']) {
        debugPrint('🚫 Liveness rejected: ${livenessResult['reason']}');
        return null;
      }

      // 3. Weighted Average (Phase 4)
      final weights = templates.map((t) => (t['qualityScore'] as double? ?? 0.5)).toList();
      final avgEmbedding = _weightedAverageEmbeddings(embeddings, weights);
      
      // Return template with averaged embedding
      return {
        ...?lastTemplate,
        'embedding': avgEmbedding,
        'frame_count': embeddings.length,
        'multi_frame': true,
        'liveness_verified': true,
        'liveness_detail': livenessResult,
      };
      
    } catch (e) {
      debugPrint('❌ Multi-frame capture error: $e');
      return null;
    }
  }

  // ✅ Phase 5: Multi-Frame Behavioral Liveness Analysis
  Map<String, dynamic> _checkBehavioralLiveness(List<List<double>> embeddings, List<Map<String, dynamic>> templates) {
    if (templates.length < 2) {
       // Single frame "Turbo" mode assumes liveness if similarity is very high
       // or relies on 3D depth from isolate
       final depth = (templates.first['advancedAttributes']?['depthScore'] ?? 0.0) as double;
       return {
         'isLive': depth > 0.010, // Base depth check
         'reason': 'turbo_depth_check',
         'depthScore': depth,
       };
    }

    // 1. Check Eye Variation (Blink Detection) over time
    double maxEyeOpen = 0.0;
    double minEyeOpen = 1.0;
    for (var t in templates) {
      final left = (t['qualityScores']?['leftEyeOpen'] ?? 0.0) as double;
      final right = (t['qualityScores']?['rightEyeOpen'] ?? 0.0) as double;
      final avg = (left + right) / 2;
      if (avg > maxEyeOpen) maxEyeOpen = avg;
      if (avg < minEyeOpen) minEyeOpen = avg;
    }
    final eyeVariation = maxEyeOpen - minEyeOpen;

    // 2. Check for Pixel-Perfect Identity (Static Image Detection)
    // If landmarks are EXACTLY the same across frames, it's a photo, not a human.
    bool pixelPerfectIdentity = true;
    for (int i = 0; i < templates.length - 1; i++) {
        final l1 = templates[i]['landmarks'] as Map?;
        final l2 = templates[i+1]['landmarks'] as Map?;
        if (l1 != null && l2 != null) {
          if (l1['noseBase']?['x'] != l2['noseBase']?['x']) {
            pixelPerfectIdentity = false;
          }
        }
    }

    // 3. Adaptive 3D Depth Check (Anti-Spoofing)
    double avgDepth = 0.0;
    double avgArea = 0.0;
    for (var t in templates) {
      avgDepth += (t['advancedAttributes']?['depthScore'] ?? 0.0) as double;
      final bbox = t['boundingBox'] as Map?;
      if (bbox != null) avgArea += (bbox['width'] as num) * (bbox['height'] as num);
    }
    avgDepth /= templates.length;
    avgArea /= templates.length;

    final double adaptiveThreshold = avgArea > 8000 ? 0.015 : 0.010;

    if (avgDepth < adaptiveThreshold) {
      return {'isLive': false, 'reason': 'flat_surface_detected', 'depthScore': avgDepth};
    }

    if (pixelPerfectIdentity) {
      return {'isLive': false, 'reason': 'static_image_detected'};
    }

    return {
      'isLive': true,
      'reason': eyeVariation > 0.15 ? 'blink_detected' : 'stable_3d_live',
      'eyeVariation': eyeVariation,
      'depthScore': avgDepth
    };
  }

  // ✅ Phase 4: Weighted average of multiple embeddings
  List<double> _weightedAverageEmbeddings(List<List<double>> embeddings, List<double> weights) {
    if (embeddings.isEmpty) return [];
    if (embeddings.length != weights.length) return _averageEmbeddings(embeddings);
    
    final embeddingSize = embeddings.first.length;
    final averaged = List<double>.filled(embeddingSize, 0.0);
    double totalWeight = 0.0;
    
    for (int j = 0; j < embeddings.length; j++) {
      final weight = weights[j];
      totalWeight += weight;
      for (int i = 0; i < embeddingSize; i++) {
        averaged[i] += embeddings[j][i] * weight;
      }
    }
    
    if (totalWeight == 0) return _averageEmbeddings(embeddings);
    for (int i = 0; i < embeddingSize; i++) averaged[i] /= totalWeight;

    double sumSquares = 0.0;
    for (var v in averaged) sumSquares += v * v;
    final double magnitude = sqrt(sumSquares);
    return magnitude < 1e-6 ? averaged : averaged.map((v) => v / magnitude).toList();
  }

  /// ✅ Average multiple embeddings (element-wise mean)
  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    final embeddingSize = embeddings.first.length;
    final averaged = List<double>.filled(embeddingSize, 0.0);
    for (final embedding in embeddings) {
      for (int i = 0; i < embeddingSize; i++) {
        averaged[i] += embedding[i];
      }
    }
    final count = embeddings.length.toDouble();
    for (int i = 0; i < embeddingSize; i++) averaged[i] /= count;
    double sumSquares = 0.0;
    for (var v in averaged) sumSquares += v * v;
    final double magnitude = sqrt(sumSquares);
    return magnitude < 1e-6 ? averaged : averaged.map((v) => v / magnitude).toList();
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
        final stopwatch = Stopwatch()..start();
        // ✅ Multi-Frame Averaging: Capture and average embeddings from 3 frames
        debugPrint('🎯 [BENCH] Starting multi-frame recognition for face $id');
        
        if (_lastStreamBytes == null) {
           debugPrint('⚠️ No stream bytes available for recognition');
           _faceStates[id] = FaceTrackingState.idle; // Reset
           return;
        }

        // Capture multi-frame averaged embedding
        final captureStart = stopwatch.elapsedMilliseconds;
        final template = await _captureMultiFrameEmbedding(face, id);
        final captureEnd = stopwatch.elapsedMilliseconds;
        debugPrint('🎬 [BENCH] Capture+Extraction took: ${captureEnd - captureStart}ms');
        
        if (template == null) {
           debugPrint('❌ Multi-frame capture failed, aborting recognition');
           _faceStates[id] = FaceTrackingState.idle;
           return;
        }
        
        final frameCount = template['frame_count'] ?? 1;
        debugPrint('✅ Using ${frameCount}-frame averaged embedding for matching');

        // Capture current bytes for attendance photo
        final bytes = Uint8List.fromList(_lastStreamBytes!);

        final matchStart = stopwatch.elapsedMilliseconds;
        final result = await _biometricService.identifyBestMatchWithUserInfo(
           capturedTemplate: template,
           organizationId: widget.organizationId,
           strict: true, // Enforce strict matching
           threshold: 0.70, // ✅ Phase 11 tuned
        );
        final matchEnd = stopwatch.elapsedMilliseconds;
        debugPrint('🔍 [BENCH] Matching against database took: ${matchEnd - matchStart}ms');
        debugPrint('🚀 [BENCH] TOTAL Recognition Cycle: ${stopwatch.elapsedMilliseconds}ms');

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
           
           _handleAttendance(result, bytes, template); // Fire and forget
            
            if (mounted) {
               SoundHelper.playSuccessSound(); 
            }
            // ✅ SUCCESS: Cooldown to prevent spam
            _cooldowns[id] = DateTime.now().add(_recognitionCooldown);

            // ✅ NEW: Adaptive Learning (Evolution)
            final matchedBiometricId = result['biometric_id'] as int?;
            final currentSim = result['similarity'] as double? ?? 0.0;
            
            if (matchedBiometricId != null && currentSim >= 0.90) {
               final originalTemplate = _biometricService.getParsedTemplateFromCache(matchedBiometricId);
               if (originalTemplate != null) {
                  _biometricService.evolveTemplate(
                    biometricId: matchedBiometricId,
                    currentTemplate: originalTemplate,
                    capturedTemplate: template,
                  );
               }
            }
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
       // ONLY if not already reset to idle (capture failure)
       if (_faceStates[id] != FaceTrackingState.idle) {
          _faceStates[id] = FaceTrackingState.cooldown;
       }
    }
  }


  // Reuse logic but modify to update persistent tracker

  
  // ✅ REMOVED: Processing queue eliminated to prevent delays
  // Attendance is now processed directly without queue overhead

  // ✅ OPTIMIZED: Direct Attendance Handling (No Queue)
  Future<void> _handleAttendance(
    Map<String, dynamic> result,
    Uint8List imageBytes,
    Map<String, dynamic> template,
  ) async {
    // Process directly without queue - run async in background
    try {
      final user = result; // result IS the user map from biometric service
      final memberId = user['organization_member_id'] as int;
      final userName = user['user_name'] ?? 'Unknown';
      final biometricId = user['biometric_id'] as int;
      final profilePhotoUrl = user['profile_photo_url'] as String?;
       
      final isCheckIn = _attendanceMode == 'check_in';
      final attendanceType = isCheckIn ? 'check_in' : 'check_out'; // Fixed logic
      
      // 🏁 RACE FIX: Cooldown check MUST be the very first thing (Sync Check)
      // Before any await.
      final cooldownKey = '${memberId}_$attendanceType';
      final lastTime = _lastAttendanceTime[cooldownKey];
      
      if (lastTime != null) {
          final timeSinceLastAttendance = DateTime.now().difference(lastTime);
          final remainingCooldown = _sameModeCooldown - timeSinceLastAttendance;
          
          if (remainingCooldown.isNegative == false) {
             // ... Cooldown Rejection Logic ...
              final remainingMinutes = remainingCooldown.inMinutes;
              final remainingSeconds = remainingCooldown.inSeconds % 60;
              debugPrint('⏳ USER $userName: Same-mode cooldown active. Wait ${remainingMinutes}m ${remainingSeconds}s');
              return;
          }
      }
      
      // 🔒 IMMEDIATE LOCK (Before DB Check or any Await)
      _lastAttendanceTime[cooldownKey] = DateTime.now();
      debugPrint('🔒 LOCKED Cooldown for $userName ($attendanceType) immediately.');

      // 🚀 OPTIMIZATION: HAPPY PATH - UPDATE UI IMMEDIATELY (Phase 9)
      _showMessage(
          'Sukses: $userName (${isCheckIn ? "MASUK" : "KELUAR"})',
          MessageType.success,
          seconds: 2,
      );

      debugPrint('Step 1: UI Update Start');
      if (mounted) {
          debugPrint('📋 TOP-LEVEL UI UPDATE: $userName, Dept=${user['department_name']}');
          setState(() {
            _totalProcessedToday++;
            final now = DateTime.now();
            final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
            
            // We use the last downloaded photo if available, otherwise fetch in background
            _recentAttendanceList.insert(0, {
              'name': userName,
              'department': user['department_name'] ?? '-',
              'photo_base64': null, // Will be updated if fetched
              'time': timeStr,
              'type': attendanceType,
              'timestamp': now,
            });
            if (_recentAttendanceList.length > 10) _recentAttendanceList.removeLast();
          });
      }
      debugPrint('Step 2: UI Update End');

      // Check duplicates (offline DB) - Now safe to await in background
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      debugPrint('Step 3: Duplicate Check Start ($todayStr)');
      
      final alreadyRecorded = await _offlineDb.hasDuplicateAttendance(
          organizationMemberId: memberId,
          eventType: attendanceType,
          attendanceDate: todayStr,
      );
      debugPrint('Step 4: Duplicate Check End ($alreadyRecorded)');
      
      if (alreadyRecorded) {
          debugPrint('⏭️ USER $userName: Already recorded in offline DB, skipping database write');
          return;
      }

      // 📥 BACKGROUND TASKS: Non-blocking
      debugPrint('Step 5: Background Tasks Start');
      _processBackgroundAttendance(user, template, attendanceType, memberId, userName, biometricId, profilePhotoUrl);
      debugPrint('Step 6: HandleAttendance Finished');

    } catch(e) {
       debugPrint('Error in handleAttendance: $e');
    }
  }

  // ✅ New helper for background tasks
  Future<void> _processBackgroundAttendance(
    Map<String, dynamic> user,
    Map<String, dynamic> template,
    String attendanceType,
    int memberId,
    String userName,
    int biometricId,
    String? profilePhotoUrl,
  ) async {
      try {
          // 1. Photo Fetch
          final profilePhotoBase64 = await _getProfilePhotoBase64(memberId, profilePhotoUrl)
              .timeout(const Duration(seconds: 3), onTimeout: () => null);

          // Update UI with photo if found
          if (mounted && profilePhotoBase64 != null) {
              setState(() {
                  for (var item in _recentAttendanceList) {
                      if (item['name'] == userName && item['photo_base64'] == null) {
                          item['photo_base64'] = profilePhotoBase64;
                          break;
                      }
                  }
              });
          }

          // 2. Database Save
          final offlineId = await _saveOfflineAttendance(
              memberId: memberId,
              userName: userName,
              attendanceType: attendanceType,
              template: template,
              localPhotoPath: null, 
              profilePhotoBase64: profilePhotoBase64,
          );

          // 3. Biometric Evolution & Usage Update
          await _biometricService.updateLastUsed(biometricId);
          
          if (offlineId != null && offlineId != -1) {
              debugPrint('💾 Saved attendance record for $userName ($attendanceType) to offline DB');
              if (_isOnline) {
                  AttendanceSyncService().syncPendingAttendances();
              }
          }
      } catch (e) {
          debugPrint('❌ Background processing failed for $userName: $e');
      }
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
                  child: CustomPaint(
                    painter: _FaceBracketPainter(color: boxColor),
                    child: Container(
                      width: width,
                      height: height,
                    ),
                  ),
                );
              }),

            // ✅ NEW: Premium Top Bar Overlay
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  // Back Button (Circular Translucent)
                  _buildCircularActionButton(
                    icon: Icons.chevron_left,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  // SESSION COUNT Pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E26).withOpacity(0.8),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.people_alt_outlined, color: Color(0xFF9B59B6), size: 20),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'SESSION COUNT',
                              style: TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              '$_totalProcessedToday',
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Manual Attendance
                  _buildCircularActionButton(
                    icon: Icons.assignment_ind_outlined,
                    onTap: () async {
                      if (_organizationMemberId != null) {
                        final success = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ManualCheckPage(
                              organizationMemberId: _organizationMemberId!,
                              memberData: {'organization_id': widget.organizationId},
                            ),
                          ),
                        );
                        if (success == true) {
                          // Refresh data if needed or show message
                          _showMessage('Absensi manual berhasil', MessageType.success);
                        }
                      } else {
                        _showMessage('Gagal: Sesi petugas tidak ditemukan', MessageType.error);
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  // Menu Button
                  _buildCircularActionButton(
                    icon: Icons.more_vert,
                    onTap: () => _showMenu(context),
                  ),
                ],
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

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(40),
                                      border: Border.all(color: const Color(0xFFE8DAEF), width: 1.2),
                                    ),
                                    child: Row(
                                      children: [
                                        // Compact Avatar with Ring
                                        Container(
                                          padding: const EdgeInsets.all(1.5),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(color: const Color(0xFF8E44AD).withOpacity(0.15)),
                                          ),
                                          child: CircleAvatar(
                                            radius: 18,
                                            backgroundColor: Colors.grey.shade100,
                                            backgroundImage: avatar,
                                            child: avatar == null
                                                ? const Icon(Icons.person, color: Colors.grey, size: 18)
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                item['name'],
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: Color(0xFF2C3E50),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                '${item['department'] ?? '-'} • ${item['type'] == 'check_in' ? 'Masuk' : 'Keluar'} • ${item['time']}',
                                                style: const TextStyle(
                                                  color: Color(0xFF8E44AD),
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        // Checkmark
                                        const Icon(
                                          Icons.check_circle,
                                          color: Color(0xFF27AE60),
                                          size: 24,
                                        ),
                                      ],
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

  Widget _buildCircularActionButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
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

/// ✅ NEW: Custom Painter for Face Bracket (VIOLET)
class _FaceBracketPainter extends CustomPainter {
  final Color color;
  final double bracketSize = 25.0;
  final double bracketWidth = 4.0;
  final double borderRadius = 30.0;

  _FaceBracketPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Use target violet if the provided color is generic green/red
    Color drawColor = color;
    if (color == Colors.green || color == Colors.red || color == Colors.blue) {
       drawColor = const Color(0xFF8E44AD); // Matches image
    }

    final paint = Paint()
      ..color = drawColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 1. Draw rounded main box with low opacity
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
    canvas.drawRRect(rrect, paint..color = drawColor.withOpacity(0.4));

    // 2. Draw 4 thick corner brackets
    final bracketPaint = Paint()
      ..color = drawColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = bracketWidth
      ..strokeCap = StrokeCap.round;

    // Top-Left
    canvas.drawLine(const Offset(0, 20), const Offset(0, 0), bracketPaint);
    canvas.drawLine(const Offset(0, 0), const Offset(20, 0), bracketPaint);

    // Top-Right
    canvas.drawLine(Offset(size.width - 20, 0), Offset(size.width, 0), bracketPaint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, 20), bracketPaint);

    // Bottom-Left
    canvas.drawLine(Offset(0, size.height - 20), Offset(0, size.height), bracketPaint);
    canvas.drawLine(Offset(0, size.height), Offset(20, size.height), bracketPaint);

    // Bottom-Right
    canvas.drawLine(Offset(size.width - 20, size.height), Offset(size.width, size.height), bracketPaint);
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width, size.height - 20), bracketPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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