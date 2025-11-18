import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import '../services/face_recognition_service.dart';
import '../services/biometric_service.dart';
import '../services/attendance_service.dart';
import '../services/supabase_storage_service.dart';

class FaceAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final String attendanceType; // 'check_in' atau 'check_out'

  const FaceAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.attendanceType,
  });

  @override
  State<FaceAttendancePage> createState() => _FaceAttendancePageState();
}

class _FaceAttendancePageState extends State<FaceAttendancePage> {
  CameraController? _cameraController;
  final FaceRecognitionService _faceService = FaceRecognitionService();
  final BiometricService _biometricService = BiometricService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();

  bool _isLoading = false;
  bool _isCameraInitialized = false;
  bool _isProcessing = false; // Prevent multiple scans
  String? _errorMessage;
  String _currentStep = 'Position your face in the frame';
  Position? _currentPosition;
  
  Timer? _autoScanTimer;
  int _countdown = 3; // Countdown 3 detik
  bool _countdownStarted = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _getCurrentLocation();
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
        
        // Start auto scan after camera initialized
        _startAutoScan();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to initialize camera: $e';
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return;
      }

      _currentPosition = await Geolocator.getCurrentPosition();
    } catch (e) {
      print('Failed to get location: $e');
    }
  }

  void _startAutoScan() {
    if (_isProcessing || !_isCameraInitialized) return;

    setState(() {
      _countdownStarted = true;
      _countdown = 3;
      _currentStep = 'Get ready... $_countdown';
    });

    _autoScanTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _countdown--;
        if (_countdown > 0) {
          _currentStep = 'Get ready... $_countdown';
        }
      });

      if (_countdown <= 0) {
        timer.cancel();
        _captureAndVerify();
      }
    });
  }

  void _cancelAutoScan() {
    _autoScanTimer?.cancel();
    setState(() {
      _countdownStarted = false;
      _currentStep = 'Position your face in the frame';
    });
  }

  Future<void> _captureAndVerify() async {
    if (_cameraController == null || 
        !_cameraController!.value.isInitialized || 
        _isProcessing) {
      return;
    }

    setState(() {
      _isLoading = true;
      _isProcessing = true;
      _errorMessage = null;
      _currentStep = 'Capturing photo...';
    });

    try {
      // Capture image
      final image = await _cameraController!.takePicture();
      final imageFile = File(image.path);

      setState(() {
        _currentStep = 'Validating face quality...';
      });

      // Validate photo quality
      await _faceService.validatePhotoQuality(image.path);

      setState(() {
        _currentStep = 'Extracting face features...';
      });

      // Extract face features from captured image
      final capturedTemplate = await _faceService.extractFaceFeatures(image.path);

      setState(() {
        _currentStep = 'Verifying identity...';
      });

      // Get registered face template
      final registeredBiometric = await _biometricService.getActiveFaceTemplate(
        widget.organizationMemberId,
      );

      if (registeredBiometric == null) {
        throw Exception('No face template registered. Please register your face first.');
      }

      // Parse registered template
      final registeredTemplate = jsonDecode(registeredBiometric.templateData);

      // Compare faces
      final similarity = _faceService.compareFaces(
        capturedTemplate,
        registeredTemplate,
      );

      // Threshold untuk verifikasi (0.75 = 75% similarity)
      if (similarity < 0.75) {
        throw Exception('Face verification failed. Similarity: ${(similarity * 100).toStringAsFixed(1)}%');
      }

      setState(() {
        _currentStep = 'Uploading photo...';
      });

      // Upload attendance photo
      final photoUrl = await _storageService.uploadAttendancePhoto(
        imageFile,
        widget.organizationMemberId,
        widget.attendanceType,
      );

      setState(() {
        _currentStep = 'Recording attendance...';
      });

      // Prepare location data
      Map<String, dynamic>? locationData;
      if (_currentPosition != null) {
        locationData = {
          'latitude': _currentPosition!.latitude,
          'longitude': _currentPosition!.longitude,
          'accuracy': _currentPosition!.accuracy,
        };
      }

      // Record attendance
      if (widget.attendanceType == 'check_in') {
        await _attendanceService.checkIn(
          organizationMemberId: widget.organizationMemberId,
          photoUrl: photoUrl,
          method: 'face_recognition',
          location: locationData,
        );
      } else {
        await _attendanceService.checkOut(
          organizationMemberId: widget.organizationMemberId,
          photoUrl: photoUrl,
          method: 'face_recognition',
          location: locationData,
        );
      }

      // Update last used timestamp
      await _biometricService.updateLastUsed(registeredBiometric.id!);

      if (mounted) {
        // Show success dialog
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 30,
                ),
                const SizedBox(width: 12),
                Text(widget.attendanceType == 'check_in' 
                    ? 'Check In Success!' 
                    : 'Check Out Success!'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.attendanceType == 'check_in'
                      ? 'You have successfully checked in.'
                      : 'You have successfully checked out.',
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.verified_user, color: Colors.green, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Match: ${(similarity * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_currentPosition != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.location_on, size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Location recorded',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(); // Close dialog
                  Navigator.of(context).pop(true); // Close attendance page
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _currentStep = 'Position your face in the frame';
        _isProcessing = false;
      });

      // Auto retry after 3 seconds
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !_isProcessing) {
          setState(() {
            _errorMessage = null;
          });
          _startAutoScan();
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
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
        title: Text(
          widget.attendanceType == 'check_in' ? 'Check In' : 'Check Out',
          style: const TextStyle(color: Colors.white),
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

          // Face overlay guide with countdown
          if (_isCameraInitialized)
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Border
                  Container(
                    width: 280,
                    height: 350,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _isLoading 
                            ? Colors.blue 
                            : (_errorMessage != null 
                                ? Colors.red 
                                : Colors.white),
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(200),
                    ),
                  ),
                  // Countdown number
                  if (_countdownStarted && _countdown > 0 && !_isLoading)
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '$_countdown',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 60,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // Instructions
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    _currentStep,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '• Face the camera directly\n• Ensure good lighting\n• Keep your face in the frame',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  if (_countdownStarted && !_isLoading) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _cancelAutoScan,
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      child: const Text(
                        'Cancel Auto Scan',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Error message
          if (_errorMessage != null)
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
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
                    const SizedBox(height: 8),
                    const Text(
                      'Retrying in 3 seconds...',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Loading indicator
          if (_isLoading)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Processing...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Manual capture button (optional, if needed)
          if (!_isLoading && !_countdownStarted && _errorMessage == null)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _startAutoScan,
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                          color: widget.attendanceType == 'check_in'
                              ? Colors.green.withOpacity(0.5)
                              : Colors.red.withOpacity(0.5),
                        ),
                        child: Icon(
                          widget.attendanceType == 'check_in'
                              ? Icons.login
                              : Icons.logout,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Tap to Start',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}