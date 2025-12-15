// lib/pages/face_registration_page.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import '../services/face_recognition_tflite_service.dart';
import '../services/biometric_service.dart';
import '../services/supabase_storage_service.dart';

class FaceRegistrationPage extends StatefulWidget {
  final int organizationMemberId;

  const FaceRegistrationPage({
    super.key,
    required this.organizationMemberId,
  });

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

class _FaceRegistrationPageState extends State<FaceRegistrationPage> {
  CameraController? _cameraController;
  final FaceRecognitionTFLiteService _faceService = FaceRecognitionTFLiteService();
  final BiometricService _biometricService = BiometricService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isModelInitialized = false;
  String? _errorMessage;
  String _currentStep = 'Loading model...';
  String _guidanceMessage = '';
  Color _overlayColor = Colors.white;
  Timer? _detectionTimer;
  
  // ✅ NEW: Multi-template registration state
  int _currentPoseIndex = 0; // 0: front, 1: left, 2: right
  final List<Map<String, dynamic>> _capturedTemplates = [];
  final List<String> _capturedImagePaths = [];
  bool _isRegistrationComplete = false;

  @override
  void initState() {
    super.initState();
    _initializeModel();
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
      setState(() {
        _errorMessage = 'Failed to load model: $e';
        _currentStep = 'Model initialization failed';
      });
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
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _currentStep = 'Foto 1/3 - DEPAN';
          _guidanceMessage = 'Hadapkan wajah ke depan';
        });
        _startFaceDetection();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to initialize camera: $e';
      });
    }
  }

  void _startFaceDetection() {
    _detectionTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (!_isProcessing && 
          _isCameraInitialized && 
          _isModelInitialized && 
          !_isRegistrationComplete &&
          _currentPoseIndex < 3) {
        _detectAndValidatePose();
      }
    });
  }
  
  String _getPoseName(int index) {
    switch (index) {
      case 0: return 'depan';
      case 1: return 'samping kiri';
      case 2: return 'samping kanan';
      default: return 'depan';
    }
  }

  Future<void> _detectAndValidatePose() async {
    if (_cameraController == null || 
        !_cameraController!.value.isInitialized || 
        _isProcessing ||
        _currentPoseIndex >= 3) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final image = await _cameraController!.takePicture();
      
      try {
        final validationResult = await _validatePoseWithFeedback(
          image.path, 
          _currentPoseIndex,
        );
        
        if (validationResult['isValid'] == true) {
          // Capture this pose
          await _capturePose(image.path);
        } else {
          setState(() {
            _guidanceMessage = validationResult['message'] ?? 'Sesuaikan posisi';
            _overlayColor = Colors.orange;
            _currentStep = validationResult['message'] ?? 'Sesuaikan posisi';
          });
          await File(image.path).delete();
          
          Future.delayed(const Duration(milliseconds: 1500), () {
            if (mounted && !_isRegistrationComplete) {
              setState(() {
                _overlayColor = Colors.white;
              });
            }
          });
        }
      } catch (e) {
        await File(image.path).delete();
        setState(() {
          _guidanceMessage = e.toString().replaceAll('Exception: ', '');
          _overlayColor = Colors.red;
        });
        
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && !_isRegistrationComplete) {
            setState(() {
              _overlayColor = Colors.white;
            });
          }
        });
      }
    } catch (e) {
      setState(() {
        _currentStep = 'Sesuaikan posisi wajah';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<Map<String, dynamic>> _validatePoseWithFeedback(
    String imagePath, 
    int poseIndex,
  ) async {
    final faces = await _faceService.detectFaces(imagePath);
    
    if (faces.isEmpty) {
      return {
        'isValid': false,
        'message': 'Wajah tidak terdeteksi - mendekatlah',
      };
    }

    if (faces.length > 1) {
      return {
        'isValid': false,
        'message': 'Beberapa wajah terdeteksi - hanya Anda',
      };
    }

    final face = faces.first;

    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    
    if (leftEyeOpen < 0.3 || rightEyeOpen < 0.3) {
      return {
        'isValid': false,
        'message': 'Buka mata Anda',
      };
    }

    final headY = face.headEulerAngleY ?? 0.0; // Positive = right, Negative = left
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();
    
    // Validate pose based on current pose index
    if (poseIndex == 0) {
      // Front face: headY should be close to 0
      if (headY.abs() > 15.0) {
        final direction = headY > 0 ? 'kanan' : 'kiri';
        return {
          'isValid': false,
          'message': 'Hadapkan wajah ke depan - jangan miring $direction',
        };
      }
    } else if (poseIndex == 1) {
      // Left side: headY should be negative (turned left)
      // Range yang lebih longgar: -10 sampai -50 derajat (lebih mudah dicapai)
      if (headY > -10.0) {
        return {
          'isValid': false,
          'message': 'Putar kepala ke kiri perlahan',
        };
      }
      if (headY < -50.0) {
        return {
          'isValid': false,
          'message': 'Terlalu miring - sedikit luruskan',
        };
      }
      // Valid jika sudah masuk range
    } else if (poseIndex == 2) {
      // Right side: headY should be positive (turned right)
      // Range yang lebih longgar: 10 sampai 50 derajat
      if (headY < 10.0) {
        return {
          'isValid': false,
          'message': 'Putar kepala ke kanan perlahan',
        };
      }
      if (headY > 50.0) {
        return {
          'isValid': false,
          'message': 'Terlalu miring - sedikit luruskan',
        };
      }
      // Valid jika sudah masuk range
    }
    
    if (headZ > 20.0) {
      return {
        'isValid': false,
        'message': 'Jangan miringkan kepala ke samping',
      };
    }

    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image != null) {
      final imageArea = image.width * image.height;
      final faceArea = face.boundingBox.width * face.boundingBox.height;
      final faceRatio = faceArea / imageArea;
      
      if (faceRatio < 0.12) {
        return {
          'isValid': false,
          'message': 'Mendekatlah ke kamera',
        };
      }

      if (faceRatio > 0.85) {
        return {
          'isValid': false,
          'message': 'Terlalu dekat - mundur sedikit',
        };
      }
    }

    return {
      'isValid': true,
      'message': 'Sempurna! Memproses...',
    };
  }
  
  Future<void> _capturePose(String imagePath) async {
    try {
      setState(() {
        _overlayColor = Colors.green;
        _guidanceMessage = 'Foto ${_getPoseName(_currentPoseIndex)} berhasil!';
        _currentStep = 'Memproses foto ${_getPoseName(_currentPoseIndex)}...';
      });

      // Extract face features (allow side poses for multi-template registration)
      // poseIndex 0 = front (no side pose), 1 = left, 2 = right (both are side poses)
      final allowSidePose = _currentPoseIndex > 0;
      final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: allowSidePose,
      );
      
      // Store template and image path
      _capturedTemplates.add(faceTemplate);
      _capturedImagePaths.add(imagePath);
      
      debugPrint('✅ Captured pose $_currentPoseIndex (${_getPoseName(_currentPoseIndex)})');
      
      // Move to next pose
      _currentPoseIndex++;
      
      if (_currentPoseIndex < 3) {
        // Continue to next pose
        await Future.delayed(const Duration(milliseconds: 1500));
        
        setState(() {
          _overlayColor = Colors.blue;
          _guidanceMessage = 'Sekarang miringkan ke ${_getPoseName(_currentPoseIndex)}';
          _currentStep = 'Foto ${_currentPoseIndex}/3 - ${_getPoseName(_currentPoseIndex).toUpperCase()}';
        });
        
        await Future.delayed(const Duration(milliseconds: 1000));
      } else {
        // All poses captured, register multi-template
        _detectionTimer?.cancel();
        await _registerMultiTemplate();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Gagal memproses foto: ${e.toString().replaceAll('Exception: ', '')}';
        _overlayColor = Colors.red;
      });
      
      // Retry this pose
      await File(imagePath).delete();
      _capturedTemplates.removeLast();
      _capturedImagePaths.removeLast();
      _currentPoseIndex--;
    }
  }

  Future<void> _registerMultiTemplate() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _currentStep = 'Menyimpan 3 template...';
      _overlayColor = Colors.green;
      _isRegistrationComplete = true;
    });

    try {
      // Build multi-template from 3 captured templates
      final multiTemplate = _faceService.buildMultiTemplate(_capturedTemplates);
      
      debugPrint('Multi-template created:');
      debugPrint('- Version: ${multiTemplate['version']}');
      debugPrint('- Template count: ${multiTemplate['templateCount']}');
      debugPrint('- Embedding size: ${multiTemplate['embeddingSize']}');

      setState(() {
        _currentStep = 'Mengunggah foto...';
      });

      // Upload first image (front) as profile photo
      final frontImageFile = File(_capturedImagePaths[0]);
      final processedFile = await _processImage(frontImageFile);
      await _storageService.uploadFaceTemplate(
        processedFile,
        widget.organizationMemberId,
      );

      // Clean up image files
      for (var path in _capturedImagePaths) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      if (processedFile.path != frontImageFile.path) {
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
        faceTemplate: multiTemplate,
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
                    'Pengenalan wajah dengan 3 template aktif',
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
        _currentPoseIndex = 0;
        _capturedTemplates.clear();
        _capturedImagePaths.clear();
      });
      
      _startFaceDetection();
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

  @override
  void dispose() {
    _detectionTimer?.cancel();
    _cameraController?.dispose();
    _faceService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

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
          // ===== FULL CAMERA BACKGROUND (SAMA SEPERTI ATTENDANCE) =====
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

          // Face overlay guide
          if (_isCameraInitialized && _isModelInitialized)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress indicator
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(3, (index) {
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: index < _currentPoseIndex
                                ? Colors.green
                                : index == _currentPoseIndex
                                    ? Colors.blue
                                    : Colors.grey,
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 20),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 280,
                    height: 350,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _isLoading 
                            ? Colors.green 
                            : _overlayColor,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(200),
                    ),
                  ),
                ],
              ),
            ),

          // Guidance message overlay
          if (_guidanceMessage.isNotEmpty && !_isLoading)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: _overlayColor == Colors.red 
                      ? Colors.red.withValues(alpha: 0.9)
                      : _overlayColor == Colors.orange
                          ? Colors.orange.withValues(alpha: 0.9)
                          : Colors.blue.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _overlayColor == Colors.red 
                          ? Icons.error_outline
                          : _overlayColor == Colors.orange
                              ? Icons.warning_amber
                              : Icons.face,
                      color: Colors.white,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _guidanceMessage,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Model status indicator
          if (!_isModelInitialized)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Loading Model...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Error message
          if (_errorMessage != null)
            Positioned(
              top: 50,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Instructions
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Column(
              children: [
                if (_isLoading)
                  const CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  )
                else
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isProcessing ? Colors.blue : Colors.white,
                    ),
                  ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _currentStep,
                    textAlign: TextAlign.center,
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
        ],
      ),
    );
  }
}