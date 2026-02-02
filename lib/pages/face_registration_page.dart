// lib/pages/face_registration_page.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../services/face_recognition_tflite_service.dart';
import '../services/biometric_service.dart';
import '../services/supabase_storage_service.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

class FaceRegistrationPage extends StatefulWidget {
  final int organizationMemberId;

  const FaceRegistrationPage({
    super.key,
    required this.organizationMemberId,
  });

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

enum CaptureAngle { front, left, right, complete }

class _FaceRegistrationPageState extends State<FaceRegistrationPage> {
  CameraController? _cameraController;
  final FaceRecognitionTFLiteService _faceService = FaceRecognitionTFLiteService();
  final BiometricService _biometricService = BiometricService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isTakingPicture = false; 
  bool _isModelInitialized = false;
  String? _errorMessage;
  String _currentStep = 'Loading model...';
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

  // Deboucing & Auto-clear
  DateTime? _lastGuidanceUpdate;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    _initializeModel();
  }
  
  @override
  void dispose() {
    _stopStream();
    _errorTimer?.cancel();
    _cameraController?.dispose();
    _faceService.dispose();
    super.dispose();
  }

  // Helper for debouncing guidance messages
  void _updateGuidance(String message, Color color) {
    final now = DateTime.now();
    if (_lastGuidanceUpdate != null && 
        now.difference(_lastGuidanceUpdate!) < const Duration(milliseconds: 500) &&
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
    setState(() {
      _errorMessage = message;
    });
    
    _errorTimer?.cancel();
    _errorTimer = Timer(const Duration(seconds: 3), () {
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
        _currentStep = 'Loading model...';
      });

      await _faceService.initialize();
      
      setState(() {
        _isModelInitialized = true;
        _currentStep = 'Model ready';
      });

      await _initializeCamera();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load model: $e';
          _currentStep = 'Model initialization failed';
        });
      }
    }
  }

  Future<void> _initializeCamera() async {
    try {
      setState(() {
        _currentStep = 'Starting camera...';
      });

      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid 
            ? ImageFormatGroup.yuv420 
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _currentStep = 'Tahap 1: Wajah Depan';
          _guidanceMessage = 'Lihat Lurus ke Kamera';
        });
        // Start silent stream instead of polling timer
        _startImageStream();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize camera: $e';
        });
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
    _isProcessing = true;

    try {
      // 1. Convert to InputImage
      final inputImage = await _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      // 2. Detect Faces
      final faces = await _faceService.detectFacesFromInputImage(inputImage);
      
      if (!mounted) return;

      if (faces.isEmpty) {
        _consecutiveValidFrames = 0;
        setState(() {
          _overlayColor = Colors.transparent;
          _guidanceMessage = 'Arahkan wajah ke kamera';
        });
      } else {
        final face = faces.first;
        final validation = _validateFace(face, Size(image.width.toDouble(), image.height.toDouble()));
        
        if (validation['isValid'] == true) {
          _consecutiveValidFrames++;
          _updateGuidance('Tahan posisi...', Colors.green.withOpacity(0.3));

          // Check stability before capturing
          if (_consecutiveValidFrames >= _requiredValidFrames && !_isTakingPicture) {
            _isTakingPicture = true; // Lock
            _stopStream(); // Async stop stream
            
            // Trigger capture
            setState(() {
              _guidanceMessage = 'Mengambil foto...';
              _currentStep = 'Capturing...';
            });

            final XFile file = await _cameraController!.takePicture();
            await _processCapturedAngle(file.path);
          }
        } else {
          _consecutiveValidFrames = 0;
          _updateGuidance(validation['message'] ?? 'Sesuaikan posisi', Colors.orange.withOpacity(0.3));
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

    if (leftEyeOpen < 0.4 || rightEyeOpen < 0.4) return {'isValid': false, 'message': 'Buka mata Anda'};

    final double headY = face.headEulerAngleY ?? 0.0;
    final double headX = face.headEulerAngleX ?? 0.0;
    final double headZ = (face.headEulerAngleZ ?? 0.0).abs();
    
    if (headZ > 45.0) return {'isValid': false, 'message': 'Jangan miringkan kepala'}; // Relaxed from 35

    // Angle specific validation
    switch (_currentAngle) {
      case CaptureAngle.front:
        if (headY.abs() > 10.0) return {'isValid': false, 'message': 'Lihat Lurus ke Depan'}; // Relaxed from 10 to 15? No, keep 10 for front but provide clear feedback
        if (headX.abs() > 10.0) return {'isValid': false, 'message': 'Wajah sejajar kamera'};
        break;
      case CaptureAngle.left:
        // Range: 20 to 45 degrees (Relaxed)
        if (headY < 15.0) return {'isValid': false, 'message': 'Miringkan Wajah ke Kiri >>'};
        if (headY > 45.0) return {'isValid': false, 'message': 'Terlalu miring! Kembali sedikit'};
        break;
      case CaptureAngle.right:
        // Range: -45 to -20 degrees (Relaxed)
        if (headY > -15.0) return {'isValid': false, 'message': '<< Miringkan Wajah ke Kanan'};
        if (headY < -45.0) return {'isValid': false, 'message': 'Terlalu miring! Kembali sedikit'};
        break;
      default:
        break;
    }
    
    return {'isValid': true, 'message': 'Sempurna, Tahan!'};
  }

  Future<void> _processCapturedAngle(String imagePath) async {
    try {
      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = 'Sudut ${_currentAngle.name.toUpperCase()} Berhasil!';
        _currentStep = 'Memproses...';
      });

      // Extract features for this angle
      final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: _currentAngle != CaptureAngle.front,
      );

      // Quality check
      double qualityScore = (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
      
      // Dynamic Threshold: 0.85 for Front, 0.60 for Sides.
      double minQuality = _currentAngle == CaptureAngle.front ? 0.85 : 0.60;
      
      if (qualityScore < minQuality) {
        setState(() {
          _overlayColor = Colors.orange;
        });
        _updateGuidance('Kualitas ${(qualityScore*100).toInt()}%. Butuh > ${(minQuality*100).toInt()}%. Coba lagi.', Colors.orange);
        
        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      // Store template
      _capturedTemplates[_currentAngle] = faceTemplate;
      
      if (_currentAngle == CaptureAngle.front) {
        _frontImagePath = imagePath; // Keep front image
      } else {
        await File(imagePath).delete(); // Delete others
      }

      // PROGRESS LOGIC
      if (_currentAngle == CaptureAngle.front) {
        _currentAngle = CaptureAngle.left;
        _resetStreamForAngle('Tahap 2: Samping Kiri', 'Miringkan Wajah ke Kiri >>');
      } else if (_currentAngle == CaptureAngle.left) {
        _currentAngle = CaptureAngle.right;
        _resetStreamForAngle('Tahap 3: Samping Kanan', '<< Miringkan Wajah ke Kanan');
      } else {
        // Complete
        setState(() {
          _guidanceMessage = 'Selesai! Menyimpan...';
          _isRegistrationComplete = true;
          _currentStep = 'Menyimpan Data...';
        });
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
    setState(() {
      _currentStep = stepName;
      _guidanceMessage = msg;
      _overlayColor = Colors.blue;
    });
  }

  Future<void> _finalizeMultiAngleRegistration() async {
    setState(() {
      _isLoading = true;
      _currentStep = 'Menyimpan ke Database...';
    });

    try {
      // 1. Combine templates
      final List<Map<String, dynamic>> combinedList = [];
      if (_capturedTemplates.containsKey(CaptureAngle.front)) combinedList.add(_capturedTemplates[CaptureAngle.front]!);
      if (_capturedTemplates.containsKey(CaptureAngle.left)) combinedList.add(_capturedTemplates[CaptureAngle.left]!);
      if (_capturedTemplates.containsKey(CaptureAngle.right)) combinedList.add(_capturedTemplates[CaptureAngle.right]!);
      
      final multiTemplate = {
        'version': 4,
        'templates': combinedList,
        'totalAngles': combinedList.length,
        'enrollmentDate': DateTime.now().toIso8601String(),
      };

      // 2. Upload Front Photo
      if (_frontImagePath != null) {
        final imageFile = File(_frontImagePath!);
        final processedFile = await _processImage(imageFile);
        await _storageService.uploadFaceTemplate(
          processedFile,
          widget.organizationMemberId,
        );
        
        // Clean up
        if (await imageFile.exists()) await imageFile.delete();
        if (processedFile.path != imageFile.path) {
          final pf = File(processedFile.path);
          if (await pf.exists()) await pf.delete();
        }
      }

      // 3. Register to Database
      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: multiTemplate,
      );

      if (mounted) {
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
      barrierColor: Colors.black.withOpacity(0.7),
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
              const Text(
                'Registrasi Selesai!',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Akurasi pengenalan wajah kini lebih tinggi dengan multi-angle.',
                textAlign: TextAlign.center,
                style: TextStyle(
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
      final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: false,
      );
      
      debugPrint('✅ Captured front face with ${faceTemplate['landmarkCount']} landmarks');
      
      // ✅ STRICT QUALITY CHECK (Added): Require 90% quality score
      double qualityScore = (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
      
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
        qualityLevel = 'Acceptable'; // Allow lower quality but might be strict during recog
        minRequired = 0.65;
      } else {
        qualityLevel = 'Poor';
        minRequired = 0.65;
      }
      
      debugPrint('🔍 Face Quality: ${(qualityScore * 100).toStringAsFixed(1)}% ($qualityLevel)');
      
      if (qualityScore < minRequired) {
        setState(() {
          _guidanceMessage = 'Kualitas $qualityLevel (${(qualityScore * 100).toInt()}%). Butuh cahaya lebih terang!';
          _overlayColor = Colors.orange;
          _currentStep = 'Cahaya kurang - coba lagi';
        });
        await Future.delayed(const Duration(seconds: 2));
        await File(imagePath).delete();
        _isTakingPicture = false;
        _startImageStream();
        return;
      }

      // ✅ ENHANCED: Check liveness score if available
      final livenessData = faceTemplate['livenessDetection'] as Map<String, dynamic>?;
      if (livenessData != null) {
        final livenessScore = (livenessData['livenessScore'] as num?)?.toDouble() ?? 0.0;
        if (livenessScore < 0.5) {
          debugPrint('⚠️ Low liveness score: ${livenessScore.toStringAsFixed(2)}');
          setState(() {
            _guidanceMessage = 'Foto tidak natural. Pastikan wajah asli!';
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
        _guidanceMessage = '$qualityLevel Quality! (${(qualityScore * 100).toInt()}%)';
        _overlayColor = Colors.green;
        _isRegistrationComplete = true;
      });
      
      await _registerSingleTemplate(faceTemplate, imagePath);
      
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Gagal memproses foto: ${e.toString().replaceAll('Exception: ', '')}';
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
      _errorMessage = null;
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
      await _storageService.uploadFaceTemplate(
        processedFile,
        widget.organizationMemberId,
      );

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
                  const Text(
                    'Registrasi Selesai!',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      decoration: TextDecoration.none,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Pengenalan wajah dengan facial landmarks aktif',
                    textAlign: TextAlign.center,
                    style: TextStyle(
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
      setState(() {
        _errorMessage = 'Gagal menyimpan: ${e.toString().replaceAll('Exception: ', '')}';
        _currentStep = 'Gagal menyimpan';
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

      var enhanced = img.adjustColor(
        image,
        brightness: 1.1,
        contrast: 1.15,
      );

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
       // Regular concatenation for other formats
       final WriteBuffer allBytes = WriteBuffer();
       for (final Plane plane in image.planes) {
         allBytes.putUint8List(plane.bytes);
       }
       bytes = allBytes.done().buffer.asUint8List();
       bytesPerRow = image.planes.first.bytesPerRow;
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );
  }

  static final Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };


  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final double viewfinderWidth = screenSize.width * 0.7;
    final double viewfinderHeight = viewfinderWidth * 1.3;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Register Face',
          style: TextStyle(color: Colors.white),
        ),
      ),
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
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // 2. DARKENED OVERLAY WITH VIEWPORT CUTOUT
          if (_isCameraInitialized && _isModelInitialized)
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withOpacity(0.5),
                  BlendMode.srcOut,
                ),
                child: Stack(
                  children: [
                    Container(
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        backgroundBlendMode: BlendMode.dstOut,
                      ),
                    ),
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 200), // Lift viewfinder further up
                        width: viewfinderWidth,
                        height: viewfinderHeight,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(40),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 3. WHITE CORNER BRACKETS
          if (_isCameraInitialized && _isModelInitialized)
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 200), // Lift corners further up to match cutout
                width: viewfinderWidth,
                height: viewfinderHeight,
                child: Stack(
                  children: [
                    // Top Left
                    Positioned(
                      top: 0,
                      left: 0,
                      child: _buildCorner(0),
                    ),
                    // Top Right
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _buildCorner(1),
                    ),
                    // Bottom Left
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: _buildCorner(2),
                    ),
                    // Bottom Right
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: _buildCorner(3),
                    ),
                  ],
                ),
               ),
            ),

          // 4. PROGRESS CARD
          if (_isCameraInitialized && _isModelInitialized)
            Positioned(
              left: 20,
              right: 20,
              bottom: 30, // Positioned slightly lower
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF8938DF), // Light Purple from Dashboard
                      Color(0xFF4A1E79), // Dark Purple from Dashboard
                    ],
                  ),
                  borderRadius: BorderRadius.circular(36),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
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
                      _guidanceMessage.isNotEmpty ? _guidanceMessage : 'Scanning your face...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22, // Slightly larger like mockup
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _currentStep,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 32),
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
                        height: 7, // Thinner progress bar
                        width: double.infinity,
                        color: Colors.white.withOpacity(0.15),
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
                  color: Colors.red.withOpacity(0.95),
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
                color: Colors.black.withOpacity(0.7),
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
      case CaptureAngle.front: base = 0; break;
      case CaptureAngle.left: base = 33; break;
      case CaptureAngle.right: base = 66; break;
      default: return 100;
    }

    // Add small visual progress for validation success
    if (_isTakingPicture) return base + 30; // Almost done with step
    if (_consecutiveValidFrames > 0) return base + 15; // Validating
    
    return base + 5; // Started step
  }

  Widget _buildCorner(int position) {
    const double size = 48; // Larger corner symbols
    const double thickness = 5; // Bolder corners
    const double radius = 32; // Rounded corners match cutout

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          if (position == 0) // Top Left
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.white, width: thickness),
                  left: BorderSide(color: Colors.white, width: thickness),
                ),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(radius)),
              ),
            ),
          if (position == 1) // Top Right
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.white, width: thickness),
                  right: BorderSide(color: Colors.white, width: thickness),
                ),
                borderRadius: BorderRadius.only(topRight: Radius.circular(radius)),
              ),
            ),
          if (position == 2) // Bottom Left
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white, width: thickness),
                  left: BorderSide(color: Colors.white, width: thickness),
                ),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(radius)),
              ),
            ),
          if (position == 3) // Bottom Right
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white, width: thickness),
                  right: BorderSide(color: Colors.white, width: thickness),
                ),
                borderRadius: BorderRadius.only(bottomRight: Radius.circular(radius)),
              ),
            ),
        ],
      ),
    );
  }
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