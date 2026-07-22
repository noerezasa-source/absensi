// lib/pages/face_registration_page.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/face_recognition_tflite_service.dart';
import '../services/biometric_service.dart';
import '../../services/supabase_storage_service.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import '../../services/tts_service.dart';
import '../../helpers/language_helper.dart';
import '../../services/offline_database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FaceRegistrationPage extends StatefulWidget {
  final int organizationMemberId;
  final String? memberName;

  const FaceRegistrationPage({
    super.key,
    required this.organizationMemberId,
    this.memberName,
  });

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

enum CaptureAngle { front, left, right, complete }

class _FaceRegistrationPageState extends State<FaceRegistrationPage> {
  CameraController? _cameraController;
  FaceRecognitionTFLiteService?
  _faceService; // Use shared instance from BiometricService
  final BiometricService _biometricService = BiometricService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isScreenFlashEnabled = false;
  bool _showLowLightWarning = false;
  int _lightCheckFrameCount = 0;
  bool _isProcessing = false;
  bool _isTakingPicture = false;
  bool _isModelInitialized = false;
  String? _errorMessage;
  String _currentStep = AppLanguage.tr(
    'attendance.face_registration.loading_model',
  );
  String _guidanceMessage = '';
  Color _overlayColor = Colors.white;

  // State variables for ImageStream
  bool _isStreaming = false;
  int _consecutiveValidFrames = 0;
  final int _requiredValidFrames = 3;
  bool _isRegistrationComplete = false;

  // Multi-Angle Registration Logic
  CaptureAngle _currentAngle = CaptureAngle.front;
  final Map<CaptureAngle, Map<String, dynamic>> _capturedTemplates = {};
  String? _frontImagePath;
  String? _leftImagePath;
  String? _rightImagePath;

  // Guidance and UI
  List<Map<String, dynamic>> _painterFaces = []; // State for optimized painter
  DateTime? _lastProcessTime; // Throttling
  DateTime? _lastGuidanceUpdate;
  Timer? _errorTimer;
  DateTime? _lastTtsTime; // Voice guidance throttling

  // Member name display
  String? _memberName;

  void _speakGuidanceKey(String key) {
    final now = DateTime.now();
    if (_lastTtsTime == null ||
        now.difference(_lastTtsTime!) >= const Duration(seconds: 3)) {
      _lastTtsTime = now;
      TtsService().speakKey(key);
    }
  }

  void _speakGuidanceText(String text) {
    final now = DateTime.now();
    if (_lastTtsTime == null ||
        now.difference(_lastTtsTime!) >= const Duration(seconds: 3)) {
      _lastTtsTime = now;
      TtsService().speak(text);
    }
  }

  @override
  void initState() {
    super.initState();
    TtsService().initialize();
    _memberName = widget.memberName;
    if (_memberName == null) {
      _fetchMemberName();
    }
    _initializeModel();
  }

  /// Fetch member name from DB if not passed as parameter
  Future<void> _fetchMemberName() async {
    try {
      final response = await Supabase.instance.client
          .from('organization_members')
          .select('user_profiles (first_name, middle_name, last_name, display_name)')
          .eq('id', widget.organizationMemberId)
          .maybeSingle();

      if (response != null && response['user_profiles'] != null) {
        final profile = response['user_profiles'] as Map<String, dynamic>;
        final firstName = profile['first_name'] as String? ?? '';
        final middleName = profile['middle_name'] as String? ?? '';
        final lastName = profile['last_name'] as String? ?? '';
        final displayName = (profile['display_name'] as String?)?.trim();

        String fullName = middleName.isNotEmpty
            ? '$firstName $middleName $lastName'.trim()
            : '$firstName $lastName'.trim();

        String formatted;
        if (fullName.isNotEmpty &&
            displayName != null &&
            displayName.isNotEmpty &&
            fullName != displayName) {
          formatted = '$fullName - $displayName';
        } else if (displayName != null && displayName.isNotEmpty) {
          formatted = displayName;
        } else {
          formatted = fullName.isNotEmpty ? fullName : 'Member';
        }

        if (mounted) {
          setState(() {
            _memberName = formatted;
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching member name: $e');
    }
  }

  Future<void> _toggleTorchMode(bool enable) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      await _cameraController!.setFlashMode(enable ? FlashMode.torch : FlashMode.off);
      debugPrint('📷 Hardware torch set to: ${enable ? "ON" : "OFF"}');
    } catch (e) {
      debugPrint('Hardware torch not supported or failed: $e');
    }
  }

  @override
  void dispose() {
    TtsService().stop();
    _stopStream();
    _errorTimer?.cancel();
    _cameraController?.dispose();
    // Don't dispose shared service - it's managed by BiometricService
    super.dispose();
  }

  // Helper for debouncing guidance messages
  void _updateGuidance(String message, Color color) {
    final now = DateTime.now();
    if (_lastGuidanceUpdate != null &&
        now.difference(_lastGuidanceUpdate!) <
            const Duration(milliseconds: 500) &&
        message == _guidanceMessage) {
      return; // Skip update if too soon and message is same
    }

    if (mounted) {
      setState(() {
        _guidanceMessage = message;
        _overlayColor = color;
        _lastGuidanceUpdate = now;
      });
    }
  }

  // Helper for auto-clearing errors
  void _showError(String message) {
    if (!mounted) return;
    // Print full error so it's visible in device logs
    debugPrint('❌ FACE REGISTRATION ERROR: $message');
    setState(() {
      _errorMessage = message;
    });

    _errorTimer?.cancel();
    _errorTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _errorMessage = null;
        });
      }
    });
  }

  Future<void> _initializeModel() async {
    try {
      setState(() {
        _currentStep = AppLanguage.tr(
          'attendance.face_registration.loading_model',
        );
      });

      // Use shared service instance from BiometricService
      _faceService = await _biometricService.getFaceService();

      setState(() {
        _isModelInitialized = true;
        _currentStep = AppLanguage.tr(
          'attendance.face_registration.model_ready',
        );
      });

      await _initializeCamera();
    } catch (e) {
      if (mounted) {
        _showError('Failed to load model: $e');
        setState(() {
          _currentStep = AppLanguage.tr(
            'attendance.face_registration.model_failed',
          );
        });
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      setState(() {
        _currentStep = AppLanguage.tr(
          'attendance.face_registration.starting_camera',
        );
      });

      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high, // HD resolution
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      try {
        final maxExp = await _cameraController!.getMaxExposureOffset();
        if (maxExp > 0) {
          final targetExposure = (maxExp * 0.3).clamp(0.5, 1.5);
          await _cameraController!.setExposureOffset(targetExposure);
          debugPrint('📷 Camera exposure offset set to: $targetExposure');
        }
      } catch (e) {
        debugPrint('Exposure offset not supported or failed: $e');
      }

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _currentStep = AppLanguage.tr(
            'attendance.face_registration.step1_title',
          );
          _guidanceMessage = AppLanguage.tr(
            'attendance.face_registration.look_straight_ui',
          );
        });
        // Welcome voice guidance
        TtsService().speakKey('welcome');
        TtsService().speakKey('step1_instruction');

        // Start silent stream instead of polling timer
        _startImageStream();
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to initialize camera: $e');
      }
    }
  }

  void _startImageStream() {
    if (_cameraController == null || _isStreaming) return;

    try {
      _isStreaming = true;
      _cameraController!.startImageStream((CameraImage image) {
        _processCameraFrame(image);
      });
      debugPrint('✅ Image stream started successfully');
    } catch (e) {
      debugPrint('Error starting stream: $e');
      _isStreaming = false;
    }
  }

  Future<void> _stopStream() async {
    if (_cameraController != null && _isStreaming) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint('Error stopping stream: $e');
      }
      _isStreaming = false;
    }
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isProcessing || _isTakingPicture || _isRegistrationComplete) return;

    // 🚀 THROTTLING: Max ~6-7 FPS (every 150ms) to ensure smooth camera preview
    final now = DateTime.now();
    if (_lastProcessTime != null &&
        now.difference(_lastProcessTime!) < const Duration(milliseconds: 150)) {
      return;
    }

    _isProcessing = true;
    _lastProcessTime = now;

    try {
      // 1. Convert to InputImage
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      // 2. Detect Faces — use permissive detector so bracket is always visible
      if (_faceService == null) return;
      final faces = await _faceService!.detectFacesFromInputImage(inputImage);

      if (!mounted) return;

      if (faces.isEmpty) {
        _consecutiveValidFrames = 0;
        setState(() {
          _painterFaces = [];
          _overlayColor = Colors.transparent;
          _guidanceMessage = AppLanguage.tr(
            'attendance.face_registration.face_not_found_ui',
          );
        });
        _speakGuidanceKey('face_not_found');
      } else {
        final face = faces.first;
        final validation = _validateFace(
          face,
          Size(image.width.toDouble(), image.height.toDouble()),
        );

        if (mounted) {
          setState(() {
            _painterFaces = faces
                .map(
                  (f) => {
                    'rect': f.boundingBox,
                    'color': validation['isValid'] == true
                        ? Colors.green
                        : Colors.orange,
                    'name': validation['message'],
                  },
                )
                .toList();
          });
        }

        if (validation['isValid'] == true) {
          _consecutiveValidFrames++;
          _updateGuidance(
            AppLanguage.tr('attendance.face_registration.hold_position_ui'),
            Colors.green.withValues(alpha: 0.3),
          );
          _speakGuidanceKey('hold_position');

          // Check stability before capturing
          if (_consecutiveValidFrames >= _requiredValidFrames &&
              !_isTakingPicture) {
            _isTakingPicture = true; // Lock
            _stopStream(); // Async stop stream

            // Trigger capture
            setState(() {
              _guidanceMessage = AppLanguage.tr(
                'attendance.face_registration.capturing_ui',
              );
              _currentStep = AppLanguage.tr(
                'attendance.face_registration.capturing_ui',
              );
              _painterFaces = []; // Clear brackets during freeze-frame capture
            });
            TtsService().speakKey('capturing');

            final XFile file = await _cameraController!.takePicture();
            await _processCapturedAngle(file.path);
          }
        } else {
          _consecutiveValidFrames = 0;
          final String msg = validation['message'] ?? 'Sesuaikan posisi';
          _updateGuidance(msg, Colors.orange.withValues(alpha: 0.3));

          // Voice guidance fallback for validation error
          if (msg.contains('mata')) {
            _speakGuidanceKey('eyes_closed');
          } else if (msg.contains('miring') || msg.contains('Tilt')) {
            _speakGuidanceKey('tilt_head');
          } else if (msg.contains('Lurus') || msg.contains('Straight')) {
            _speakGuidanceKey('look_straight');
          } else if (msg.contains('KIRI') || msg.contains('LEFT')) {
            _speakGuidanceKey('turn_left');
          } else if (msg.contains('KANAN') || msg.contains('RIGHT')) {
            _speakGuidanceKey('turn_right');
          } else {
            _speakGuidanceText(msg);
          }
        }
      }
    } catch (e) {
      debugPrint('Stream process error: $e');
      _isTakingPicture = false;
      _startImageStream();
    } finally {
      _isProcessing = false;
    }
  }

  // Reuse the validation logic but adapted for Face object
  Map<String, dynamic> _validateFace(dynamic face, Size imageSize) {
    // Basic validation logic
    final double leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final double rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;

    // Relaxed eye open probability to accommodate glasses or narrow eyes
    if (leftEyeOpen < 0.25 || rightEyeOpen < 0.25) {
      return {'isValid': false, 'message': 'Buka mata Anda'};
    }

    final double headY = face.headEulerAngleY ?? 0.0;
    final double headX = face.headEulerAngleX ?? 0.0;
    final double headZ = (face.headEulerAngleZ ?? 0.0).abs();

    if (headZ > 45.0) {
      return {
        'isValid': false,
        'message': 'Jangan miringkan kepala',
      }; // Relaxed from 35
    }

    // Angle specific validation
    switch (_currentAngle) {
      case CaptureAngle.front:
        if (headY.abs() > 15.0) {
          return {
            'isValid': false,
            'message': 'Lihat Lurus ke Depan',
          };
        }
        if (headX.abs() > 15.0) {
          return {'isValid': false, 'message': 'Wajah sejajar kamera'};
        }
        break;
      case CaptureAngle.left:
        // Range: 20 to 50 degrees
        if (headY < -15.0) {
          return {'isValid': false, 'message': '← Salah Arah! Toleh KIRI'};
        }
        if (headY < 20.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr(
              'attendance.face_registration.turn_left_ui',
            ),
          };
        }
        if (headY > 50.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr(
              'attendance.face_registration.tilt_head_ui',
            ),
          };
        }
        break;
      case CaptureAngle.right:
        // Range: -20 to -50 degrees
        if (headY > 15.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr(
              'attendance.face_registration.wrong_direction_right',
            ),
          };
        }
        if (headY > -20.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr(
              'attendance.face_registration.turn_right_ui',
            ),
          };
        }
        if (headY < -50.0) {
          return {
            'isValid': false,
            'message': AppLanguage.tr(
              'attendance.face_registration.tilt_head_ui',
            ),
          };
        }
        break;
      default:
        break;
    }

    return {
      'isValid': true,
      'message': AppLanguage.tr('attendance.face_registration.perfect_hold'),
    };
  }

  Future<void> _processCapturedAngle(String imagePath) async {
    try {
      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = AppLanguage.tr(
          'attendance.face_registration.success_angle',
        );
        _currentStep = AppLanguage.tr(
          'attendance.face_registration.processing',
        );
      });

      // Extract features — use permissive detector for enrollment
      if (_faceService == null) return;
      final faceTemplate = await _faceService!.extractFaceFeatures(
        imagePath,
        allowSidePose: _currentAngle != CaptureAngle.front,
        forRegistration: true,
      );

      // ✅ BALANCED VALIDATION: Not too strict, not too loose
      double qualityScore =
          (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;

      // 🚀 Relaxed Quality Standard to avoid frustrating users while maintaining decent accuracy
      double minQuality = _currentAngle == CaptureAngle.front ? 0.80 : 0.55;

      if (qualityScore < minQuality) {
        _updateGuidance(
          AppLanguage.tr('attendance.face_registration.quality_low_ui'),
          Colors.red,
        );
        TtsService().speakKey('quality_low');

        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      // Store template
      _capturedTemplates[_currentAngle] = faceTemplate;

      if (_currentAngle == CaptureAngle.front) {
        _frontImagePath = imagePath;
      } else if (_currentAngle == CaptureAngle.left) {
        _leftImagePath = imagePath;
      } else if (_currentAngle == CaptureAngle.right) {
        _rightImagePath = imagePath;
      }

      // PROGRESS LOGIC
      if (_currentAngle == CaptureAngle.front) {
        _currentAngle = CaptureAngle.left;
        _resetStreamForAngle(
          AppLanguage.tr('attendance.face_registration.step2_title'),
          AppLanguage.tr('attendance.face_registration.turn_left_ui'),
        );
        await TtsService().speakKey('step_done_front');
        TtsService().speakKey('step2_instruction');
      } else if (_currentAngle == CaptureAngle.left) {
        _currentAngle = CaptureAngle.right;
        _resetStreamForAngle(
          AppLanguage.tr('attendance.face_registration.step3_title'),
          AppLanguage.tr('attendance.face_registration.turn_right_ui'),
        );
        await TtsService().speakKey('step_done_left');
        TtsService().speakKey('step3_instruction');
      } else {
        // Complete
        _updateGuidance(
          AppLanguage.tr('attendance.face_registration.done_saving'),
          Colors.green,
        );
        setState(() {
          _isRegistrationComplete = true;
          _currentStep = AppLanguage.tr(
            'attendance.face_registration.saving_data',
          );
        });
        await TtsService().speakKey('step_done_right');
        TtsService().speakKey('saving');
        await _finalizeMultiAngleRegistration();
      }
    } catch (e) {
      debugPrint('Error processing angle: $e');
      _isTakingPicture = false;
      _startImageStream();
      _showError('Gagal memproses: $e');
    }
  }

  void _resetStreamForAngle(String stepName, String msg) {
    _consecutiveValidFrames = 0;
    _isTakingPicture = false;
    _startImageStream();
    _updateGuidance(msg, Colors.blue);
    setState(() {
      _currentStep = stepName;
    });
  }

  Future<void> _finalizeMultiAngleRegistration() async {
    setState(() {
      _isLoading = true;
      _currentStep = AppLanguage.tr('attendance.face_registration.saving_db');
    });

    try {
      // 1. Combine templates
      final List<Map<String, dynamic>> combinedList = [];
      if (_capturedTemplates.containsKey(CaptureAngle.front)) {
        combinedList.add(_capturedTemplates[CaptureAngle.front]!);
      }
      if (_capturedTemplates.containsKey(CaptureAngle.left)) {
        combinedList.add(_capturedTemplates[CaptureAngle.left]!);
      }
      if (_capturedTemplates.containsKey(CaptureAngle.right)) {
        combinedList.add(_capturedTemplates[CaptureAngle.right]!);
      }

      final multiTemplate = {
        'version': 4, // Aligned with high-standard container version
        'templates': combinedList,
        'totalAngles': combinedList.length,
        'enrollmentDate': DateTime.now().toIso8601String(),
      };

      // ✅ DUPLICATE GUARD: Check if this face is already registered to someone else
      try {
        final memberRow = await Supabase.instance.client
            .from('organization_members')
            .select('organization_id')
            .eq('id', widget.organizationMemberId)
            .maybeSingle();
        final orgId = memberRow?['organization_id'] as int?;
        if (orgId != null) {
          final duplicateWarning = await _biometricService.verifyFaceAgainstExisting(
            faceTemplate: combinedList.first, // Check the front-facing template
            intendedMemberId: widget.organizationMemberId,
            organizationId: orgId,
          );
          if (duplicateWarning != null && mounted) {
            final matchedName = duplicateWarning['matched_name'] as String? ?? 'Unknown';
            final similarity = ((duplicateWarning['similarity'] as double?) ?? 0) * 100;
            setState(() {
              _isLoading = false;
            });
            final proceed = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
                    SizedBox(width: 8),
                    Text('Peringatan Duplikat'),
                  ],
                ),
                content: Text(
                  'Wajah ini mirip dengan "$matchedName" '
                  '(${similarity.toStringAsFixed(0)}% cocok).\n\n'
                  'Pastikan orang yang benar sedang menghadap kamera.\n\n'
                  'Lanjutkan registrasi?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Batal', style: TextStyle(color: Colors.red)),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Lanjutkan'),
                  ),
                ],
              ),
            );
            if (proceed != true) {
              setState(() {
                _isRegistrationComplete = false;
              });
              _currentAngle = CaptureAngle.front;
              _capturedTemplates.clear();
              _startImageStream();
              return;
            }
            setState(() {
              _isLoading = true;
            });
          }
        }
      } catch (e) {
        debugPrint('⚠️ Duplicate face check failed (non-fatal): $e');
      }

      // 2. Upload Photos (Front, Left, Right)
      final pathsToUpload = [
        _frontImagePath,
        _leftImagePath,
        _rightImagePath,
      ];

      String? frontPhotoUrl;

      for (int i = 0; i < pathsToUpload.length; i++) {
        final path = pathsToUpload[i];
        if (path != null) {
          final imageFile = File(path);
          if (await imageFile.exists()) {
            final processedFile = await _processImage(imageFile);
            
            // Pass the angle suffix (front, left, right) so we can distinguish them in storage
            final suffix = i == 0 ? 'front' : (i == 1 ? 'left' : 'right');
            
            final uploadedUrl = await _storageService.uploadFaceTemplate(
              processedFile,
              widget.organizationMemberId,
              suffix: suffix,
            );

            // Jika ini foto FRONT, simpan URL-nya untuk jadi foto profil
            if (i == 0) {
              frontPhotoUrl = uploadedUrl;
            }

            // Clean up temp files
            if (await imageFile.exists()) await imageFile.delete();
            if (processedFile.path != imageFile.path) {
              final pf = File(processedFile.path);
              if (await pf.exists()) await pf.delete();
            }
          }
        }
      }

      // 2.5 Update user profile photo with the FRONT photo if profile photo is empty or is a previous face-template photo
      if (frontPhotoUrl != null) {
        try {
          // Cari user_id dan profile_photo_url yang terhubung dengan organization_member_id ini
          final memberData = await Supabase.instance.client
              .from('organization_members')
              .select('user_id, user_profiles(profile_photo_url)')
              .eq('id', widget.organizationMemberId)
              .maybeSingle();
          
          final userId = memberData?['user_id'];
          if (userId != null) {
            final userProfile = memberData?['user_profiles'] as Map<String, dynamic>?;
            final existingPhoto = userProfile?['profile_photo_url'] as String?;

            // Hanya update jika belum ada foto profil, ATAU foto profil saat ini adalah foto otomatis dari registrasi wajah sebelumnya
            final shouldUpdate = existingPhoto == null ||
                existingPhoto.trim().isEmpty ||
                existingPhoto.contains('face-templates');

            if (shouldUpdate) {
              // 1. Update ke Server Supabase
              await Supabase.instance.client
                  .from('user_profiles')
                  .update({'profile_photo_url': frontPhotoUrl})
                  .eq('id', userId);
              
              // 2. Update ke Cache Lokal SQLite agar UI langsung berubah
              await _offlineDb.database.then((db) async {
                await db.update(
                  'cached_members',
                  {'profile_photo_url': frontPhotoUrl},
                  where: 'organization_member_id = ?',
                  whereArgs: [widget.organizationMemberId],
                );
              });

              // 3. Hapus cache SharedPreferences anggota agar daftar anggota langsung ter-refresh
              await _clearMemberCaches();
              
              debugPrint('✅ Profile photo updated automatically in Server, SQLite, & SharedPreferences');
            } else {
              debugPrint('ℹ️ Preserved existing custom profile photo for user $userId');
            }
          }
        } catch (e) {
          debugPrint('⚠️ Failed to auto-update profile photo: $e');
        }
      }

      // 3. Register to Database
      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: multiTemplate,
      );

      if (mounted) {
        TtsService().speakKey('complete');
        _showSuccessDialog();
      }
    } catch (e) {
      _showError('Gagal registrasi: $e');
      setState(() {
        _isLoading = false;
        _isRegistrationComplete = false;
      });
      _currentAngle = CaptureAngle.front; // Reset
      _startImageStream();
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 48),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 24),
              Text(
                AppLanguage.tr('attendance.face_registration.reg_complete'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLanguage.tr('attendance.face_registration.reg_desc'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        Navigator.of(context).pop();
        Navigator.of(context).pop(true);
      }
    });
  }

  // Obsolete - kept for reference if needed during migration but removed from flow
  Future<void> _captureFrontPose(String imagePath) async {
    try {
      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = 'Foto berhasil!';
        _currentStep = 'Memproses foto...';
      });

      // ✅ SIMPLIFIED: Extract front face features only (no side pose)
      if (_faceService == null) return;
      final faceTemplate = await _faceService!.extractFaceFeatures(
        imagePath,
        allowSidePose: false,
      );

      debugPrint(
        '✅ Captured front face with ${faceTemplate['landmarkCount']} landmarks',
      );

      // ✅ STRICT QUALITY CHECK (Added): Require 90% quality score
      double qualityScore =
          (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;

      // ✅ IMPROVED: Multi-tier quality check
      String qualityLevel;
      double minRequired;

      if (qualityScore >= 0.85) {
        qualityLevel = 'Excellent';
        minRequired = 0.85;
      } else if (qualityScore >= 0.75) {
        qualityLevel = 'Good';
        minRequired = 0.75;
      } else if (qualityScore >= 0.65) {
        qualityLevel =
            'Acceptable'; // Allow lower quality but might be strict during recog
        minRequired = 0.65;
      } else {
        qualityLevel = 'Poor';
        minRequired = 0.65;
      }

      debugPrint(
        '🔍 Face Quality: ${(qualityScore * 100).toStringAsFixed(1)}% ($qualityLevel)',
      );

      if (qualityScore < minRequired) {
        setState(() {
          _guidanceMessage = AppLanguage.tr(
            'attendance.face_registration.quality_low_ui',
          );
          _overlayColor = Colors.orange;
          _currentStep = AppLanguage.tr(
            'attendance.face_registration.quality_low_ui',
          );
        });
        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      // ✅ ENHANCED: Check liveness score if available
      final livenessData =
          faceTemplate['livenessDetection'] as Map<String, dynamic>?;
      if (livenessData != null) {
        final livenessScore =
            (livenessData['livenessScore'] as num?)?.toDouble() ?? 0.0;
        if (livenessScore < 0.5) {
          debugPrint(
            '⚠️ Low liveness score: ${livenessScore.toStringAsFixed(2)}',
          );
          setState(() {
            _guidanceMessage = AppLanguage.tr(
              'attendance.face_registration.liveness_low',
            );
            _overlayColor = Colors.red;
          });
          await Future.delayed(const Duration(seconds: 2));
          await File(imagePath).delete();
          _isTakingPicture = false;
          _startImageStream();
          return;
        }
      }

      setState(() {
        _guidanceMessage =
            '$qualityLevel Quality! (${(qualityScore * 100).toInt()}%)';
        _overlayColor = Colors.green;
        _isRegistrationComplete = true;
      });

      await _registerSingleTemplate(faceTemplate, imagePath);
    } catch (e) {
      if (mounted) {
        _showError(
          'Gagal memproses foto: ${e.toString().replaceAll('Exception: ', '')}',
        );
        setState(() {
          _overlayColor = Colors.red;
          _isRegistrationComplete = false;
        });
      }

      // Retry
      await File(imagePath).delete();
      _startImageStream();
    }
  }

  Future<void> _registerSingleTemplate(
    Map<String, dynamic> faceTemplate,
    String imagePath,
  ) async {
    setState(() {
      _isLoading = true;
      _currentStep = 'Menyimpan template...';
      _overlayColor = Colors.green;
    });

    try {
      debugPrint('Single template registration:');
      debugPrint('- Version: ${faceTemplate['version']}');
      debugPrint('- Embedding size: ${faceTemplate['embeddingSize']}');
      debugPrint('- Landmarks: ${faceTemplate['landmarkCount']}');

      setState(() {
        _currentStep = 'Mengunggah foto...';
      });

      // Upload front image as profile photo
      final imageFile = File(imagePath);
      final processedFile = await _processImage(imageFile);
      final uploadedUrl = await _storageService.uploadFaceTemplate(
        processedFile,
        widget.organizationMemberId,
      );

      // Auto-update profile photo for single template as well if profile photo is empty or from face-templates
      try {
        final memberData = await Supabase.instance.client
            .from('organization_members')
            .select('user_id, user_profiles(profile_photo_url)')
            .eq('id', widget.organizationMemberId)
            .maybeSingle();
        
        final userId = memberData?['user_id'];
        if (userId != null) {
          final userProfile = memberData?['user_profiles'] as Map<String, dynamic>?;
          final existingPhoto = userProfile?['profile_photo_url'] as String?;

          final shouldUpdate = existingPhoto == null ||
              existingPhoto.trim().isEmpty ||
              existingPhoto.contains('face-templates');

          if (shouldUpdate) {
            await Supabase.instance.client
                .from('user_profiles')
                .update({'profile_photo_url': uploadedUrl})
                .eq('id', userId);

            await _offlineDb.database.then((db) async {
              await db.update(
                'cached_members',
                {'profile_photo_url': uploadedUrl},
                where: 'organization_member_id = ?',
                whereArgs: [widget.organizationMemberId],
              );
            });

            await _clearMemberCaches();

            debugPrint('✅ Profile photo updated automatically (single capture)');
          }
        }
      } catch (e) {
        debugPrint('⚠️ Failed to auto-update profile photo: $e');
      }

      // Clean up image files
      if (await imageFile.exists()) {
        await imageFile.delete();
      }
      if (processedFile.path != imageFile.path) {
        final processed = File(processedFile.path);
        if (await processed.exists()) {
          await processed.delete();
        }
      }

      setState(() {
        _currentStep = 'Menyimpan template...';
      });

      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: faceTemplate,
      );

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.black.withValues(alpha: 0.7),
          builder: (context) => Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 48),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    AppLanguage.tr('attendance.face_registration.reg_complete'),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      decoration: TextDecoration.none,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLanguage.tr('attendance.face_registration.reg_desc'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.grey,
                      letterSpacing: 0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        await Future.delayed(const Duration(milliseconds: 2000));
        if (mounted) {
          Navigator.of(context).pop();
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      _showError(
        'Gagal menyimpan: ${e.toString().replaceAll('Exception: ', '')}',
      );
      setState(() {
        _currentStep = AppLanguage.tr(
          'attendance.face_registration.save_failed',
        );
        _isLoading = false;
        _overlayColor = Colors.red;
        _isRegistrationComplete = false;
      });

      _startImageStream();
    }
  }

  Future<File> _processImage(File imageFile) async {
    try {
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);

      if (image == null) {
        return imageFile;
      }

      var enhanced = img.adjustColor(image, brightness: 1.1, contrast: 1.15);

      final flipped = img.flipHorizontal(enhanced);

      final resized = img.copyResize(
        flipped,
        width: 800,
        interpolation: img.Interpolation.average,
      );

      final compressedBytes = img.encodeJpg(resized, quality: 90);

      final tempDir = await Directory.systemTemp.createTemp();
      final processedFile = File('${tempDir.path}/processed_face.jpg');
      await processedFile.writeAsBytes(compressedBytes);

      return processedFile;
    } catch (e) {
      return imageFile;
    }
  }

  // Helper for CameraImage -> InputImage
  // Uses NV21 format which is the only format guaranteed to work with ML Kit on Android.
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

    if (Platform.isAndroid) {
      try {
        final nv21Bytes = _yuv420ToNv21(image);
        debugPrint('📷 [REG] InputImage: size=${image.width}x${image.height}, format=${InputImageFormat.nv21.name} (${InputImageFormat.nv21.rawValue}), bytes=${nv21Bytes.length}');

        // Throttled low-light check (once every 30 frames)
        _lightCheckFrameCount++;
        if (_lightCheckFrameCount >= 30) {
          _lightCheckFrameCount = 0;
          _enhanceNv21Brightness(nv21Bytes, image.width * image.height);
        }

        return InputImage.fromBytes(
          bytes: nv21Bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: image.width,
          ),
        );
      } catch (e) {
        debugPrint('YUV conversion error: $e');
        return null;
      }
    }

    // iOS: planes can be used directly
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    // Throttled low-light check (once every 30 frames)
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

    // Copy Y plane
    final Uint8List yPlane = image.planes[0].bytes;
    final int yRowStride = image.planes[0].bytesPerRow;
    if (yRowStride == width) {
      nv21.setRange(0, ySize, yPlane);
    } else {
      for (int row = 0; row < height; row++) {
        nv21.setRange(
          row * width,
          row * width + width,
          yPlane,
          row * yRowStride,
        );
      }
    }

    // Interleave V and U planes for NV21 (V first, then U)
    final Uint8List uPlane = image.planes[1].bytes;
    final Uint8List vPlane = image.planes[2].bytes;
    final int uvRowStride = image.planes[1].bytesPerRow;
    final int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    if (uvPixelStride == 2) {
      // Semi-planar (interleaved VU) - Copy the entire V plane directly!
      final int toCopy = vPlane.length < uvSize ? vPlane.length : uvSize;
      nv21.setRange(ySize, ySize + toCopy, vPlane);
    } else {
      // Planar - Manual interleave
      int pos = ySize;
      for (int row = 0; row < height ~/ 2; row++) {
        for (int col = 0; col < width ~/ 2; col++) {
          final int uvIndex = row * uvRowStride + col * uvPixelStride;
          nv21[pos++] = vPlane[uvIndex];
          nv21[pos++] = uPlane[uvIndex];
        }
      }
    }
    
    return nv21;
  }


  void _enhanceNv21Brightness(Uint8List nv21, int ySize) {
    if (ySize == 0 || nv21.isEmpty) return;
    int sum = 0;
    int sampleCount = 0;
    for (int i = 0; i < ySize; i += 64) {
      if (i >= nv21.length) break;
      sum += nv21[i];
      sampleCount++;
    }
    if (sampleCount == 0) return;
    final double averageLuminance = sum / sampleCount;

    final bool isDark = averageLuminance < 60.0;
    if (_showLowLightWarning != isDark) {
      _showLowLightWarning = isDark;
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _enhanceBgraBrightness(Uint8List bytes) {
    final int totalBytes = bytes.length;
    if (totalBytes == 0) return;
    int sum = 0;
    int sampleCount = 0;
    for (int i = 0; i < totalBytes; i += 256) {
      if (i + 2 >= totalBytes) break;
      final b = bytes[i];
      final g = bytes[i + 1];
      final r = bytes[i + 2];
      sum += (0.299 * r + 0.587 * g + 0.114 * b).round();
      sampleCount++;
    }
    if (sampleCount == 0) return;
    final double averageLuminance = sum / sampleCount;

    final bool isDark = averageLuminance < 60.0;
    if (_showLowLightWarning != isDark) {
      _showLowLightWarning = isDark;
      if (mounted) {
        setState(() {});
      }
    }
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  Widget _buildAngleFlowchart() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (index) {
        bool completed = false;
        bool current = false;

        switch (_currentAngle) {
          case CaptureAngle.front:
            completed = false;
            current = index == 0;
            break;
          case CaptureAngle.left:
            completed = index == 0;
            current = index == 1;
            break;
          case CaptureAngle.right:
            completed = index == 0 || index == 1;
            current = index == 2;
            break;
          case CaptureAngle.complete:
            completed = true;
            current = false;
            break;
        }

        return Row(
          children: [
            // Step circle
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: completed
                    ? Colors.white
                    : current
                    ? Colors.white.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.2),
                border: Border.all(
                  color: current
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: Center(
                child: completed
                    ? const Icon(
                        Icons.check,
                        color: Color(0xFF4A1E79),
                        size: 24,
                      )
                    : Text(
                        index == 0
                            ? 'F'
                            : index == 1
                            ? 'L'
                            : 'R',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: current
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
              ),
            ),
            // Connecting line (except for last step)
            if (index < 2)
              Container(
                width: 30,
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: completed
                      ? Colors.white
                      : current
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final double viewfinderWidth = screenSize.width * 0.7;
    final double viewfinderHeight = viewfinderWidth * 1.3;

    return Scaffold(
      body: Stack(
        children: [
          // 1. FULL CAMERA BACKGROUND
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

          // Screen Flash Overlay
          if (_isScreenFlashEnabled)
            const Positioned.fill(
              child: IgnorePointer(
                child: ScreenFlashOverlay(),
              ),
            ),

          // Background logo with transparency
          Positioned.fill(
            child: Opacity(
              opacity: 0.08,
              child: Image.asset(
                'assets/logo/app_logo_terbaru.png',
                fit: BoxFit.contain,
                alignment: Alignment.center,
                width: 300,
                height: 300,
              ),
            ),
          ),

          // 2. DYNAMIC FACE BRACKETS (Optimized CustomPainter)
          if (_painterFaces.isNotEmpty &&
              _cameraController != null &&
              _cameraController!.value.previewSize != null)
            Positioned.fill(
              child: CustomPaint(
                painter: FaceDetectorPainter(
                  absoluteImageSize: Size(
                    _cameraController!.value.previewSize!.height,
                    _cameraController!.value.previewSize!.width,
                  ),
                  faces: _painterFaces,
                  isFrontCamera: true,
                ),
              ),
            ),

          // 3. TOP BAR
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Registrasi Wajah',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (_memberName != null && _memberName!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              _memberName!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _isScreenFlashEnabled
                            ? Icons.flash_on_rounded
                            : Icons.flash_off_rounded,
                        color: _isScreenFlashEnabled
                            ? Colors.yellow
                            : Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          _isScreenFlashEnabled = !_isScreenFlashEnabled;
                        });
                        _toggleTorchMode(_isScreenFlashEnabled);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Low Light Warning Notification Banner
          if (_showLowLightWarning && !_isScreenFlashEnabled)
            Positioned(
              bottom: 250, // tepat di atas kartu progress
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade900.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wb_incandescent_outlined, color: Colors.white),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Lingkungan redup. Silakan aktifkan Cahaya Layar.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.amber.shade900,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () {
                        setState(() {
                          _isScreenFlashEnabled = true;
                        });
                        _toggleTorchMode(true);
                      },
                      child: const Text(
                        'Aktifkan',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. PROGRESS CARD with Flowchart
          if (_isCameraInitialized && _isModelInitialized)
            Positioned(
              left: 20,
              right: 20,
              bottom: 30,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 28,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF8938DF), Color(0xFF4A1E79)],
                  ),
                  borderRadius: BorderRadius.circular(36),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 25,
                      offset: const Offset(0, 15),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _guidanceMessage.isNotEmpty
                          ? _guidanceMessage
                          : 'Scanning your face...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _currentStep,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Flowchart for 3 angles
                    _buildAngleFlowchart(),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'PROGRESS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.8,
                          ),
                        ),
                        Text(
                          '${_getProgressPercentage().toInt()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 7,
                        width: double.infinity,
                        color: Colors.white.withValues(alpha: 0.15),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: _getProgressPercentage() / 100,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Error message overlay
          if (_errorMessage != null)
            Positioned(
              top: 10,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Loading overlay
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.7),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _getProgressPercentage() {
    if (_isRegistrationComplete) return 100;

    double base = 0;
    switch (_currentAngle) {
      case CaptureAngle.front:
        base = 0;
        break;
      case CaptureAngle.left:
        base = 33;
        break;
      case CaptureAngle.right:
        base = 66;
        break;
      default:
        return 100;
    }

    // Add small visual progress for validation success
    if (_isTakingPicture) return base + 30; // Almost done with step
    if (_consecutiveValidFrames > 0) return base + 15; // Validating

    return base + 5; // Started step
  }

  Future<void> _clearMemberCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('org_members')).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
      debugPrint('🧹 Cleared ${keys.length} member list cache keys in SharedPreferences');
    } catch (e) {
      debugPrint('⚠️ Error clearing member cache: $e');
    }
  }
}

/// ✅ SYNC: Optimized Custom Painter for all faces (matching attendance page)
class FaceDetectorPainter extends CustomPainter {
  final Size absoluteImageSize;
  final List<Map<String, dynamic>> faces;
  final bool isFrontCamera;

  FaceDetectorPainter({
    required this.absoluteImageSize,
    required this.faces,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (absoluteImageSize.width == 0 || absoluteImageSize.height == 0) return;

    final double scaleX = size.width / absoluteImageSize.width;
    final double scaleY = size.height / absoluteImageSize.height;

    final Paint bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final Paint boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final face in faces) {
      final rect = face['rect'] as Rect;
      final color = face['color'] as Color;
      final nameLabel = face['name'] as String?;

      // Apply scaling and mirroring
      double left, right;
      if (isFrontCamera) {
        left = (absoluteImageSize.width - rect.right) * scaleX;
        right = (absoluteImageSize.width - rect.left) * scaleX;
      } else {
        left = rect.left * scaleX;
        right = rect.right * scaleX;
      }
      final top = rect.top * scaleY;
      final bottom = rect.bottom * scaleY;

      final mappedRect = Rect.fromLTRB(left, top, right, bottom);

      // 1. Draw main rounded box with low opacity
      boxPaint.color = color.withValues(alpha: 0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(mappedRect, const Radius.circular(12)),
        boxPaint,
      );

      // 2. Draw Brackets
      bracketPaint.color = color;
      const bSize = 20.0;

      // Top-Left
      canvas.drawLine(
        Offset(left, top + bSize),
        Offset(left, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, top),
        Offset(left + bSize, top),
        bracketPaint,
      );

      // Top-Right
      canvas.drawLine(
        Offset(right - bSize, top),
        Offset(right, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, top),
        Offset(right, top + bSize),
        bracketPaint,
      );

      // Bottom-Left
      canvas.drawLine(
        Offset(left, bottom - bSize),
        Offset(left, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, bottom),
        Offset(left + bSize, bottom),
        bracketPaint,
      );

      // Bottom-Right
      canvas.drawLine(
        Offset(right - bSize, bottom),
        Offset(right, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, bottom),
        Offset(right, bottom - bSize),
        bracketPaint,
      );

      // 3. Draw Name/Status Label (if present)
      if (nameLabel != null && nameLabel.isNotEmpty) {
        final textSpan = TextSpan(
          text: nameLabel,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [Shadow(blurRadius: 2, color: Colors.black)],
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();

        final labelBgPaint = Paint()..color = color.withValues(alpha: 0.8);
        final labelRect = Rect.fromLTWH(
          left,
          top - textPainter.height - 8,
          textPainter.width + 12,
          textPainter.height + 4,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
          labelBgPaint,
        );
        textPainter.paint(
          canvas,
          Offset(left + 6, top - textPainter.height - 6),
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) => true;
}

class ScreenFlashOverlay extends StatelessWidget {
  const ScreenFlashOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: ScreenFlashOverlayPainter(),
    );
  }
}

class ScreenFlashOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw a white background over the whole screen
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final double centerX = size.width / 2;
    final double centerY = size.height / 2.3; // slightly above center to align with typical face positioning
    final double radiusX = size.width * 0.32;
    final double radiusY = radiusX * 1.35;

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: radiusX * 2,
        height: radiusY * 2,
      ))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, paint);

    // 2. Draw a subtle border around the oval cutout
    final borderPaint = Paint()
      ..color = const Color(0xFF6366F1) // Indigo accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: radiusX * 2,
        height: radiusY * 2,
      ),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
