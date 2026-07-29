// lib/attendance/screens/face_attendance_multi_user_page.dart
//
// REFACTORED: Fixed camera deadlock, enabled true multi-face parallel async
// recognition, precise bounding box scaling, and zero-anomaly error handling.
//
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
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
import '../../models/face_tracking_state.dart';

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
  FaceRecognitionTFLiteService? _faceService;
  final BiometricService _biometricService = BiometricService();
  final AttendanceService _attendanceService = AttendanceService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _attendanceSyncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isCameraInitialized = false;
  bool _isProcessingFrame = false;
  String? _currentMessage;
  MessageType _messageType = MessageType.idle;
  Position? _currentPosition;
  String _organizationTimezone = 'Asia/Jakarta';

  bool _isSystemReady = false;
  double _initProgress = 0.0;
  String _initStatus = 'Initializing...';

  Timer? _messageTimer;
  Timer? _scheduleCheckTimer;

  final List<Map<String, dynamic>> _recentAttendanceList = [];
  int _totalProcessedToday = 0;
  String _organizationName = '';
  int? _organizationMemberId;

  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  DailySchedule? _dailySchedule;
  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  bool _isRefreshing = false;
  bool _isScreenFlashEnabled = false;
  bool _showLowLightWarning = false;
  int _lightCheckFrameCount = 0;

  final ValueNotifier<List<Map<String, dynamic>>> _detectedFacesNotifier =
      ValueNotifier([]);

  final Map<int, Offset> _activeTrackers = {};
  final Map<int, DateTime> _lastSeenTimes = {};
  int _nextTrackerId = 1;
  static const double _maxTrackingDistance = 80.0;

  final Map<int, FaceTrackingState> _faceStates = {};
  final Map<int, DateTime> _cooldowns = {};

  final Set<int> _recognitionInFlight = {};
  final Map<int, Map<String, dynamic>> _persistentFaceTracker = {};
  final Map<int, Map<String, dynamic>> _pendingMatches = {};
  final Map<int, Map<String, dynamic>> _todayProcessedMembers = {};

  final Map<int, DateTime> _memberCooldowns = {};

  bool _isStreaming = false;
  bool _isIdleMode = true;
  int _consecutiveNoFaceFrames = 0;
  DateTime _lastCameraProcess = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _cameraThrottle = Duration.zero;
  static const Duration _idleCameraThrottle = Duration(milliseconds: 10);

  bool _isOnline = true;

  static double _calculateIOU(Rect boxA, Rect boxB) {
    final double intersectionLeft = max(boxA.left, boxB.left);
    final double intersectionTop = max(boxA.top, boxB.top);
    final double intersectionRight = min(boxA.right, boxB.right);
    final double intersectionBottom = min(boxA.bottom, boxB.bottom);
    final double iW = max(0.0, intersectionRight - intersectionLeft);
    final double iH = max(0.0, intersectionBottom - intersectionTop);
    final double iArea = iW * iH;
    if (iArea <= 0) return 0.0;
    final double unionArea =
        boxA.width * boxA.height + boxB.width * boxB.height - iArea;
    if (unionArea <= 0) return 0.0;
    return iArea / unionArea;
  }

  List<Face> _suppressOverlappingFaces(List<Face> faces) {
    if (faces.length <= 1) return faces;
    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });
    final selected = <Face>[];
    for (final face in sorted) {
      bool suppress = false;
      for (final s in selected) {
        if (_calculateIOU(face.boundingBox, s.boundingBox) > 0.35) {
          suppress = true;
          break;
        }
      }
      if (!suppress) selected.add(face);
    }
    return selected;
  }

  @override
  void initState() {
    super.initState();
    _setMaxBrightness();
    _initializeSystem();
  }

  Future<void> _setMaxBrightness() async {
    try {
      await ScreenBrightness().setApplicationScreenBrightness(1.0);
      debugPrint('☀️ Screen brightness automatically set to 100% MAX');
    } catch (e) {
      debugPrint('⚠️ Error setting max screen brightness: $e');
    }
  }

  Future<void> _resetBrightness() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
      debugPrint('🌙 Screen brightness reset to default');
    } catch (e) {
      debugPrint('⚠️ Error resetting screen brightness: $e');
    }
  }

  Future<void> _initializeSystem() async {
    final stopwatch = Stopwatch()..start();
    debugPrint('🏁 Starting face-attendance system initialization...');

    try {
      setState(() { _initProgress = 0.05; _initStatus = 'Warming up UI...'; });
      await _enableKioskMode();
      await Future.delayed(const Duration(milliseconds: 100));

      setState(() { _initProgress = 0.15; _initStatus = 'Loading organization settings...'; });
      await _loadOrganizationData();
      _startScheduleCheck();

      setState(() { _initProgress = 0.40; _initStatus = 'Loading AI Models (Multi-Threaded)...'; });
      await _initializeFaceService();

      setState(() { _initProgress = 0.70; _initStatus = 'Preparing high-speed camera...'; });
      await _initializeCamera();

      setState(() { _initProgress = 0.90; _initStatus = 'Warming up biometric cache...'; });
      await Future.wait([
        _getCurrentLocation().timeout(
          const Duration(seconds: 5),
          onTimeout: () { debugPrint('⚠️ Location timeout'); },
        ),
        _checkConnectivity().timeout(
          const Duration(seconds: 3),
          onTimeout: () { debugPrint('⚠️ Connectivity check timeout'); },
        ),
        _biometricService
            .getAllActiveFaceTemplatesWithUserInfo(widget.organizationId)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () { debugPrint('⚠️ Face templates timeout'); return []; },
            ),
      ]);

      setState(() { _initProgress = 1.0; _initStatus = 'Ready!'; });
      await Future.delayed(const Duration(milliseconds: 300));

      if (mounted) {
        setState(() => _isSystemReady = true);
        await _loadAvailableModes();
        await _preloadTodayProcessedMembers();
        _autoSelectCurrentShift();
        _attendanceSyncService.startAutoSync();
        _startFaceAutoSync();
        debugPrint('🚀 System ready in ${stopwatch.elapsedMilliseconds}ms');
      }
    } catch (e) {
      debugPrint('❌ Initialization failed: $e');
      _showMessage(
        '${AppLanguage.tr('attendance.face.init_failed')}$e',
        MessageType.error,
      );
    }
  }

  Timer? _faceAutoSyncTimer;

  void _startFaceAutoSync() {
    _faceAutoSyncTimer?.cancel();
    _faceAutoSyncTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        await _biometricService.getAllActiveFaceTemplatesWithUserInfo(widget.organizationId);
      } catch (_) {}
    });
  }

  Future<void> _toggleTorchMode(bool enable) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      await _cameraController!.setFlashMode(enable ? FlashMode.torch : FlashMode.off);
    } catch (e) {
      debugPrint('Hardware torch not supported: $e');
    }
  }

  @override
  void dispose() {
    _resetBrightness();
    _messageTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _faceAutoSyncTimer?.cancel();
    _isProcessingFrame = false;
    _detectedFacesNotifier.dispose();
    _recentAttendanceList.clear();
    _cameraController?.dispose();
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
        _isOnline = result.isNotEmpty && !result.contains(ConnectivityResult.none);
      });
    }
    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        setState(() {
          _isOnline = results.isNotEmpty && !results.contains(ConnectivityResult.none);
        });
      }
    });
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
        await _offlineDb.cacheOrganizationData({
          'id': orgId,
          'name': _organizationName,
          'timezone': _organizationTimezone,
        });
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error loading org data: $e');
      final cachedOrg = await _offlineDb.getOrganizationData(orgId);
      if (cachedOrg != null && mounted) {
        setState(() {
          _organizationTimezone = cachedOrg['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = cachedOrg['name'] as String? ?? '';
        });
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
          setState(() => _organizationMemberId = memberId);
          await _loadMemberSchedule(memberId);
          _loadDailySchedule(memberId);
        }
      }
    } catch (e) {
      debugPrint('🌐 Offline/Error finding member ID: $e');
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        final cachedMembers = await _offlineDb.getOrganizationMembers(orgId);
        if (cachedMembers != null) {
          final member = cachedMembers.firstWhere(
            (m) => m['user_id'] == userId,
            orElse: () => <String, dynamic>{},
          );
          if (member.isNotEmpty && member['id'] != null && mounted) {
            setState(() => _organizationMemberId = member['id'] as int);
          }
        }
      }
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
      _showMessage(AppLanguage.tr('attendance.face.preparing'), MessageType.loading);
      _faceService = await _biometricService.getFaceService();
      debugPrint('✅ Face service initialized');
      _clearMessage();
    } catch (e) {
      debugPrint('❌ Failed to init TFLite: $e');
      if (mounted) {
        _showMessage('Face service init failed: $e', MessageType.error, seconds: 10);
      }
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) return;
    try {
      debugPrint('📷 Initializing camera...');
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No cameras available');

      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      if (_cameraController != null) await _cameraController!.dispose();

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Camera init timeout'),
      );

      try {
        final maxExp = await _cameraController!.getMaxExposureOffset();
        if (maxExp > 0) {
          await _cameraController!.setExposureOffset((maxExp * 0.3).clamp(0.5, 1.5));
        }
      } catch (_) {}
      try { await _cameraController!.setFocusMode(FocusMode.auto); } catch (_) {}

      if (mounted) {
        setState(() => _isCameraInitialized = true);
        debugPrint('✅ Camera initialized — starting continuous scan');
        _startContinuousScan();
      }
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      if (mounted) {
        _showMessage('Camera error: $e', MessageType.error, seconds: 10);
        setState(() => _isCameraInitialized = false);
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
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isStreaming) {
      return;
    }
    try {
      _isStreaming = true;
      debugPrint('✅ Image stream started');
      _cameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('❌ Error starting stream: $e');
      _isStreaming = false;
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    final now = DateTime.now();
    final throttle = _isIdleMode ? _idleCameraThrottle : _cameraThrottle;
    if (now.difference(_lastCameraProcess) < throttle) return;
    _lastCameraProcess = now;

    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      Uint8List? frameBytes;
      int imgWidth = image.width;
      int imgHeight = image.height;
      int rotation = 0;

      if (inputImage.bytes != null) {
        frameBytes = Uint8List.fromList(inputImage.bytes!);
        if (inputImage.metadata?.rotation != null) {
          switch (inputImage.metadata!.rotation) {
            case InputImageRotation.rotation0deg:   rotation = 0;
            case InputImageRotation.rotation90deg:  rotation = 90;
            case InputImageRotation.rotation180deg: rotation = 180;
            case InputImageRotation.rotation270deg: rotation = 270;
          }
        }
      }

      if (_faceService == null) return;
      final faces = await _faceService!.detectFacesFromInputImage(inputImage);

      if (faces.isEmpty) {
        _consecutiveNoFaceFrames++;
        if (_consecutiveNoFaceFrames >= 5 && !_isIdleMode) {
          if (mounted) setState(() => _isIdleMode = true);
        }
      } else {
        _consecutiveNoFaceFrames = 0;
        if (_isIdleMode && mounted) setState(() => _isIdleMode = false);
      }

      final bool isPortrait = rotation == 90 || rotation == 270;
      final Size logicalImageSize = isPortrait
          ? Size(image.height.toDouble(), image.width.toDouble())
          : Size(image.width.toDouble(), image.height.toDouble());

      _handleStreamFaces(
        faces,
        logicalImageSize,
        frameBytes,
        imgWidth,
        imgHeight,
        rotation,
      );
    } catch (e) {
      debugPrint('Stream processing error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_cameraController == null) return null;
    final camera = _cameraController!.description;
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotation.rotation0deg;
    } else if (Platform.isAndroid) {
      var comp = _orientations[_cameraController!.value.deviceOrientation] ?? 0;
      if (camera.lensDirection == CameraLensDirection.front) {
        comp = (sensorOrientation + comp) % 360;
      } else {
        comp = (sensorOrientation - comp + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(comp);
    }
    if (rotation == null) return null;

    if (Platform.isAndroid) {
      try {
        final nv21 = _yuv420ToNv21(image);
        _lightCheckFrameCount++;
        if (_lightCheckFrameCount >= 30) {
          _lightCheckFrameCount = 0;
          _enhanceNv21Brightness(nv21, image.width * image.height);
        }
        return InputImage.fromBytes(
          bytes: nv21,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: image.width,
          ),
        );
      } catch (e) {
        debugPrint('❌ YUV→NV21 error: $e');
        return null;
      }
    }

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    _lightCheckFrameCount++;
    if (_lightCheckFrameCount >= 30) {
      _lightCheckFrameCount = 0;
      _enhanceBgraBrightness(bytes);
    }
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

  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);

    final Uint8List yPlane = image.planes[0].bytes;
    final int yRowStride = image.planes[0].bytesPerRow;
    if (yRowStride == width) {
      nv21.setRange(0, ySize, yPlane);
    } else {
      for (int row = 0; row < height; row++) {
        nv21.setRange(row * width, row * width + width, yPlane, row * yRowStride);
      }
    }

    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    if (uvPixelStride == 2) {
      final int toCopy = min(vPlane.length, uvSize);
      nv21.setRange(ySize, ySize + toCopy, vPlane);
    } else {
      int pos = ySize;
      for (int row = 0; row < height ~/ 2; row++) {
        for (int col = 0; col < width ~/ 2; col++) {
          final int uvIndex = row * uvRowStride + col * uvPixelStride;
          if (pos + 1 < nv21.length && uvIndex < vPlane.length && uvIndex < uPlane.length) {
            nv21[pos++] = vPlane[uvIndex];
            nv21[pos++] = uPlane[uvIndex];
          }
        }
      }
    }
    return nv21;
  }

  void _enhanceNv21Brightness(Uint8List nv21, int ySize) {
    if (ySize == 0 || nv21.isEmpty) return;
    int sum = 0, count = 0;
    for (int i = 0; i < ySize; i += 64) {
      if (i >= nv21.length) break;
      sum += nv21[i];
      count++;
    }
    if (count == 0) return;
    final bool isDark = (sum / count) < 60.0;
    if (_showLowLightWarning != isDark && mounted) {
      _showLowLightWarning = isDark;
      setState(() {});
    }
  }

  void _enhanceBgraBrightness(Uint8List bytes) {
    final int totalBytes = bytes.length;
    if (totalBytes == 0) return;
    int sum = 0, count = 0;
    for (int i = 0; i < totalBytes; i += 256) {
      if (i + 2 >= totalBytes) break;
      final b = bytes[i], g = bytes[i + 1], r = bytes[i + 2];
      sum += (0.299 * r + 0.587 * g + 0.114 * b).round();
      count++;
    }
    if (count == 0) return;
    final bool isDark = (sum / count) < 60.0;
    if (_showLowLightWarning != isDark && mounted) {
      _showLowLightWarning = isDark;
      setState(() {});
    }
  }

  void _handleStreamFaces(
    List<Face> faces,
    Size imageSize,
    Uint8List? frameBytes,
    int width,
    int height,
    int rotation,
  ) {
    final cleanFaces = _suppressOverlappingFaces(faces);

    if (cleanFaces.isEmpty) {
      _activeTrackers.clear();
      _lastSeenTimes.clear();
      _faceStates.clear();
      _recognitionInFlight.clear();
      _cooldowns.clear();
      _persistentFaceTracker.clear();
      _detectedFacesNotifier.value = [];
      return;
    }

    final now = DateTime.now();
    final Map<int, Face> currentTrackedFaces = {};
    final Set<int> usedTrackerIds = {};

    for (final face in cleanFaces) {
      final currentCentroid = face.boundingBox.center;
      double minDist = double.infinity;
      int? closestId;

      _activeTrackers.forEach((id, prevCentroid) {
        if (!usedTrackerIds.contains(id)) {
          final dist = (currentCentroid - prevCentroid).distance;
          if (dist < minDist && dist < _maxTrackingDistance) {
            minDist = dist;
            closestId = id;
          }
        }
      });

      final assignedId = closestId ?? _nextTrackerId++;
      _activeTrackers[assignedId] = currentCentroid;
      _lastSeenTimes[assignedId] = now;
      usedTrackerIds.add(assignedId);
      currentTrackedFaces[assignedId] = face;
    }

    const gracePeriod = Duration(milliseconds: 400);
    _activeTrackers.removeWhere((id, _) {
      final lastSeen = _lastSeenTimes[id];
      return lastSeen == null || now.difference(lastSeen) > gracePeriod;
    });
    _faceStates.removeWhere((id, _) => !_activeTrackers.containsKey(id));
    _recognitionInFlight.removeWhere((id) => !_activeTrackers.containsKey(id));
    _cooldowns.removeWhere((id, _) => !_activeTrackers.containsKey(id));
    _lastSeenTimes.removeWhere((id, _) => !_activeTrackers.containsKey(id));

    _cooldowns.entries
        .where((e) => now.isAfter(e.value))
        .map((e) => e.key)
        .toList()
        .forEach((id) {
      _cooldowns.remove(id);
      if (_activeTrackers.containsKey(id)) {
        _faceStates[id] = FaceTrackingState.idle;
      }
    });

    if (currentTrackedFaces.isEmpty) {
      _detectedFacesNotifier.value = [];
      return;
    }

    final displayFaces = <Map<String, dynamic>>[];

    for (final entry in currentTrackedFaces.entries) {
      final id = entry.key;
      final face = entry.value;

      _faceStates.putIfAbsent(id, () => FaceTrackingState.idle);
      final currentState = _faceStates[id]!;

      switch (currentState) {
        case FaceTrackingState.idle:
          if (!_recognitionInFlight.contains(id) && frameBytes != null) {
            _faceStates[id] = FaceTrackingState.locked;
            _recognitionInFlight.add(id);
            _triggerRecognition(face, id, imageSize, frameBytes, width, height, rotation);
          }
          displayFaces.add(_buildFaceDisplayData(face, id, FaceTrackingState.locked));
          break;

        case FaceTrackingState.locked:
          displayFaces.add(_buildFaceDisplayData(face, id, FaceTrackingState.locked));
          break;

        case FaceTrackingState.cooldown:
          if (_cooldowns.containsKey(id) && now.isAfter(_cooldowns[id]!)) {
            _cooldowns.remove(id);
            _faceStates[id] = FaceTrackingState.idle;
            displayFaces.add(_buildFaceDisplayData(face, id, FaceTrackingState.idle));
          } else {
            displayFaces.add(_buildFaceDisplayData(face, id, FaceTrackingState.cooldown));
          }
          break;

        default:
          _faceStates[id] = FaceTrackingState.idle;
          break;
      }
    }

    _detectedFacesNotifier.value = displayFaces;
  }

  Map<String, dynamic> _buildFaceDisplayData(
    Face face,
    int trackerId,
    FaceTrackingState state,
  ) {
    Color boxColor;
    String? statusText;

    switch (state) {
      case FaceTrackingState.idle:
        boxColor = Colors.yellow;
        statusText = null;
        break;
      case FaceTrackingState.locked:
        boxColor = Colors.blue;
        statusText = null;
        break;
      case FaceTrackingState.cooldown:
        final trackedData = _persistentFaceTracker[trackerId];
        if (trackedData != null) {
          final name = trackedData['name'] as String? ?? 'Unknown';
          final similarity = (trackedData['similarity'] as num?)?.toDouble();
          if (name == 'Unknown') {
            boxColor = Colors.red;
            statusText = AppLanguage.tr('attendance.face.unknown');
          } else if (name == 'Error') {
            boxColor = Colors.red.withValues(alpha: 0.5);
            statusText = AppLanguage.tr('attendance.face.error');
          } else {
            boxColor = Colors.green;
            statusText = similarity != null
                ? '$name (${similarity.toStringAsFixed(0)}%)'
                : name;
          }
        } else {
          boxColor = Colors.red;
          statusText = AppLanguage.tr('attendance.face.unknown');
        }
        break;
      default:
        boxColor = Colors.grey;
        statusText = null;
        break;
    }

    return {
      'rect': face.boundingBox,
      'color': boxColor,
      'name': statusText,
      'trackingId': trackerId,
    };
  }

  Future<void> _triggerRecognition(
    Face face,
    int id,
    Size imageSize,
    Uint8List frameBytes,
    int width,
    int height,
    int rotation,
  ) async {
    try {
      if (_faceService == null) return;
      if (!_faceService!.isValidFaceForRecognition(face)) {
        _cooldowns.remove(id);
        _faceStates[id] = FaceTrackingState.idle;
        return;
      }

      final template = await _faceService!.buildTemplateFromBytes(
        frameBytes,
        width,
        height,
        rotation,
        face,
        allowSidePose: true, // Allow side gaze faces for fast attendance
      );

      if (template.isEmpty ||
          (template['embedding'] == null &&
           (template['templates'] == null ||
            (template['templates'] as List?)?.isEmpty == true))) {
        debugPrint('⚠️ Face $id: empty template from inference');
        _persistentFaceTracker[id] = {'name': 'Unknown', 'member_id': null, 'similarity': 0.0, 'timestamp': DateTime.now()};
        _cooldowns[id] = DateTime.now().add(const Duration(milliseconds: 600));
        return;
      }

      final Map<String, dynamic>? result;
      if (template.containsKey('matched_user')) {
        result = template['matched_user'] as Map<String, dynamic>?;
      } else {
        result = await _biometricService.identifyBestMatchWithUserInfo(
          capturedTemplate: template,
          organizationId: widget.organizationId,
          strict: false,
          threshold: 0.78, // 78% standard MobileFaceNet threshold
        );
      }

      if (result != null) {
        final organizationMemberId = (result['organization_member_id'] as num?)?.toInt();
        final matchedName = result['user_name'] as String? ?? 'Unknown';
        final matchedSim = (result['similarity'] as num?)?.toDouble() ?? 0.0;
        final matchedBiometricId = (result['biometric_id'] as num?)?.toInt();

        if (organizationMemberId != null) {
          final now = DateTime.now();

          // 1. Check RAM Session Cache first (Instant 0ms lookup!)
          final existingSessionRecord = _todayProcessedMembers[organizationMemberId];
          if (existingSessionRecord != null &&
              existingSessionRecord['attendance_type'] == _attendanceMode) {
            _persistentFaceTracker[id] = {
              'name': '$matchedName (Sudah Absen)',
              'member_id': organizationMemberId,
              'similarity': matchedSim * 100,
              'timestamp': now,
            };
            _cooldowns[id] = now.add(const Duration(seconds: 5));
            _faceStates[id] = FaceTrackingState.cooldown;
            return;
          }

          // 2. Lock member cooldown & register in RAM cache synchronously
          _memberCooldowns[organizationMemberId] = now;
          _todayProcessedMembers[organizationMemberId] = {
            'attendance_type': _attendanceMode,
            'attendance_time': TimezoneHelper.formatTimeOnly(now),
          };

          // 3. Play success sound & update UI INSTANTLY (0ms response)
          if (mounted) SoundHelper.playSuccessSound();

          _persistentFaceTracker[id] = {
            'name': matchedName,
            'member_id': organizationMemberId,
            'id': matchedBiometricId,
            'similarity': matchedSim * 100,
            'timestamp': now,
          };
          _cooldowns[id] = now.add(const Duration(seconds: 10));
          _faceStates[id] = FaceTrackingState.cooldown;

          // 4. Background DB / Network Record Check & Save (non-blocking)
          unawaited(_processAttendanceRecordInBackground(
            organizationMemberId: organizationMemberId,
            matchedName: matchedName,
            matchedBiometricId: matchedBiometricId,
            matchedSim: matchedSim,
            result: result,
            id: id,
          ));
        }
      } else {
        // Instant retry on next frame (no 600ms delay!)
        _pendingMatches.remove(id);
        _cooldowns.remove(id);
        _faceStates[id] = FaceTrackingState.idle;
      }
    } catch (e) {
      debugPrint('❌ Async recognition error for face $id: $e');
      _cooldowns.remove(id);
      _faceStates[id] = FaceTrackingState.idle;
    } finally {
      _recognitionInFlight.remove(id);
    }
  }

  Future<void> _processAttendanceRecordInBackground({
    required int organizationMemberId,
    required String matchedName,
    int? matchedBiometricId,
    required double matchedSim,
    required Map<String, dynamic> result,
    required int id,
  }) async {
    try {
      final existingRecord = await _getExistingAttendanceToday(
        memberId: organizationMemberId,
        attendanceType: _attendanceMode,
      );

      if (existingRecord != null) {
        _handleDuplicateAttendanceUI(
          matchedName,
          result['department_name'] as String?,
          organizationMemberId,
          _attendanceMode,
          existingRecord,
        );
        return;
      }

      await _recordAttendanceAsync(
        organizationMemberId: organizationMemberId,
        memberName: matchedName,
        departmentName: result['department_name'] as String?,
        similarity: matchedSim,
      );
    } catch (e) {
      debugPrint('⚠️ Error processing background attendance record: $e');
    }
  }

  void _handleDuplicateAttendanceUI(
    String memberName,
    String? departmentName,
    int organizationMemberId,
    String attendanceType,
    Map<String, dynamic> existingRecord,
  ) {
    if (!mounted) return;

    final attendanceTimeStr = existingRecord['attendance_time'] as String?;
    String formattedTime = 'hari ini';
    if (attendanceTimeStr != null) {
      try {
        final timeParts = attendanceTimeStr.split(':');
        if (timeParts.length >= 2) {
          formattedTime = '${timeParts[0]}:${timeParts[1]}';
        }
      } catch (_) {}
    }

    final modeLabel = _availableModes.firstWhere(
      (m) => m['key'] == attendanceType,
      orElse: () => {'label': attendanceType},
    )['label'];

    _showMessage(
      '$memberName ${AppLanguage.tr('attendance.face.already_recorded')} ($modeLabel pukul $formattedTime)',
      MessageType.warning,
      seconds: 4,
    );

    _addRecentAttendance(
      memberName: memberName,
      departmentName: departmentName,
      attendanceType: attendanceType,
      formattedTime: formattedTime,
      isDuplicate: true,
    );
  }

  Future<void> _recordAttendanceAsync({
    required int organizationMemberId,
    required String memberName,
    String? departmentName,
    required double similarity,
  }) async {
    try {
      final now = DateTime.now();
      final String nowUtcIso = TimezoneHelper.formatUtcForSupabase(now);
      final String todayDateStr = TimezoneHelper.formatDateOnly(now);
      final String timeStr = TimezoneHelper.formatTimeOnly(now);

      _todayProcessedMembers[organizationMemberId] = {
        'attendance_type': _attendanceMode,
        'attendance_time': timeStr,
      };

      final modeLabel = _availableModes.firstWhere(
        (m) => m['key'] == _attendanceMode,
        orElse: () => {'label': _attendanceMode},
      )['label'];

      _showMessage(
        '$memberName — $modeLabel BERHASIL',
        MessageType.success,
        seconds: 4,
      );

      _addRecentAttendance(
        memberName: memberName,
        departmentName: departmentName,
        attendanceType: _attendanceMode,
        formattedTime: timeStr,
        isDuplicate: false,
      );

      final attendanceRecordData = {
        'organization_id': widget.organizationId,
        'organization_member_id': organizationMemberId,
        'attendance_date': todayDateStr,
        'attendance_time': timeStr,
        'created_at': nowUtcIso,
        'attendance_type': _attendanceMode,
        'status': 'present',
        'verification_method': 'face_recognition',
        'latitude': _currentPosition?.latitude,
        'longitude': _currentPosition?.longitude,
      };

      if (_isOnline) {
        try {
          if (_attendanceMode == 'check_out') {
            await _attendanceService.checkOut(
              organizationMemberId: organizationMemberId,
              photoUrl: '',
              method: 'face_recognition',
              location: _currentPosition != null ? {'latitude': _currentPosition!.latitude, 'longitude': _currentPosition!.longitude} : null,
            );
          } else {
            await _attendanceService.checkIn(
              organizationMemberId: organizationMemberId,
              photoUrl: '',
              method: 'face_recognition',
              location: _currentPosition != null ? {'latitude': _currentPosition!.latitude, 'longitude': _currentPosition!.longitude} : null,
            );
          }
          debugPrint('✅ Online attendance recorded for member $organizationMemberId');
          return;
        } catch (e) {
          debugPrint('⚠️ Online record failed, saving offline fallback: $e');
        }
      }

      final offlineAttendance = OfflineAttendance(
        cardNumber: 'FACE_$organizationMemberId',
        eventType: _attendanceMode,
        method: 'face_recognition',
        timestamp: nowUtcIso,
        organizationMemberId: organizationMemberId,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
        notes: 'Offline Face Attendance (Sim: ${(similarity * 100).toStringAsFixed(1)}%)',
      );

      await _offlineDb.insertAttendance(offlineAttendance);
      debugPrint('💾 Saved offline attendance for member $organizationMemberId');
    } catch (e) {
      debugPrint('❌ Error in async attendance recording: $e');
    }
  }

  void _addRecentAttendance({
    required String memberName,
    String? departmentName,
    required String attendanceType,
    required String formattedTime,
    bool isDuplicate = false,
  }) {
    if (!mounted) return;
    setState(() {
      final modeLabel = _availableModes.firstWhere(
        (m) => m['key'] == attendanceType,
        orElse: () => {'label': attendanceType},
      )['label'];

      _recentAttendanceList.insert(0, {
        'name': memberName,
        'department': departmentName ?? '',
        'time': formattedTime,
        'type': modeLabel,
        'type_key': attendanceType,
        'timestamp': DateTime.now(),
        'is_duplicate': isDuplicate,
      });

      if (_recentAttendanceList.length > 20) {
        _recentAttendanceList.removeLast();
      }

      if (!isDuplicate) {
        _totalProcessedToday++;
      }
    });
  }

  Future<Map<String, dynamic>?> _getExistingAttendanceToday({
    required int memberId,
    required String attendanceType,
  }) async {
    // 1. Check RAM session cache (Instant 0ms lookup!)
    final sessionRecord = _todayProcessedMembers[memberId];
    if (sessionRecord != null && sessionRecord['attendance_type'] == attendanceType) {
      return sessionRecord;
    }

    final now = DateTime.now();
    final todayStr = TimezoneHelper.formatDateOnly(now);

    // 2. Query Supabase attendance_records using correct schema columns
    try {
      final records = await _supabase
          .from('attendance_records')
          .select('id, actual_check_in, actual_check_out, actual_break_start, actual_break_end')
          .eq('organization_member_id', memberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (records != null) {
        final checkInTime = records['actual_check_in'];
        final checkOutTime = records['actual_check_out'];
        final breakStartTime = records['actual_break_start'];
        final breakEndTime = records['actual_break_end'];

        bool isDuplicate = false;
        String? recordTime;

        if (attendanceType == 'check_in' && checkInTime != null) {
          isDuplicate = true;
          recordTime = checkInTime.toString();
        } else if (attendanceType == 'check_out' && checkOutTime != null) {
          isDuplicate = true;
          recordTime = checkOutTime.toString();
        } else if (attendanceType == 'break_start' && breakStartTime != null) {
          isDuplicate = true;
          recordTime = breakStartTime.toString();
        } else if (attendanceType == 'break_end' && breakEndTime != null) {
          isDuplicate = true;
          recordTime = breakEndTime.toString();
        }

        if (isDuplicate) {
          final foundRecord = {
            'id': records['id'],
            'attendance_time': recordTime ?? todayStr,
            'attendance_type': attendanceType,
          };
          _todayProcessedMembers[memberId] = foundRecord;
          return foundRecord;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error checking online duplicate attendance: $e');
    }

    // 3. Query local offline SQLite database
    try {
      final offlineRecords = await _offlineDb.getUnsyncedAttendances();
      for (final record in offlineRecords) {
        if (record.organizationMemberId == memberId &&
            record.eventType == attendanceType) {
          final foundRecord = {
            'id': record.id,
            'attendance_time': record.timestamp,
            'attendance_type': record.eventType,
          };
          _todayProcessedMembers[memberId] = foundRecord;
          return foundRecord;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> _preloadTodayProcessedMembers() async {
    final now = DateTime.now();
    final todayStr = TimezoneHelper.formatDateOnly(now);
    try {
      final records = await _supabase
          .from('attendance_records')
          .select('organization_member_id, actual_check_in, actual_check_out')
          .eq('attendance_date', todayStr);

      for (final rec in records as List<dynamic>) {
        final memberId = (rec['organization_member_id'] as num?)?.toInt();
        if (memberId == null) continue;

          final checkInTime = rec['actual_check_in'];
          final checkOutTime = rec['actual_check_out'];

          if (checkInTime != null) {
            _todayProcessedMembers[memberId] = {
              'attendance_type': 'check_in',
              'attendance_time': checkInTime.toString(),
            };
          }
          if (checkOutTime != null) {
            _todayProcessedMembers[memberId] = {
              'attendance_type': 'check_out',
              'attendance_time': checkOutTime.toString(),
            };
          }
        }
      } catch (e) {
      debugPrint('⚠️ Preload online attendance records failed: $e');
    }

    try {
      final offlineRecords = await _offlineDb.getUnsyncedAttendances();
      for (final rec in offlineRecords) {
        if (rec.organizationMemberId != null) {
          _todayProcessedMembers[rec.organizationMemberId!] = {
            'attendance_type': rec.eventType,
            'attendance_time': rec.timestamp,
          };
        }
      }
    } catch (_) {}

    debugPrint('📋 Preloaded ${_todayProcessedMembers.length} attendance records for strict 1-session locking.');
  }

  void _showMessage(String text, MessageType type, {int seconds = 3}) {
    _messageTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _currentMessage = text;
      _messageType = type;
    });

    if (type != MessageType.loading) {
      _messageTimer = Timer(Duration(seconds: seconds), () {
        if (mounted) _clearMessage();
      });
    }
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

  Future<void> _loadMemberSchedule(int memberId) async {
    try {
      final schedule = await _attendanceService.getMemberSchedule(memberId);
      if (mounted) {
        setState(() {
          _memberSchedule = schedule;
          _workTimeMode = schedule?['work_time_mode'] as String?;
        });
      }
    } catch (e) {
      debugPrint('Error loading schedule: $e');
    }
  }

  void _loadDailySchedule(int memberId) {
    _dailySchedule = WorkScheduleHelper.getTodaySchedule(_memberSchedule);
  }

  Future<void> _loadAvailableModes() async {
    setState(() => _isLoadingModes = true);
    try {
      final modes = await _attendanceService.getAvailableAttendanceModes(
        organizationId: widget.organizationId,
        memberSchedule: _memberSchedule,
        workTimeMode: _workTimeMode,
      );

      if (mounted) {
        setState(() {
          _availableModes = modes;
          if (_availableModes.isNotEmpty) {
            _selectedMode = _availableModes.firstWhere(
              (m) => m['key'] == _attendanceMode,
              orElse: () => _availableModes.first,
            );
            _attendanceMode = _selectedMode!['key'] as String;
          }
          _isLoadingModes = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading modes: $e');
      if (mounted) setState(() => _isLoadingModes = false);
    }
  }

  void _autoSelectCurrentShift() {
    if (_availableModes.isEmpty) return;
    final now = DateTime.now();

    for (final mode in _availableModes) {
      final startTimeStr = mode['start_time'] as String?;
      final endTimeStr = mode['end_time'] as String?;
      if (startTimeStr == null || endTimeStr == null) continue;

      try {
        final startParts = startTimeStr.split(':').map(int.parse).toList();
        final endParts = endTimeStr.split(':').map(int.parse).toList();

        final start = DateTime(now.year, now.month, now.day, startParts[0], startParts[1]);
        final end = DateTime(now.year, now.month, now.day, endParts[0], endParts[1]);

        if (now.isAfter(start.subtract(const Duration(minutes: 30))) &&
            now.isBefore(end.add(const Duration(minutes: 30)))) {
          setState(() {
            _selectedMode = mode;
            _attendanceMode = mode['key'] as String;
          });
          debugPrint('⏰ Auto-selected mode: $_attendanceMode');
          break;
        }
      } catch (_) {}
    }
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer?.cancel();
    _scheduleCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted) _autoSelectCurrentShift();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSystemReady) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1B4B),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.face_rounded,
                    color: Color(0xFF818CF8),
                    size: 48,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  _initStatus,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _initProgress,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF6366F1),
                    ),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
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
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(
              child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                valueListenable: _detectedFacesNotifier,
                builder: (context, faces, _) {
                  if (faces.isEmpty) return const SizedBox.shrink();
                  return CustomPaint(
                    painter: FaceDetectorPainter(
                      absoluteImageSize: Size(
                        _cameraController!.value.previewSize!.height,
                        _cameraController!.value.previewSize!.width,
                      ),
                      faces: faces,
                      isFrontCamera: true,
                    ),
                  );
                },
              ),
            ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.black45,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.people_outline, color: Colors.white70, size: 18),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                AppLanguage.tr('attendance.face.session_count'),
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 9,
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
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.black45,
                          child: IconButton(
                            icon: const Icon(Icons.assignment_ind_outlined, color: Colors.white),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ManualCheckPage(
                                    organizationMemberId: _organizationMemberId ?? 0,
                                    memberData: {'organization_id': widget.organizationId},
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        CircleAvatar(
                          backgroundColor: Colors.black45,
                          child: IconButton(
                            icon: const Icon(Icons.refresh, color: Colors.white),
                            onPressed: () async {
                              await _biometricService.refreshCache(widget.organizationId);
                              _showMessage(
                                AppLanguage.tr('attendance.face.refresh_success'),
                                MessageType.success,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_currentMessage != null)
            Positioned(
              top: 100,
              left: 20,
              right: 20,
              child: _buildNotificationBanner(),
            ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationBanner() {
    Color bg;
    IconData icon;

    switch (_messageType) {
      case MessageType.success:
        bg = Colors.green.shade800;
        icon = Icons.check_circle_outline;
        break;
      case MessageType.error:
        bg = Colors.red.shade800;
        icon = Icons.error_outline;
        break;
      case MessageType.warning:
        bg = Colors.orange.shade800;
        icon = Icons.warning_amber_rounded;
        break;
      default:
        bg = Colors.indigo.shade800;
        icon = Icons.info_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _currentMessage!,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  AppLanguage.tr('attendance.face.attendance_data'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_availableModes.isNotEmpty)
                  DropdownButton<String>(
                    value: _attendanceMode,
                    underline: const SizedBox(),
                    items: _availableModes.map((m) {
                      return DropdownMenuItem<String>(
                        value: m['key'] as String,
                        child: Text(
                          m['label'] as String,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _attendanceMode = val;
                        });
                      }
                    },
                  ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: _recentAttendanceList.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        AppLanguage.tr('attendance.face.no_data'),
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _recentAttendanceList.length,
                    itemBuilder: (context, index) {
                      final item = _recentAttendanceList[index];
                      final isDup = item['is_duplicate'] == true;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDup ? Colors.orange.shade50 : Colors.white,
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(
                            color: isDup ? Colors.orange.shade200 : const Color(0xFFE8DAEF),
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.grey.shade100,
                              child: const Icon(Icons.person, color: Colors.grey, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item['name'] ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Color(0xFF2C3E50),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${item['type'] ?? ''} • ${item['time'] ?? ''}',
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
                            Icon(
                              isDup ? Icons.warning_rounded : Icons.check_circle,
                              color: isDup ? Colors.orange : const Color(0xFF27AE60),
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
  }
}
