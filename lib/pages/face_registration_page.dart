// lib/pages/face_registration_page.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import '../services/face_recognition_service.dart';
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
  final FaceRecognitionService _faceService = FaceRecognitionService();
  final BiometricService _biometricService = BiometricService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  String? _errorMessage;
  String _currentStep = 'Positioning face...';
  Timer? _detectionTimer;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
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
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
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
      if (!_isProcessing && _isCameraInitialized) {
        _detectAndCapture();
      }
    });
  }

  Future<void> _detectAndCapture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized || _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Capture image for detection
      final image = await _cameraController!.takePicture();
      
      // Try to validate face (this will throw if no face detected)
      try {
        await _faceService.validatePhotoQuality(image.path);
        
        // If validation passes, face is detected
        // Stop detection timer
        _detectionTimer?.cancel();
        
        // Register the face
        await _registerFace(image.path);
      } catch (e) {
        // No face detected or poor quality, delete temp image and continue
        await File(image.path).delete();
        setState(() {
          _currentStep = 'Positioning face...';
        });
      }
    } catch (e) {
      // Continue detecting
      setState(() {
        _currentStep = 'Positioning face...';
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

      // Validate photo quality
      await _faceService.validatePhotoQuality(imagePath);

      setState(() {
        _currentStep = 'Extracting face features...';
      });

      // Extract face features
      final faceTemplate = await _faceService.extractFaceFeatures(imagePath);

      setState(() {
        _currentStep = 'Processing image...';
      });

      // Compress and fix orientation before upload
      final processedFile = await _processImage(imageFile);

      setState(() {
        _currentStep = 'Uploading face template...';
      });

      // Upload to storage
      await _storageService.uploadFaceTemplate(
        processedFile,
        widget.organizationMemberId,
      );

      // Delete temporary files
      await imageFile.delete();
      if (processedFile.path != imageFile.path) {
        await processedFile.delete();
      }

      setState(() {
        _currentStep = 'Registering face template...';
      });

      // Save to database
      await _biometricService.registerFaceTemplate(
        organizationMemberId: widget.organizationMemberId,
        faceTemplate: faceTemplate,
      );

      if (mounted) {
        // Show success overlay in center
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
                  // Success icon with animation feel
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
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
                  // Title
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
                  // Subtitle
                  Text(
                    'Face recognition active',
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

        // Auto close after 1.5 seconds
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) {
          Navigator.of(context).pop(); // Close dialog
          Navigator.of(context).pop(true); // Close registration page
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _currentStep = 'Positioning face...';
        _isLoading = false;
      });
      
      // Restart detection
      _startFaceDetection();
    }
  }

  Future<File> _processImage(File imageFile) async {
    try {
      // Read image
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);
      
      if (image == null) {
        return imageFile;
      }

      // Fix orientation (front camera is mirrored)
      final flipped = img.flipHorizontal(image);
      
      // Resize to max 800px width while maintaining aspect ratio
      final resized = img.copyResize(
        flipped,
        width: 800,
        interpolation: img.Interpolation.average,
      );

      // Compress to JPEG with 85% quality
      final compressedBytes = img.encodeJpg(resized, quality: 85);

      // Save to temporary file
      final tempDir = await Directory.systemTemp.createTemp();
      final processedFile = File('${tempDir.path}/processed_face.jpg');
      await processedFile.writeAsBytes(compressedBytes);

      return processedFile;
    } catch (e) {
      // If processing fails, return original
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
          'Register Face',
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
          if (_isCameraInitialized)
            Center(
              child: Container(
                width: 280,
                height: 350,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isLoading ? Colors.green : (_isProcessing ? Colors.blue : Colors.white),
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(200),
                ),
              ),
            ),

          // Error message at top
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

          // Instructions at bottom
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Column(
              children: [
                if (_isLoading)
                  const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
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
                Text(
                  _currentStep,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    shadows: [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 8,
                      ),
                    ],
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