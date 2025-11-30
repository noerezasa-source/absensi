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
  String _currentStep = 'Initializing model...';
  Timer? _detectionTimer;

  @override
  void initState() {
    super.initState();
    _initializeModel();
  }

  Future<void> _initializeModel() async {
    try {
      setState(() {
        _currentStep = 'Loading AI model...';
      });

      await _faceService.initialize();
      
      setState(() {
        _isModelInitialized = true;
        _currentStep = 'Model ready';
      });

      // Now initialize camera
      await _initializeCamera();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load AI model: $e';
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
          _currentStep = 'Position your face...';
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
      if (!_isProcessing && _isCameraInitialized && _isModelInitialized) {
        _detectAndCapture();
      }
    });
  }

  Future<void> _detectAndCapture() async {
    if (_cameraController == null || 
        !_cameraController!.value.isInitialized || 
        _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final image = await _cameraController!.takePicture();
      
      try {
        await _faceService.validatePhotoQuality(image.path);
        
        _detectionTimer?.cancel();
        
        await _registerFace(image.path);
      } catch (e) {
        await File(image.path).delete();
        setState(() {
          _currentStep = 'Position your face...';
        });
      }
    } catch (e) {
      setState(() {
        _currentStep = 'Position your face...';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _registerFace(String imagePath) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _currentStep = 'Face detected!';
    });

    try {
      final imageFile = File(imagePath);

      setState(() {
        _currentStep = 'Validating face quality...';
      });

      await _faceService.validatePhotoQuality(imagePath);

      setState(() {
        _currentStep = 'Extracting face features (AI)...';
      });

      // Extract face features using TFLite
      final faceTemplate = await _faceService.extractFaceFeatures(imagePath);
      
      debugPrint('Face template extracted:');
      debugPrint('- Version: ${faceTemplate['version']}');
      debugPrint('- Embedding size: ${faceTemplate['embeddingSize']}');

      setState(() {
        _currentStep = 'Processing image...';
      });

      final processedFile = await _processImage(imageFile);

      setState(() {
        _currentStep = 'Uploading face template...';
      });

      await _storageService.uploadFaceTemplate(
        processedFile,
        widget.organizationMemberId,
      );

      await imageFile.delete();
      if (processedFile.path != imageFile.path) {
        await processedFile.delete();
      }

      setState(() {
        _currentStep = 'Registering face template...';
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
                    'All Set!',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      decoration: TextDecoration.none,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Face recognition active\n(Powered by AI)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.grey[600],
                      letterSpacing: 0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) {
          Navigator.of(context).pop();
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _currentStep = 'Position your face...';
        _isLoading = false;
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

      final flipped = img.flipHorizontal(image);
      
      final resized = img.copyResize(
        flipped,
        width: 800,
        interpolation: img.Interpolation.average,
      );

      final compressedBytes = img.encodeJpg(resized, quality: 85);

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
          'Register Face (AI)',
          style: TextStyle(color: Colors.white),
        ),
      ),
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

          // Face overlay guide
          if (_isCameraInitialized && _isModelInitialized)
            Center(
              child: Container(
                width: 280,
                height: 350,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isLoading 
                        ? Colors.green 
                        : (_isProcessing ? Colors.blue : Colors.white),
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(200),
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
                      'Loading AI Model...',
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