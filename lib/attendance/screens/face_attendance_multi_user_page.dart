// lib/pages/face_attendance_multi_user_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math'; // ✅ Valid element for sqrt
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../helpers/language_helper.dart';
import '../services/biometric_service.dart';
import '../services/face_recognition_tflite_service.dart';
import '../painters/face_detector_painter.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/attendance_service.dart';
import '../../helpers/sound_helper.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../../models/offline_attendance.dart';
import '../../models/work_schedule_models.dart';
import 'manual_check_page.dart';
import '../../models/face_tracking_state.dart'; // ✅ NEW: State Machine Enum

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

enum MessageType { idle, processing, loading, success, error, warning, info }

class _FaceAttendanceMultiUserPageState
    extends State<FaceAttendanceMultiUserPage> {
  CameraController? _cameraController;
  late FaceRecognitionTFLiteService
  _faceService; // ✅ Use SHARED instance from BiometricService
  final BiometricService _biometricService = BiometricService();
  final AttendanceService _attendanceService = AttendanceService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _attendanceSyncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  final bool _isTakingPicture =
      false; // ✅ NEW: Prevent concurrent camera captures
  String? _currentMessage;
  MessageType _messageType = MessageType.idle;
  Position? _currentPosition;
  String _organizationTimezone = 'Asia/Jakarta';

  // ✅ NEW: Setup Phase Tracking
  bool _isSystemReady = false;
  double _initProgress = 0.0;
  String _initStatus = 'Initializing...';

  Timer? _continuousScanTimer;
  Timer? _messageTimer;
  Timer? _scheduleCheckTimer;

  final List<Map<String, dynamic>> _recentAttendanceList = [];
  int _totalProcessedToday = 0;
  String _organizationName = '';
  int? _organizationMemberId;

  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  DailySchedule? _dailySchedule; // ✅ NEW: for break time validation
  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  bool _isRefreshing = false;

  List<Map<String, dynamic>> _detectedFaces = [];

  // ✅ Store face data with user info for better UI
  final Map<int, Map<String, dynamic>> _faceDataMap = {};

  // ✅ NEW: Persistent Face Tracking
  // Map<trackingId, {name, similarity, memberId, timestamp}>
  final Map<int, Map<String, dynamic>> _persistentFaceTracker = {};

  // ✅ NEW: Face Tracking State Machine
  final Map<int, FaceTrackingState> _faceStates = {};
  final Map<int, int> _stabilityCounters = {};
  final Map<int, Rect> _lastFaceRects = {};
  final Map<int, DateTime> _cooldowns = {};

  // ✅ NEW: Centroid Tracker State
  final Map<int, Offset> _activeTrackers = {};
  int _nextTrackerId = 1;
  static const double _maxTrackingDistance = 150.0;

  // Configuration
  static const int _requiredStableFrames =
      3; // ⚡ STABLE: Require 3 stable frames before recognition (prevents accidental triggers)
  static const double _stabilityThreshold =
      300.0; // 🚀 INCREASED: More tolerant of motion (was 200.0)
  static const Duration _recognitionCooldown = Duration(
    seconds: 2,
  ); // ✅ FASTER: 2s cooldown for quicker re-recognition

  // ✅ Adaptive Configuration (Speed + Accuracy Balance)
  // ✅ Same-Mode Attendance Cooldown (5 minutes)
  static const Duration _sameModeCooldown = Duration(minutes: 5);
  final Map<String, DateTime> _lastAttendanceTime = {}; // Key: "memberId_mode"

  bool _isOnline = true;
  DateTime _lastCameraProcess = DateTime.fromMillisecondsSinceEpoch(
    0,
  ); // ✅ NEW: Throttle detection loop
  static const Duration _cameraThrottle = Duration(
    milliseconds: 30, // ⚡ FAST: ~33 FPS for maximum smoothness (was 150ms)
  );

  static const Duration _idleCameraThrottle = Duration(
    milliseconds: 100, // ⚡ FAST: Quicker response even when idle (was 500ms)
  );

  DateTime _lastUIUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _uiThrottle = Duration(
    milliseconds: 33, // ⚡ SILKY: ~30 FPS UI updates (was 150ms)
  );

  @override
  void initState() {
    super.initState();
    _initializeSystem();
  }

  Future<void> _initializeSystem() async {
    final stopwatch = Stopwatch()..start();
    debugPrint('🏁 Starting high-performance system initialization...');

    try {
      // Step 1: Kiosk Mode (5%)
      setState(() {
        _initProgress = 0.05;
        _initStatus = 'Warming up UI...';
      });
      await _enableKioskMode();
      await Future.delayed(const Duration(milliseconds: 100));

      // Step 2: Org & Settings (15%)
      setState(() {
        _initProgress = 0.15;
        _initStatus = 'Loading organization settings...';
      });
      await _loadOrganizationData();
      _startScheduleCheck();

      // Step 3: Face Service & Models (40%)
      setState(() {
        _initProgress = 0.40;
        _initStatus = 'Loading AI Models (Multi-Threaded)...';
      });
      await _initializeFaceService();

      // Step 4: Camera (70%)
      setState(() {
        _initProgress = 0.70;
        _initStatus = 'Preparing high-speed camera...';
      });
      await _initializeCamera();

      // Step 5: Location & DB Cache (90%)
      setState(() {
        _initProgress = 0.90;
        _initStatus = 'Warming up biometric cache...';
      });
      await Future.wait([
        _getCurrentLocation().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            debugPrint('⚠️ Location timeout - continuing without location');
            return;
          },
        ),
        _checkConnectivity().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            debugPrint('⚠️ Connectivity check timeout - continuing');
            return;
          },
        ),
        _biometricService
            .getAllActiveFaceTemplatesWithUserInfo(widget.organizationId)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                debugPrint('⚠️ Face templates load timeout - continuing');
                return [];
              },
            ),
      ]);

      // Final: Ready (100%)
      setState(() {
        _initProgress = 1.0;
        _initStatus = 'Ready!';
      });
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        setState(() => _isSystemReady = true);
        // ✅ Load modes and auto-select shift at startup
        await _loadAvailableModes();
        _autoSelectCurrentShift();

        _attendanceSyncService.startAutoSync();
        debugPrint(
          '🚀 System initialized and ready in ${stopwatch.elapsedMilliseconds}ms',
        );
      }
    } catch (e) {
      debugPrint('❌ Initialization failed: $e');
      _showMessage(
        '${AppLanguage.tr('attendance.face.init_failed')}$e',
        MessageType.error,
      );
    }
  }

  @override
  void dispose() {
    _continuousScanTimer?.cancel();
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _isProcessing = false;
    _faceDataMap.clear();
    _detectedFaces.clear();
    _recentAttendanceList.clear();
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
    if (mounted) {
      setState(() {
        _isOnline =
            result.isNotEmpty && !result.contains(ConnectivityResult.none);
      });
    }

    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        setState(() {
          _isOnline =
              results.isNotEmpty && !results.contains(ConnectivityResult.none);
        });
      }
    });
  }

  Future<String?> _getProfilePhotoBase64(
    int memberId,
    String? remoteUrl,
  ) async {
    try {
      final cached = await _offlineDb.findMemberByOrgIdInCache(memberId);
      final cachedProfile =
          cached?['organization_members']?['user_profiles']
              as Map<String, dynamic>?;
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
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(
        _organizationTimezone,
      );
      final isDuplicate = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      );
      if (isDuplicate) {
        debugPrint(
          '⚠️ Duplicate offline attendance ignored for member $memberId, type $attendanceType, date $todayStr',
        );
        return -1; // sentinel for duplicate
      }

      final capturedBase64 = await _encodeFileToBase64(localPhotoPath);

      // ✅ MULTI-SHIFT: Encode full shift details if available
      String modeToSave = _getWorkTimeMode();
      if (_selectedMode != null) {
        try {
          // Combine the code with full details
          final shiftData = Map<String, dynamic>.from(_selectedMode!);
          shiftData['mode_code'] =
              modeToSave; // Ensure the simple code is preserved
          modeToSave = jsonEncode(shiftData);
        } catch (e) {
          debugPrint('Failed to encode shift data: $e');
        }
      }

      OfflineAttendance record = OfflineAttendance(
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

      // Try online first if connected
      bool syncSuccess = false;
      if (_isOnline) {
        try {
          final rawData = {
            'face_recognition': true,
            'work_time_mode': modeToSave,
            'synced_from_offline': false,
          };

          if (attendanceType == 'check_in') {
            await _attendanceService.checkIn(
              organizationMemberId: memberId,
              method: 'face_recognition',
              photoUrl: '', // Face recognition uses embeddings
              rawData: rawData,
            );
          } else if (attendanceType == 'check_out') {
            await _attendanceService.checkOut(
              organizationMemberId: memberId,
              method: 'face_recognition',
              photoUrl: '',
              rawData: rawData,
            );
          } else if (attendanceType == 'break_out' ||
              attendanceType == 'break_start') {
            await _attendanceService.breakOut(
              organizationMemberId: memberId,
              method: 'face_recognition',
              photoUrl: '',
              rawData: rawData,
            );
          } else if (attendanceType == 'break_in' ||
              attendanceType == 'break_end') {
            await _attendanceService.breakIn(
              organizationMemberId: memberId,
              method: 'face_recognition',
              photoUrl: '',
              rawData: rawData,
            );
          }
          syncSuccess = true;
          debugPrint('✅ Online face attendance recorded for $userName');
        } catch (e) {
          debugPrint('⚠️ Online face failed, preserving for offline sync: $e');
        }
      }

      record = record.copyWith(isSynced: syncSuccess);
      final id = await _offlineDb.insertAttendance(record);

      // Trigger background sync if not already successful
      if (!syncSuccess) {
        AttendanceSyncService().syncPendingAttendances();
      }
      return id;
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

  Future<void> _refreshTemplates() async {
    if (_isRefreshing || _isProcessing) return;

    setState(() {
      _isRefreshing = true;
      _showMessage(
        AppLanguage.tr('attendance.face.refreshing_faces'),
        MessageType.loading,
        seconds: 60,
      ); // Long timeout
    });

    try {
      await _biometricService.refreshCache(widget.organizationId);
      if (mounted) {
        _showMessage(
          AppLanguage.tr('attendance.face.refresh_success'),
          MessageType.success,
        );
      }
    } catch (e) {
      debugPrint('Refresh faces error: $e');
      if (mounted) {
        _showMessage(
          AppLanguage.tr('attendance.face.refresh_failed'),
          MessageType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  Future<void> _loadOrganizationData() async {
    final orgId = widget.organizationId;
    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', orgId)
          .maybeSingle();

      if (org != null && mounted) {
        setState(() {
          _organizationTimezone = org['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = org['name'] as String? ?? '';
        });

        // Cache for offline use
        await _offlineDb.cacheOrganizationData({
          'id': orgId,
          'name': _organizationName,
          'timezone': _organizationTimezone,
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading org data: $e');

      // Try fallback from cache
      final cachedOrg = await _offlineDb.getOrganizationData(orgId);
      if (cachedOrg != null && mounted) {
        setState(() {
          _organizationTimezone =
              cachedOrg['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = cachedOrg['name'] as String? ?? '';
        });
        debugPrint('💾 Using cached organization data');
      }
    }

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final member = await _supabase
            .from('organization_members')
            .select('id')
            .eq('organization_id', orgId)
            .eq('user_id', userId)
            .eq('is_active', true)
            .maybeSingle();

        if (member != null) {
          final memberId = member['id'] as int;
          setState(() {
            _organizationMemberId = memberId;
          });
          await _loadMemberSchedule(memberId);
          // ✅ Load DailySchedule for break time validation
          _loadDailySchedule(memberId);
        }
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error finding member ID: $e');

      // Fallback from cache
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final cachedMembers = await _offlineDb.getOrganizationMembers(orgId);
        if (cachedMembers != null) {
          final member = cachedMembers.firstWhere(
            (m) => m['user_id'] == userId,
            orElse: () => <String, dynamic>{}, // explicit type
          );
          if (member.isNotEmpty && member['id'] != null) {
            final memberId = member['id'] as int;
            if (mounted) {
              setState(() {
                _organizationMemberId = memberId;
              });
            }
            debugPrint('💾 Using cached admin member ID: $memberId');
            // Can't reliably load schedule offline yet unless cached, but at least manual button works
          }
        }
      }
    }
  }

  Future<void> _enableKioskMode() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } catch (e) {
      debugPrint('Error kiosk mode: $e');
    }
  }

  Future<void> _initializeFaceService() async {
    try {
      _showMessage(
        AppLanguage.tr('attendance.face.preparing'),
        MessageType.loading,
      );
      // ✅ USE SHARED SERVICE: Prevents 2-3s delay from reloading models
      _faceService = await _biometricService.getFaceService();
      debugPrint('✅ Face service initialized successfully');
      _clearMessage();
    } catch (e) {
      debugPrint('❌ Failed to init TFLite: $e');
      if (mounted) {
        _showMessage(
          'Face service init failed: $e',
          MessageType.error,
          seconds: 10,
        );
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
      debugPrint('📷 Initializing camera...');
      final cameras = await availableCameras();
      debugPrint('📷 Available cameras: ${cameras.length}');
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      debugPrint('📷 Selected camera: ${frontCamera.name}');

      // ✅ FIXED: Dispose old controller if exists
      if (_cameraController != null) {
        await _cameraController!.dispose();
      }

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset
            .high, // ✅ OPTIMIZED: 720p is much faster and sharp enough
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup
                  .yuv420 // YUV420 untuk ML Kit
            : ImageFormatGroup.bgra8888, // iOS standard
      );

      await _cameraController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Camera initialization timeout');
        },
      );
      debugPrint('✅ Camera initialized successfully');

      try {
        await _cameraController!.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('Auto-focus not supported: $e');
      }

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
        debugPrint('✅ Starting continuous scan...');
        _startContinuousScan();
      }
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      if (mounted) {
        _showMessage('Camera error: $e', MessageType.error, seconds: 10);
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
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isStreaming) {
      debugPrint(
        '⚠️ Cannot start scan: camera=${_cameraController != null}, initialized=${_cameraController?.value.isInitialized}, streaming=$_isStreaming',
      );
      return;
    }

    try {
      _isStreaming = true;
      debugPrint('✅ Starting image stream...');
      _cameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('❌ Error starting image stream: $e');
      _isStreaming = false;
    }
  }

  bool _isIdleMode = true; // Start in idle
  int _consecutiveNoFaceFrames = 0;

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing || _isTakingPicture) return;

    // ✅ DYNAMIC THROTTLE: Slow down to 2 FPS when idle (no faces) to save CPU
    final now = DateTime.now();
    final currentThrottle = _isIdleMode ? _idleCameraThrottle : _cameraThrottle;

    if (now.difference(_lastCameraProcess) < currentThrottle) return;
    _lastCameraProcess = now;

    _isProcessing = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        debugPrint('⚠️ InputImage is null');
        _isProcessing = false;
        return;
      }

      Uint8List? currentFrameBytes;
      int currentWidth = image.width;
      int currentHeight = image.height;
      int currentRotation = 0;

      if (inputImage.bytes != null) {
        currentFrameBytes = inputImage.bytes;
        if (inputImage.metadata?.rotation != null) {
          switch (inputImage.metadata!.rotation) {
            case InputImageRotation.rotation0deg:
              currentRotation = 0;
            case InputImageRotation.rotation90deg:
              currentRotation = 90;
            case InputImageRotation.rotation180deg:
              currentRotation = 180;
            case InputImageRotation.rotation270deg:
              currentRotation = 270;
          }
        }
      }

      final faces = await _faceService.detectFacesFromInputImage(inputImage);

      // Debug: Log face detection
      if (faces.isNotEmpty) {
        debugPrint('👤 Detected ${faces.length} face(s)');
      }

      // ✅ Mode Switching Logic (Hysteresis)
      if (faces.isEmpty) {
        _consecutiveNoFaceFrames++;
        if (_consecutiveNoFaceFrames >= 5 && !_isIdleMode) {
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

      // ⚡ SYNC COPY BYTES FOR CONCURRENT PROCESSING
      Uint8List? copiedBytes;
      if (currentFrameBytes != null && faces.isNotEmpty) {
        copiedBytes = Uint8List.fromList(currentFrameBytes);
      }

      _handleStreamFaces(
        faces,
        Size(image.height.toDouble(), image.width.toDouble()),
        copiedBytes,
        currentWidth,
        currentHeight,
        currentRotation,
      );
    } catch (e) {
      debugPrint('Error processing stream: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_cameraController == null) return null;

    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;

    // Determine rotation
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[_cameraController!.value.deviceOrientation] ?? 0;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // ✅ CRITICAL FIX: Convert to NV21 — the ONLY format reliably supported
    // by Google ML Kit on all Android devices.
    if (Platform.isAndroid) {
      try {
        // Validate planes before conversion
        if (image.planes.length < 3) {
          debugPrint('⚠️ Not enough planes for YUV420: ${image.planes.length}');
          return null;
        }

        if (image.planes[0].bytes.isEmpty ||
            image.planes[1].bytes.isEmpty ||
            image.planes[2].bytes.isEmpty) {
          debugPrint('⚠️ One or more planes are empty');
          return null;
        }

        final nv21Bytes = _yuv420ToNv21(image);
        return InputImage.fromBytes(
          bytes: nv21Bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: image.width,
          ),
        );
      } catch (e, stackTrace) {
        debugPrint('❌ NV21 conversion error: $e');
        debugPrint('Stack trace: $stackTrace');
        return null;
      }
    }

    // iOS fallback
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Converts a YUV420 CameraImage to NV21 byte array.
  /// NV21 layout: Y plane (width*height bytes) + interleaved V,U plane.
  /// Handles both planar (pixelStride=1) and semi-planar (pixelStride=2) formats.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Debug: Log plane information
    debugPrint(
      '🔍 NV21 conversion: width=$width, height=$height, planes=${image.planes.length}',
    );
    for (int i = 0; i < image.planes.length; i++) {
      debugPrint(
        '  Plane $i: bytes=${image.planes[i].bytes.length}, bytesPerRow=${image.planes[i].bytesPerRow}, bytesPerPixel=${image.planes[i].bytesPerPixel}',
      );
    }

    // Validate planes
    if (image.planes.length < 3) {
      throw Exception(
        'Expected 3 planes for YUV420, got ${image.planes.length}',
      );
    }

    // Copy Y plane
    final Uint8List yPlane = image.planes[0].bytes;
    final int yRowStride = image.planes[0].bytesPerRow;

    if (yPlane.length < ySize) {
      debugPrint(
        '⚠️ Y plane too small: ${yPlane.length} < $ySize, using available data',
      );
    }

    if (yRowStride == width) {
      final copyLength = yPlane.length < ySize ? yPlane.length : ySize;
      nv21.setRange(0, copyLength, yPlane);
    } else {
      for (int row = 0; row < height; row++) {
        final int srcOffset = row * yRowStride;
        final int dstOffset = row * width;
        // Guard against Y plane being shorter than expected
        final int available = yPlane.length - srcOffset;
        final int toCopy = available < width ? available : width;
        if (toCopy <= 0) break;
        nv21.setRange(dstOffset, dstOffset + toCopy, yPlane, srcOffset);
      }
    }

    // Handle UV planes
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    debugPrint('🔍 UV: uvRowStride=$uvRowStride, uvPixelStride=$uvPixelStride');

    int pos = ySize;
    final int uvRows = height ~/ 2;
    final int uvCols = width ~/ 2;

    for (int row = 0; row < uvRows; row++) {
      for (int col = 0; col < uvCols; col++) {
        final int uvIndex = row * uvRowStride + col * uvPixelStride;

        // Check bounds
        if (uvIndex >= 0 &&
            uvIndex < vPlane.length &&
            uvIndex < uPlane.length) {
          nv21[pos++] = vPlane[uvIndex]; // V first (NV21)
          if (pos < nv21.length) {
            nv21[pos++] = uPlane[uvIndex]; // then U
          }
        } else {
          // Fill with neutral chroma (128) if out of bounds
          if (pos < nv21.length) nv21[pos++] = 128;
          if (pos < nv21.length) nv21[pos++] = 128;
        }
      }
    }

    return nv21;
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // ✅ REFACTORED: State Machine Core Logic + Centroid Tracker
  void _handleStreamFaces(
    List<Face> faces,
    Size imageSize,
    Uint8List? frameBytes,
    int width,
    int height,
    int rotation,
  ) {
    final now = DateTime.now();

    // 1. Centroid Tracking to Assign Persistent IDs
    final Map<int, Face> currentTrackedFaces = {};
    final Set<int> usedTrackerIds = {};

    for (final face in faces) {
      int? assignedId = face.trackingId;

      // If ML Kit doesn't provide trackingId, use Centroid Tracking
      if (assignedId == null) {
        final currentCentroid = face.boundingBox.center;
        double minDistance = double.infinity;
        int? closestId;

        _activeTrackers.forEach((id, prevCentroid) {
          if (!usedTrackerIds.contains(id)) {
            final distance = (currentCentroid - prevCentroid).distance;
            if (distance < minDistance && distance < _maxTrackingDistance) {
              minDistance = distance;
              closestId = id;
            }
          }
        });

        if (closestId != null) {
          assignedId = closestId;
        } else {
          assignedId = _nextTrackerId++;
        }
      }

      _activeTrackers[assignedId!] = face.boundingBox.center;
      usedTrackerIds.add(assignedId);
      currentTrackedFaces[assignedId] = face;
    }

    // Clean up stale trackers
    _activeTrackers.removeWhere((id, _) => !usedTrackerIds.contains(id));

    // 2. Clean up stale states
    _faceStates.removeWhere((id, _) => !usedTrackerIds.contains(id));
    _stabilityCounters.removeWhere((id, _) => !usedTrackerIds.contains(id));
    _lastFaceRects.removeWhere((id, _) => !usedTrackerIds.contains(id));

    // Check global cooldowns
    final activeCooldowns = Map<int, DateTime>.from(_cooldowns);
    activeCooldowns.forEach((id, time) {
      if (now.isAfter(time)) {
        _cooldowns.remove(id);
        _faceStates[id] = FaceTrackingState.idle;
      }
    });

    if (currentTrackedFaces.isEmpty) {
      if (mounted) setState(() => _detectedFaces = []);
      return;
    }

    final displayFaces = <Map<String, dynamic>>[];

    for (final entry in currentTrackedFaces.entries) {
      final id = entry.key;
      final face = entry.value;

      // Initialize state if new
      _faceStates.putIfAbsent(id, () => FaceTrackingState.idle);
      final currentState = _faceStates[id]!;

      // Early exit if in cooldown
      if (_cooldowns.containsKey(id)) {
        if (now.isBefore(_cooldowns[id]!)) {
          // Still in cooldown, just show box (gray)
          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.cooldown),
          );
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
          _triggerRecognition(
            face,
            id,
            imageSize,
            frameBytes,
            width,
            height,
            rotation,
          );
          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.locked),
          );
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
            _triggerRecognition(
              face,
              id,
              imageSize,
              frameBytes,
              width,
              height,
              rotation,
            );
          }

          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.tracking),
          );
          break;

        case FaceTrackingState.locked:
          // Waiting for inference to complete
          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.locked),
          );
          break;

        case FaceTrackingState.livenessCheck:
          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.livenessCheck),
          );
          break;

        case FaceTrackingState.cooldown:
          displayFaces.add(
            _buildFaceDisplayData(face, id, FaceTrackingState.cooldown),
          );
          break;
      }
    }

    // ✅ UI THROTTLE: Only update visual boxes every 150ms to keep camera smooth
    final nowUI = DateTime.now();
    if (mounted && nowUI.difference(_lastUIUpdate) >= _uiThrottle) {
      _lastUIUpdate = nowUI;
      setState(() {
        _detectedFaces = displayFaces;
      });
    }
  }

  Map<String, dynamic> _buildFaceDisplayData(
    Face face,
    int trackerId,
    FaceTrackingState state,
  ) {
    // Determine color/status based on state
    Color boxColor;
    String? statusText;

    switch (state) {
      case FaceTrackingState.idle:
      case FaceTrackingState.tracking:
        boxColor = Colors.yellow;
        statusText = null;
        break;
      case FaceTrackingState.locked:
        boxColor = Colors.blue;
        statusText = null;
        break;
      case FaceTrackingState.livenessCheck:
        boxColor = Colors.orange;
        statusText = AppLanguage.tr('attendance.face.checking');
        break;
      case FaceTrackingState.cooldown:
        final trackedData = _persistentFaceTracker[trackerId];
        if (trackedData != null) {
          final name = trackedData['name'] as String;
          final similarity = trackedData['similarity'] as double?;

          if (name == 'Unknown') {
            boxColor = Colors.red;
            statusText = AppLanguage.tr('attendance.face.unknown');
          } else if (name == 'Error') {
            boxColor = Colors.red.withValues(alpha: 0.5);
            statusText = AppLanguage.tr('attendance.face.error');
          } else {
            boxColor = Colors.green;
            // ✅ SHOW PERCENTAGE: "Name (85%)"
            if (similarity != null) {
              statusText = '$name (${similarity.toStringAsFixed(0)}%)';
            } else {
              statusText = name;
            }
          }
        } else {
          boxColor = Colors.grey;
          statusText = AppLanguage.tr('attendance.face.done');
        }
        break;
    }

    return {
      'rect': face.boundingBox,
      'color': boxColor,
      'name': statusText,
      'trackingId': trackerId,
    };
  }

  // ✅ REMOVED _captureMultiFrameEmbedding entirely.

  /* Behavioral Liveness Analysis Removed */

  Future<void> _triggerRecognition(
    Face face,
    int id,
    Size imageSize,
    Uint8List? frameBytes,
    int width,
    int height,
    int rotation,
  ) async {
    if (id == -1) return;

    try {
      final stopwatch = Stopwatch()..start();
      // ✅ Instant Single-Frame Inference
      debugPrint('🎯 [BENCH] Starting instantaneous recognition for face $id');

      if (frameBytes == null) {
        debugPrint('⚠️ No stream bytes available for recognition');
        _faceStates[id] = FaceTrackingState.idle; // Reset
        return;
      }

      // Capture single-frame embedding directly
      final captureStart = stopwatch.elapsedMilliseconds;
      final template = await _faceService.buildTemplateFromBytes(
        frameBytes,
        width,
        height,
        rotation,
        face,
        allowSidePose: false,
      );
      final captureEnd = stopwatch.elapsedMilliseconds;
      debugPrint(
        '🎬 [BENCH] Capture+Extraction took: ${captureEnd - captureStart}ms',
      );

      final frameCount = template['frame_count'] ?? 1;
      debugPrint('✅ Using $frameCount-frame averaged embedding for matching');

      final matchStart = stopwatch.elapsedMilliseconds;
      final result = template.containsKey('matched_user')
          ? template['matched_user'] as Map<String, dynamic>?
          : await _biometricService.identifyBestMatchWithUserInfo(
              capturedTemplate: template,
              organizationId: widget.organizationId,
              strict: true,
              threshold:
                  0.55, // ✅ INCREASED: More strict threshold to prevent false matches (was 0.45)
            );
      final matchEnd = stopwatch.elapsedMilliseconds;
      debugPrint(
        '🔍 [BENCH] Matching against database took: ${matchEnd - matchStart}ms',
      );

      if (result == null) {
        debugPrint(
          '⚠️ No match found for face $id (similarity below threshold)',
        );
      }
      debugPrint(
        '🚀 [BENCH] TOTAL Recognition Cycle: ${stopwatch.elapsedMilliseconds}ms',
      );

      if (result != null) {
        // ✅ INSTANT FEEDBACK: Sound + UI First
        if (mounted) {
          SoundHelper.playSuccessSound();
        }

        final now = DateTime.now();
        final matchedName = result['user_name'] as String? ?? 'Unknown';
        final matchedSim = (result['similarity'] as num?)?.toDouble() ?? 0.0;
        final matchedBiometricId = result['biometric_id'] as int?;
        final organizationMemberId = result['organization_member_id'] as int?;

        debugPrint(
          '✅ Valid match found: $matchedName (Mem: $organizationMemberId, Bio: $matchedBiometricId) with sim: ${matchedSim.toStringAsFixed(3)}',
        );

        _persistentFaceTracker[id] = {
          'name': matchedName,
          'member_id': organizationMemberId,
          'id': matchedBiometricId,
          'similarity': matchedSim * 100,
          'timestamp': now,
        };

        // ✅ SUCCESS: Cooldown to prevent spam
        _cooldowns[id] = now.add(_recognitionCooldown);

        _handleAttendance(result, template); // Fire and forget

        // ✅ NEW: Adaptive Learning (Evolution-Only on High Confidence)
        if (matchedBiometricId != null && matchedSim >= 0.55) {
          // 0.55 Raw Cosine is Very High
          final originalTemplate = _biometricService.getParsedTemplateFromCache(
            matchedBiometricId,
          );
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
      _persistentFaceTracker[id] = {'name': 'Error', 'member_id': null};
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
    Map<String, dynamic> template,
  ) async {
    // Process directly without queue - run async in background
    try {
      final user = result; // result IS the user map from biometric service
      final memberId = user['organization_member_id'] as int;
      final userName = user['user_name'] ?? 'Unknown';
      final biometricId = user['biometric_id'] as int;
      final profilePhotoUrl = user['profile_photo_url'] as String?;

      final attendanceType = _attendanceMode;

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
          debugPrint(
            '⏳ USER $userName: Same-mode cooldown active. Wait ${remainingMinutes}m ${remainingSeconds}s',
          );
          return;
        }
      }

      // 🔒 IMMEDIATE LOCK (Before DB Check or any Await)
      _lastAttendanceTime[cooldownKey] = DateTime.now();
      debugPrint(
        '🔒 LOCKED Cooldown for $userName ($attendanceType) immediately.',
      );

      String typeName;
      switch (attendanceType) {
        case 'check_in':
          typeName = "MASUK";
          break;
        case 'check_out':
          typeName = "KELUAR";
          break;
        case 'break_out':
          typeName = "ISTIRAHAT KELUAR";
          break;
        case 'break_in':
          typeName = "ISTIRAHAT MASUK";
          break;
        default:
          typeName = attendanceType.toUpperCase();
      }

      _showMessage(
        'Sukses: $userName ($typeName)',
        MessageType.success,
        seconds: 2,
      );

      if (mounted) {
        setState(() {
          _totalProcessedToday++;
          final now = DateTime.now();
          final timeStr =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

          _recentAttendanceList.insert(0, {
            'name': userName,
            'department': user['department_name'], // ✅ Removed fallback to '-'
            'photo_base64': null,
            'time': timeStr,
            'type': attendanceType,
            'timestamp': now,
          });
          if (_recentAttendanceList.length > 10) {
            _recentAttendanceList.removeLast();
          }
        });
      }

      // 📥 BACKGROUND TASKS: Non-blocking (Duplicate check & Database Save)
      _processBackgroundAttendance(
        user,
        template,
        attendanceType,
        memberId,
        userName,
        biometricId,
        profilePhotoUrl,
      );
    } catch (e) {
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
      final profilePhotoBase64 = await _getProfilePhotoBase64(
        memberId,
        profilePhotoUrl,
      ).timeout(const Duration(seconds: 3), onTimeout: () => null);

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

      // 2. Duplicate Check & Database Save
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(
        _organizationTimezone,
      );
      final alreadyRecorded = await _offlineDb.hasDuplicateAttendance(
        organizationMemberId: memberId,
        eventType: attendanceType,
        attendanceDate: todayStr,
      );

      if (alreadyRecorded) {
        debugPrint(
          '⏭️ Background: $userName already recorded, skipping DB write',
        );
        return;
      }

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
        debugPrint(
          '💾 Saved attendance record for $userName ($attendanceType) to offline DB',
        );
        if (_isOnline) {
          AttendanceSyncService().syncPendingAttendances();
        }
      }
    } catch (e) {
      debugPrint('❌ Background processing failed for $userName: $e');
    }
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

      if (schedule != null && mounted) {
        setState(() {
          _memberSchedule = schedule;
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading member schedule: $e');
      // No explicit fallback here because getTodaySchedule in _loadDailySchedule
      // already handles the complex daily fallback logic.
    }
  }

  // ✅ NEW: Load the full DailySchedule (with break times) for validation
  Future<void> _loadDailySchedule(int memberId) async {
    try {
      final schedule = await _attendanceService.getTodaySchedule(
        memberId,
        organizationTimezone: _organizationTimezone,
      );
      if (mounted) {
        setState(() => _dailySchedule = schedule);
      }
    } catch (e) {
      debugPrint('Error loading daily schedule: $e');
    }
  }

  /// Returns a record with (breakOutEnabled, breakInEnabled, hint string)
  ({bool canBreakOut, bool canBreakIn, String? hint})
  _computeBreakButtonState() {
    final schedule = _dailySchedule;
    if (schedule == null) {
      // No schedule info loaded: disable buttons (fail closed)
      return (canBreakOut: false, canBreakIn: false, hint: 'Memuat jadwal...');
    }

    final breakStartStr = schedule.breakStart;
    final breakEndStr = schedule.breakEnd;

    if (breakStartStr == null || breakEndStr == null) {
      // No break scheduled = disable both buttons
      return (
        canBreakOut: false,
        canBreakIn: false,
        hint: 'Tidak ada jadwal istirahat',
      );
    }

    // Parse break times
    TimeOfDay? parseTime(String s) {
      try {
        final parts = s.split(':');
        return TimeOfDay(
          hour: int.parse(parts[0]),
          minute: int.parse(parts[1]),
        );
      } catch (_) {
        return null;
      }
    }

    final breakStart = parseTime(breakStartStr);
    final breakEnd = parseTime(breakEndStr);
    if (breakStart == null || breakEnd == null) {
      return (canBreakOut: true, canBreakIn: true, hint: null);
    }

    // Use Organization Timezone for current time comparison
    final now = TimezoneHelper.convertUtcToOrgTimezone(
      DateTime.now().toUtc(),
      _organizationTimezone,
    );
    final nowMin = now.hour * 60 + now.minute;
    final bStartMin = breakStart.hour * 60 + breakStart.minute;
    final bEndMin = breakEnd.hour * 60 + breakEnd.minute;

    // Allow both "Mulai" and "Selesai" if within the schedule window
    // [breakStart - 30m, breakEnd + 30m]
    const windowMinutes = 30;
    final canBreakOut =
        nowMin >= (bStartMin - windowMinutes) &&
        nowMin <= (bEndMin + windowMinutes);
    final canBreakIn =
        nowMin >= (bStartMin - windowMinutes) &&
        nowMin <= (bEndMin + windowMinutes);

    String formatTime(TimeOfDay t) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }

    String? hint;
    if (!canBreakOut) {
      hint =
          'Istirahat tersedia pukul ${formatTime(breakStart)} - ${formatTime(breakEnd)}';
    }

    return (canBreakOut: canBreakOut, canBreakIn: canBreakIn, hint: hint);
  }

  // Reverting to dynamic shift selector based on User Request
  Future<void> _loadAvailableModes() async {
    if (_isLoadingModes) return;
    final orgId = widget.organizationId;

    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time, description')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('name', ascending: true);

      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(modes);
        });

        // Cache shifts for offline use
        await _offlineDb.cacheShifts(orgId, _availableModes);
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading modes result: $e');

      // Fallback to cache
      final cachedShifts = await _offlineDb.getShifts(orgId);
      if (mounted) {
        setState(() {
          _availableModes = List<Map<String, dynamic>>.from(cachedShifts);
        });
        if (_availableModes.isNotEmpty) {
          debugPrint(
            '💾 Using cached shifts (${_availableModes.length} found)',
          );
        }
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
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_availableModes.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Shift tidak tersedia',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _availableModes.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final mode = _availableModes[index];
                          final start = mode['start_time'] as String?;
                          final end = mode['end_time'] as String?;
                          final isSelected = _selectedMode?['id'] == mode['id'];

                          return ListTile(
                            title: Text(
                              mode['name'] ?? '-',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: start != null && end != null
                                ? Text('$start - $end')
                                : null,
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
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
        _workTimeMode =
            selected['code'] as String? ?? selected['name'] as String?;
      });
      await _showInOutSelector();
    }
  }

  void _autoSelectCurrentShift() {
    if (_availableModes.isEmpty) return;

    final nowDateTime = DateTime.now();
    final currentTime = TimeOfDay.fromDateTime(nowDateTime);

    Map<String, dynamic>? bestMatch;

    // 0. Priority: pre-select user's personally assigned shift from member schedule
    final memberShiftId = _memberSchedule?['shift_id'] as int?;
    if (memberShiftId != null) {
      for (final mode in _availableModes) {
        if (mode['id'] == memberShiftId) {
          bestMatch = mode;
          break;
        }
      }
    }

    // 0b. Priority: Match by work schedule hours for today
    if (bestMatch == null && _dailySchedule != null) {
      final startTime = _dailySchedule!.startTime;
      final endTime = _dailySchedule!.endTime;
      if (startTime != null && endTime != null) {
        for (var mode in _availableModes) {
          // Normalize time string (remove seconds if present)
          String norm(String t) => t.split(':').take(2).join(':');
          if (norm(mode['start_time'] ?? '') == norm(startTime) &&
              norm(mode['end_time'] ?? '') == norm(endTime)) {
            bestMatch = mode;
            break;
          }
        }
      }
    }

    // 1. Fallback: find a shift that matches the current time range
    if (bestMatch == null) {
      for (final mode in _availableModes) {
        final startStr = mode['start_time'] as String?;
        final endStr = mode['end_time'] as String?;

        if (startStr != null && endStr != null) {
          if (_isTimeInRange(currentTime, startStr, endStr)) {
            bestMatch = mode;
            break;
          }
        }
      }
    }

    if (bestMatch != null) {
      setState(() {
        _selectedMode = bestMatch;
        _workTimeMode =
            bestMatch!['code'] as String? ?? bestMatch['name'] as String?;
      });
    }
  }

  bool _isTimeInRange(TimeOfDay current, String startStr, String endStr) {
    try {
      final startParts = startStr.split(':');
      final endParts = endStr.split(':');

      final start = TimeOfDay(
        hour: int.parse(startParts[0]),
        minute: int.parse(startParts[1]),
      );
      final end = TimeOfDay(
        hour: int.parse(endParts[0]),
        minute: int.parse(endParts[1]),
      );

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
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    final state = _computeBreakButtonState();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: state.canBreakOut
                                      ? Colors.orange
                                      : Colors.grey.shade400,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: state.canBreakOut
                                    ? () =>
                                          Navigator.pop(context, 'break_start')
                                    : null,
                                child: Text(
                                  AppLanguage.tr('attendance.face.break_in'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: state.canBreakIn
                                      ? Colors.blue
                                      : Colors.grey.shade400,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: state.canBreakIn
                                    ? () => Navigator.pop(context, 'break_end')
                                    : null,
                                child: Text(
                                  AppLanguage.tr('attendance.face.break_out'),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (state.hint != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              state.hint!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );

    if (pickedMode != null && mounted) {
      setState(() => _attendanceMode = pickedMode);
      final modeName = _selectedMode != null
          ? _selectedMode!['name']
          : 'Standar';

      String typeName;
      switch (pickedMode) {
        case 'check_in':
          typeName = 'MASUK';
          break;
        case 'check_out':
          typeName = 'KELUAR';
          break;
        case 'break_start':
          typeName = 'ISTIRAHAT MASUK';
          break;
        case 'break_end':
          typeName = 'ISTIRAHAT KELUAR';
          break;
        default:
          typeName = pickedMode.toUpperCase();
      }

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
                Text(AppLanguage.tr('attendance.face.exit_title')),
              ],
            ),
            content: Text(AppLanguage.tr('attendance.face.exit_content')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(AppLanguage.tr('attendance.face.cancel')),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: Text(AppLanguage.tr('attendance.face.exit')),
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

            // ✅ SYNC: Using a single CustomPainter for all faces to eliminate lag (matching wajah project)
            if (_cameraController != null)
              Positioned.fill(
                child: CustomPaint(
                  painter: FaceDetectorPainter(
                    absoluteImageSize: Size(
                      _cameraController!.value.previewSize!.height,
                      _cameraController!.value.previewSize!.width,
                    ),
                    faces: _detectedFaces,
                    isFrontCamera:
                        true, // Multi-user attendance is usually front camera
                  ),
                ),
              ),

            // Debug overlay to show status
            Positioned(
              bottom: 100,
              left: 16,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Camera: ${_isCameraInitialized ? "✅" : "❌"}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      'Streaming: ${_isStreaming ? "✅" : "❌"}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      'Faces: ${_detectedFaces.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      'Idle: ${_isIdleMode ? "✅" : "❌"}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),

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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E26).withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.people_alt_outlined,
                          color: Color(0xFF9B59B6),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              AppLanguage.tr('attendance.face.session_count'),
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '$_totalProcessedToday',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
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
                              memberData: {
                                'organization_id': widget.organizationId,
                              },
                              sourceMode: 'face_recognition_kiosk',
                              initialShiftName: _workTimeMode,
                            ),
                          ),
                        );
                        if (success == true) {
                          // Refresh data if needed or show message
                          _showMessage(
                            AppLanguage.tr('attendance.face.manual_success'),
                            MessageType.success,
                          );
                        }
                      } else {
                        _showMessage(
                          AppLanguage.tr('attendance.face.manual_error'),
                          MessageType.error,
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  // Refresh Button
                  _buildCircularActionButton(
                    icon: _isRefreshing
                        ? Icons.hourglass_empty
                        : Icons.refresh_rounded,
                    onTap: _isRefreshing ? () {} : _refreshTemplates,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
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
                          Icon(
                            _getMessageIcon(),
                            color: Colors.white,
                            size: 16,
                          ),
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
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                AppLanguage.tr(
                                  'attendance.face.attendance_data',
                                ),
                                style: const TextStyle(
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
                                        AppLanguage.tr(
                                          'attendance.face.no_data',
                                        ),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        AppLanguage.tr(
                                          'attendance.face.start_instruction',
                                        ),
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
                                  final photoBase64 =
                                      item['photo_base64'] as String?;
                                  final photoUrl = item['photo_url'] as String?;
                                  ImageProvider? avatar;
                                  if (photoBase64 != null &&
                                      photoBase64.isNotEmpty) {
                                    avatar = MemoryImage(
                                      base64Decode(photoBase64),
                                    );
                                  } else if (photoUrl != null &&
                                      photoUrl.isNotEmpty) {
                                    avatar = NetworkImage(photoUrl);
                                  }

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(40),
                                      border: Border.all(
                                        color: const Color(0xFFE8DAEF),
                                        width: 1.2,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        // Compact Avatar with Ring
                                        Container(
                                          padding: const EdgeInsets.all(1.5),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: const Color(
                                                0xFF8E44AD,
                                              ).withValues(alpha: 0.15),
                                            ),
                                          ),
                                          child: CircleAvatar(
                                            radius: 18,
                                            backgroundColor:
                                                Colors.grey.shade100,
                                            backgroundImage: avatar,
                                            child: avatar == null
                                                ? const Icon(
                                                    Icons.person,
                                                    color: Colors.grey,
                                                    size: 18,
                                                  )
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
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
                                                '${item['department'] != null ? "${item['department']} • " : ""}${item['type'] == 'check_in' ? AppLanguage.tr('attendance.face.masuk') : AppLanguage.tr('attendance.face.keluar')} • ${item['time']}',
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

            // System Setup Overlay (Blocking)
            if (!_isSystemReady) _buildSetupOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupOverlay() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode ? const Color(0xFF121212) : Colors.white,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo / Icon
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF8938DF).withValues(alpha: 0.1),
              ),
              child: const Icon(
                Icons.face_retouching_natural_rounded,
                size: 64,
                color: Color(0xFF8938DF),
              ),
            ),
            const SizedBox(height: 32),

            // Progress Text
            Text(
              'System Setup',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: isDarkMode ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _initStatus,
              style: TextStyle(
                fontSize: 14,
                color: isDarkMode ? Colors.white70 : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 48),

            // Progress Indicator
            SizedBox(
              width: 200,
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _initProgress,
                    backgroundColor: isDarkMode
                        ? Colors.white10
                        : Colors.grey.shade200,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF8938DF),
                    ),
                    minHeight: 8,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${(_initProgress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF8938DF),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircularActionButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    _openModePicker();
  }
}
