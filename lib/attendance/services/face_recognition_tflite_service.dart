// lib/services/face_recognition_tflite_service.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'isolate_inference_service.dart';
import '../../helpers/timezone_helper.dart';

class FaceRecognitionTFLiteService {
  late final FaceDetector _faceDetector;
  final IsolateInferenceService _inferenceService = IsolateInferenceService();
  bool _isInitialized = false;

  // W600K MBF optimized model config
  int inputSize = 160;
  int embeddingSize = 512;

  // ✅ OPTIMIZED: Adjusted Quality & Distance Thresholds for Long Range (~5m) & Fast Scanning
  static const double minFaceQualityScore = 0.50;
  static const double minEyeOpenProbability = 0.50;
  static const double maxHeadRotation = 45.0; // Allow side gaze up to 45 degrees

  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.01, // Detect tiny faces from ~5m distance
      ),
    );
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing Face Recognition Service ===');
      await _inferenceService.initialize();
      debugPrint(
        '✅ Face Recognition Service initialized (matching wajah project)',
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to initialize Face Recognition Service: $e');
      rethrow;
    }
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    return await detectFacesFromInputImage(inputImage);
  }

  Future<List<Face>> detectFacesFromInputImage(InputImage inputImage) async {
    return await _faceDetector.processImage(inputImage);
  }

  // ✅ IMPROVED: L2 Normalization Helper
  List<double> l2Normalize(List<double> vector) {
    if (vector.isEmpty) return [];
    double sum = 0.0;
    for (var x in vector) {
      sum += x * x;
    }
    final norm = sqrt(sum);
    if (norm == 0) return vector;
    return vector.map((x) => x / norm).toList();
  }

  // ✅ CALCULATE: Face Quality Score
  double calculateFaceQuality(Face face) {
    double qualityScore = 1.0;

    // Eye openness (40% weight)
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    final eyeScore = (leftEyeOpen + rightEyeOpen) / 2.0;
    qualityScore *= (0.6 + eyeScore * 0.4);

    // Head rotation (30% weight)
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();
    final rotationPenalty = (headY + headZ) / 100.0;
    qualityScore *= (1.0 - rotationPenalty.clamp(0.0, 0.3));

    // Face size (30% weight)
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final sizeScore = (faceArea / 100000.0).clamp(0.0, 1.0);
    qualityScore *= (0.7 + sizeScore * 0.3);

    return qualityScore.clamp(0.0, 1.0);
  }

  bool isValidFaceForRecognition(
    Face face, {
    bool allowSidePose = false,
    bool forRegistration = false,
  }) {
    // 1. Check eye openness (Only strictly enforce for registration)
    if (forRegistration) {
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;

      if (leftEyeOpen < minEyeOpenProbability ||
          rightEyeOpen < minEyeOpenProbability) {
        debugPrint(
          '❌ Face rejected: Eyes closed (L:${leftEyeOpen.toStringAsFixed(2)}, R:${rightEyeOpen.toStringAsFixed(2)}) < $minEyeOpenProbability',
        );
        return false;
      }
    }

    // 2. Check head rotation
    final headY = (face.headEulerAngleY ?? 0.0).abs();
    final headZ = (face.headEulerAngleZ ?? 0.0).abs();

    if (forRegistration && !allowSidePose) {
      if (headY > 20.0 || headZ > 20.0) {
        debugPrint(
          '❌ Face rejected: Bad Rotation (Y:${headY.toStringAsFixed(1)}, Z:${headZ.toStringAsFixed(1)}) > 20.0 for registration',
        );
        return false;
      }
    } else {
      // Lenient threshold for real-time scanning (up to 45 degrees)
      if (headY > 45.0 || headZ > 45.0) {
        debugPrint(
          '❌ Face rejected: Excessive Rotation (Y:${headY.toStringAsFixed(1)}, Z:${headZ.toStringAsFixed(1)}) > 45.0',
        );
        return false;
      }
    }

    // 3. Check face size (Lower limit 250 ~16x16px for long-range & fast recognition)
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    if (!forRegistration && faceArea < 250) {
      debugPrint('❌ Face REJECTED: Too far/small (Area: ${faceArea.toInt()} < 250)');
      return false;
    }

    // 4. Overall Quality Score (Lenient score 0.10 for attendance mode)
    final double currentMinQuality = forRegistration ? minFaceQualityScore : 0.10;
    final quality = calculateFaceQuality(face);
    if (quality < currentMinQuality) {
      debugPrint(
        '❌ Face REJECTED: Low quality (${(quality * 100).toInt()}%) < ${(currentMinQuality * 100).toInt()}%',
      );
      return false;
    }

    return true;
  }

  double _calculateIOU(Rect boxA, Rect boxB) {
    final double iLeft = max(boxA.left, boxB.left);
    final double iTop = max(boxA.top, boxB.top);
    final double iRight = min(boxA.right, boxB.right);
    final double iBottom = min(boxA.bottom, boxB.bottom);
    final double iW = max(0.0, iRight - iLeft);
    final double iH = max(0.0, iBottom - iTop);
    final double iArea = iW * iH;
    if (iArea <= 0) return 0.0;
    final double unionArea =
        boxA.width * boxA.height + boxB.width * boxB.height - iArea;
    if (unionArea <= 0) return 0.0;
    return iArea / unionArea;
  }

  Face _selectPrimaryFace(List<Face> faces) {
    if (faces.isEmpty) throw Exception('No face detected');
    if (faces.length == 1) return faces.first;

    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });

    final primaryFace = sorted.first;
    final primaryArea =
        primaryFace.boundingBox.width * primaryFace.boundingBox.height;

    final distinctFaces = <Face>[primaryFace];
    for (int i = 1; i < sorted.length; i++) {
      final face = sorted[i];
      final area = face.boundingBox.width * face.boundingBox.height;

      if (area < primaryArea * 0.20) continue;

      bool isOverlap = false;
      for (final selected in distinctFaces) {
        if (_calculateIOU(face.boundingBox, selected.boundingBox) > 0.35) {
          isOverlap = true;
          break;
        }
      }

      if (!isOverlap) {
        distinctFaces.add(face);
      }
    }

    if (distinctFaces.length > 1) {
      throw Exception('Multiple faces detected');
    }

    return primaryFace;
  }

  Future<Map<String, dynamic>> extractFaceFeatures(
    String imagePath, {
    bool allowSidePose = false,
    bool forRegistration = false,
  }) async {
    final faces = await detectFaces(imagePath);
    final face = _selectPrimaryFace(faces);

    if (!isValidFaceForRecognition(
      face,
      allowSidePose: allowSidePose,
      forRegistration: forRegistration,
    )) {
      throw Exception(
        'Face quality insufficient. Open eyes and look straight.',
      );
    }

    return buildTemplateFromFace(face, imagePath, allowSidePose: allowSidePose);
  }

  Future<Map<String, dynamic>> buildTemplateFromBytes(
    Uint8List imageBytes,
    int width,
    int height,
    int rotation,
    Face face, {
    bool allowSidePose = false,
    String? debugPath,
  }) async {
    if (!_isInitialized) await initialize();

    final landmarks = <String, dynamic>{};
    void addLandmark(FaceLandmarkType type, String key) {
      final l = face.landmarks[type];
      if (l != null) {
        landmarks[key] = {
          'x': l.position.x.toDouble(),
          'y': l.position.y.toDouble(),
        };
      }
    }

    // Add essential landmarks
    for (var t in [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.bottomMouth,
      FaceLandmarkType.leftMouth,
      FaceLandmarkType.rightMouth,
    ]) {
      addLandmark(t, t.toString().split('.').last);
    }

    final faceData = {
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
    };

    final response = await _inferenceService.processFaceFromBytes(
      imageBytes: imageBytes,
      width: width,
      height: height,
      rotation: rotation,
      faceData: faceData,
      allowSidePose: allowSidePose,
      debugPath: debugPath,
    );

    if (response.error != null) throw Exception(response.error);
    if (response.embedding == null) {
      throw Exception('Failed to generate embedding');
    }

    // ✅ CRITICAL: L2 Normalize embedding immediately
    final normalizedEmbedding = l2Normalize(response.embedding!);

    return _buildTemplate(
      face,
      normalizedEmbedding, // Use IS L2 Normalized
      landmarks,
      "stream_capture",
    );
  }

  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) await initialize();

    final landmarks = <String, dynamic>{};
    void addLandmark(FaceLandmarkType type, String key) {
      final l = face.landmarks[type];
      if (l != null) {
        landmarks[key] = {
          'x': l.position.x.toDouble(),
          'y': l.position.y.toDouble(),
        };
      }
    }

    addLandmark(FaceLandmarkType.leftEye, 'leftEye');
    addLandmark(FaceLandmarkType.rightEye, 'rightEye');
    addLandmark(FaceLandmarkType.noseBase, 'noseBase');
    addLandmark(FaceLandmarkType.bottomMouth, 'bottomMouth');
    addLandmark(FaceLandmarkType.leftMouth, 'leftMouth');
    addLandmark(FaceLandmarkType.rightMouth, 'rightMouth');

    final faceData = {
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
    };

    final response = await _inferenceService.processFace(
      imagePath: imagePath,
      faceData: faceData,
      allowSidePose: allowSidePose,
    );

    if (response.error != null) throw Exception(response.error);
    if (response.embedding == null) {
      throw Exception('Failed to generate embedding');
    }

    // ✅ CRITICAL: L2 Normalize embedding immediately
    final normalizedEmbedding = l2Normalize(response.embedding!);

    return _buildTemplate(face, normalizedEmbedding, landmarks, imagePath);
  }

  double _calculateIPD(Map<String, dynamic> landmarks) {
    if (landmarks['leftEye'] != null && landmarks['rightEye'] != null) {
      final leftEye = landmarks['leftEye'] as Map<String, dynamic>;
      final rightEye = landmarks['rightEye'] as Map<String, dynamic>;
      final dx = (rightEye['x'] as double) - (leftEye['x'] as double);
      final dy = (rightEye['y'] as double) - (leftEye['y'] as double);
      return sqrt(dx * dx + dy * dy);
    }
    return 0.0;
  }

  Map<String, dynamic> _calculateBiometricMetrics(
    Rect boundingBox,
    Map<String, dynamic> landmarks,
  ) {
    final ipd = _calculateIPD(landmarks);
    final faceWidth = boundingBox.width;
    final faceHeight = boundingBox.height;
    final aspectRatio = faceHeight > 0 ? faceWidth / faceHeight : 0.0;
    return {
      'interPupillaryDistance': ipd,
      'faceWidth': faceWidth,
      'faceHeight': faceHeight,
      'faceAspectRatio': aspectRatio,
      'faceShape': aspectRatio > 0.85
          ? 'round'
          : (aspectRatio < 0.75 ? 'long/oval' : 'oval'),
    };
  }

  Map<String, dynamic> _detectOcclusion(Face face) {
    final leftEye = face.leftEyeOpenProbability ?? 0.0;
    final rightEye = face.rightEyeOpenProbability ?? 0.0;
    bool isOccluded = (leftEye < 0.05 && rightEye < 0.05);
    return {'isOccluded': isOccluded, 'confidence': isOccluded ? 0.8 : 0.1};
  }

  Map<String, dynamic> _detectPassiveLiveness(Face face) {
    final leftEye = face.leftEyeOpenProbability ?? 0.0;
    final rightEye = face.rightEyeOpenProbability ?? 0.0;
    final eyeSymmetry = 1.0 - (leftEye - rightEye).abs();
    return {
      'isLive': eyeSymmetry > 0.5,
      'livenessScore': eyeSymmetry,
      'method': 'passive',
    };
  }

  Map<String, dynamic> _buildTemplate(
    Face face,
    List<double> embedding,
    Map<String, dynamic> landmarks,
    String imagePath,
  ) {
    final qualityScore = calculateFaceQuality(face);
    final biometricMetrics = _calculateBiometricMetrics(
      face.boundingBox,
      landmarks,
    );
    final livenessDetection = _detectPassiveLiveness(face);
    final occlusion = _detectOcclusion(face);

    return {
      'version': 5.0,
      'embedding': embedding,
      'embeddingSize': embedding.length,
      'qualityScore': qualityScore,
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'landmarks': landmarks,
      'biometricMetrics': biometricMetrics,
      'livenessDetection': livenessDetection,
      'qualityScores': {
        'leftEyeOpen': face.leftEyeOpenProbability ?? 0.0,
        'rightEyeOpen': face.rightEyeOpenProbability ?? 0.0,
      },
      'poseInformation': {
        'yaw': face.headEulerAngleY ?? 0.0,
        'roll': face.headEulerAngleZ ?? 0.0,
        'pitch': face.headEulerAngleX ?? 0.0,
      },
      'advancedAttributes': {'occlusion': occlusion},
      'captureMetadata': {
        'captureDate': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'captureDevice': 'Mobile Camera',
      },
    };
  }

  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    final embedding1 = List<double>.from(template1['embedding'] ?? []);
    final embedding2 = List<double>.from(template2['embedding'] ?? []);

    if (embedding1.isEmpty || embedding2.isEmpty) return -1.0;

    double dotProduct = 0.0;
    double norm1 = 0.0;
    double norm2 = 0.0;

    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
      norm1 += embedding1[i] * embedding1[i];
      norm2 += embedding2[i] * embedding2[i];
    }

    final mag = sqrt(norm1) * sqrt(norm2);
    if (mag == 0) return -1.0;

    return (dotProduct / mag).clamp(-1.0, 1.0);
  }

  double calculateSimilarity(List<double> e1, List<double> e2) {
    if (e1.isEmpty || e2.isEmpty) return -1.0;

    double dot = 0.0, n1 = 0.0, n2 = 0.0;
    for (int i = 0; i < e1.length; i++) {
      dot += e1[i] * e2[i];
      n1 += e1[i] * e1[i];
      n2 += e2[i] * e2[i];
    }
    final mag = sqrt(n1) * sqrt(n2);
    if (mag == 0) return -1.0;

    return (dot / mag).clamp(-1.0, 1.0);
  }

  Future<bool> validatePhotoQuality(String imagePath) async {
    final faces = await detectFaces(imagePath);
    final face = _selectPrimaryFace(faces);

    if (!isValidFaceForRecognition(face, allowSidePose: false)) {
      throw Exception('Face quality insufficient');
    }

    final imageFile = File(imagePath);
    final decoded = img.decodeImage(await imageFile.readAsBytes());
    if (decoded != null) {
      final faceArea = face.boundingBox.width * face.boundingBox.height;
      final imgArea = decoded.width * decoded.height;
      if (faceArea / imgArea < 0.05) throw Exception('Face too small');
    }
    return true;
  }

  Map<String, dynamic> getModelInfo() {
    return {'status': 'initialized', 'domain': 'Raw Cosine [-1,1]'};
  }

  void dispose() {
    _faceDetector.close();
    _inferenceService.dispose();
    _isInitialized = false;
  }
}
