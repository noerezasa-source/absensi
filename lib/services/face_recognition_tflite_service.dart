// lib/services/face_recognition_tflite_service.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceRecognitionTFLiteService {
  late final FaceDetector _faceDetector;
  Interpreter? _interpreter;
  bool _isInitialized = false;

  // Model config - MobileFaceNet (optimized for mobile/offline)
  int inputSize = 112; // MobileFaceNet uses 112x112
  int embeddingSize = 192; // MobileFaceNet produces 192-dim embeddings
  
  // ✅ IMPROVED: Stricter quality thresholds
  static const double minFaceQualityScore = 0.7;
  static const double minEyeOpenProbability = 0.5;
  static const double maxHeadRotation = 15.0;
  
  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15, // ✅ Increased for better quality
      ),
    );
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing TFLite Model ===');
      
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobile_face_net.tflite',
        options: InterpreterOptions()
          ..threads = 4
          ..useNnApiForAndroid = true,
      );

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      
      // Update actual model dimensions
      if (inputShape.length >= 3) {
        inputSize = inputShape[1]; // Typically [1, 160, 160, 3] or [1, 112, 112, 3]
      }
      if (outputShape.length >= 2) {
        embeddingSize = outputShape[1]; // Typically [1, 512] or [1, 192]
      }
      
      debugPrint('Input shape: $inputShape (using inputSize: $inputSize)');
      debugPrint('Output shape: $outputShape (using embeddingSize: $embeddingSize)');
      debugPrint('✅ TFLite model (mobile_face_net.tflite) loaded successfully');
      
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to load TFLite model: $e');
      rethrow;
    }
  }

  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);
    return faces;
  }

  // ✅ NEW: Calculate face quality score
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
    final rotationPenalty = (headY + headZ) / 100.0; // normalize
    qualityScore *= (1.0 - rotationPenalty.clamp(0.0, 0.3));
    
    // Face size (30% weight) - larger faces are better
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    final sizeScore = (faceArea / 100000.0).clamp(0.0, 1.0);
    qualityScore *= (0.7 + sizeScore * 0.3);
    
    return qualityScore.clamp(0.0, 1.0);
  }

  // ✅ IMPROVED: Filter faces by quality before processing
  bool isValidFaceForRecognition(Face face, {bool allowSidePose = false}) {
    // Check eye openness
    final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
    final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
    if (leftEyeOpen < minEyeOpenProbability || rightEyeOpen < minEyeOpenProbability) {
      debugPrint('❌ Face rejected: Eyes not open enough');
      return false;
    }
    
    // Check head rotation (skip for side poses in multi-template registration)
    if (!allowSidePose) {
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      if (headY > maxHeadRotation || headZ > maxHeadRotation) {
        debugPrint('❌ Face rejected: Head rotation too large');
        return false;
      }
    } else {
      // For side poses, only check Z rotation (no tilting), allow Y rotation up to 50 degrees
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      if (headZ > maxHeadRotation) {
        debugPrint('❌ Face rejected: Head tilt too large (Z: ${headZ.toStringAsFixed(1)}°)');
        return false;
      }
      if (headY > 50.0) {
        debugPrint('❌ Face rejected: Head rotation too extreme (Y: ${headY.toStringAsFixed(1)}°)');
        return false;
      }
      debugPrint('✅ Side pose accepted: headY=${headY.toStringAsFixed(1)}°, headZ=${headZ.toStringAsFixed(1)}°');
    }
    
    // Check face size
    final faceArea = face.boundingBox.width * face.boundingBox.height;
    if (faceArea < 8000) { // Minimum face area
      debugPrint('❌ Face rejected: Face too small');
      return false;
    }
    
    // Calculate overall quality (relaxed for side poses)
    final qualityScore = calculateFaceQuality(face);
    final minQuality = allowSidePose ? (minFaceQualityScore * 0.85) : minFaceQualityScore;
    if (qualityScore < minQuality) {
      debugPrint('❌ Face rejected: Quality score too low (${qualityScore.toStringAsFixed(2)})');
      return false;
    }
    
    debugPrint('✅ Face quality: ${qualityScore.toStringAsFixed(2)}');
    return true;
  }

  Future<Map<String, dynamic>> extractFaceFeatures(
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    final face = faces.first;
    
    // ✅ IMPROVED: Validate face quality (allow side poses for multi-template)
    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose)) {
      throw Exception('Face quality insufficient. Please ensure good lighting${allowSidePose ? '' : ' and look straight at camera'}');
    }

    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    final enhancedImage = _enhanceImageForLowLight(image);
    final alignedImage = _alignFaceByEyes(enhancedImage, face);
    final faceImage = _cropFaceWithMargin(alignedImage, face.boundingBox);
    final embedding = await _getEmbedding(faceImage);

    return _buildTemplate(face, embedding);
  }

  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath, {
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    // ✅ IMPROVED: Validate face quality before processing
    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose)) {
      throw Exception('Face quality insufficient');
    }

    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    final enhancedImage = _enhanceImageForLowLight(image);
    final alignedImage = _alignFaceByEyes(enhancedImage, face);
    final faceImage = _cropFaceWithMargin(alignedImage, face.boundingBox);
    final embedding = await _getEmbedding(faceImage);

    return _buildTemplate(face, embedding);
  }

  /// Enhance image for better recognition quality (consistent with registration)
  img.Image _enhanceImageForLowLight(img.Image image) {
    // ✅ IMPROVED: Apply consistent enhancement for all images (same as registration)
    // This ensures attendance photos have same quality as registration photos
    return img.adjustColor(
      image,
      brightness: 1.1,   // Slight brightness boost for better visibility
      contrast: 1.15,    // Increased contrast for better feature extraction
      saturation: 1.05,  // Slight saturation boost
      gamma: 1.1,        // Gamma correction for better exposure balance
    );
  }

  /// Align face by rotating to make eyes horizontal
  /// This improves recognition accuracy by ensuring consistent face orientation
  img.Image _alignFaceByEyes(img.Image image, Face face) {
    try {
      final leftEye = face.landmarks[FaceLandmarkType.leftEye];
      final rightEye = face.landmarks[FaceLandmarkType.rightEye];
      
      if (leftEye == null || rightEye == null) {
        return image; // Can't align without eye landmarks
      }
      
      // Calculate angle between eyes
      final leftEyePos = leftEye.position;
      final rightEyePos = rightEye.position;
      
      final dx = rightEyePos.x - leftEyePos.x;
      final dy = rightEyePos.y - leftEyePos.y;
      
      // Only rotate if angle is significant (>2 degrees)
      final angleRad = atan2(dy, dx);
      final angleDeg = angleRad * 180 / pi;
      
      if (angleDeg.abs() > 2.0) {
        // Rotate image to align eyes horizontally
        return img.copyRotate(image, angle: -angleDeg, interpolation: img.Interpolation.cubic);
      }
      
      return image;
    } catch (e) {
      debugPrint('⚠️ Face alignment failed: $e');
      return image; // Return original if alignment fails
    }
  }

  img.Image _cropFaceWithMargin(img.Image image, Rect boundingBox) {
    // ✅ IMPROVED: Slightly larger margin for better context
    const margin = 0.35;
    final marginW = boundingBox.width * margin;
    final marginH = boundingBox.height * margin;

    final x = max(0, (boundingBox.left - marginW).toInt());
    final y = max(0, (boundingBox.top - marginH).toInt());
    final w = min(
      image.width - x,
      (boundingBox.width + 2 * marginW).toInt(),
    );
    final h = min(
      image.height - y,
      (boundingBox.height + 2 * marginH).toInt(),
    );

    final croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);
    
    // ✅ IMPROVED: Use lanczos for better quality
    return img.copyResize(
      croppedFace,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.cubic,
    );
  }

  Future<List<double>> _getEmbedding(img.Image faceImage) async {
    final input = _preprocessImage(faceImage);
    final output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));

    _interpreter!.run(input, output);

    final embedding = List<double>.from(output[0]);
    return _normalizeEmbedding(embedding);
  }

  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    final input = <List<List<List<double>>>>[];
    final batch = <List<List<double>>>[];
    
    for (int y = 0; y < inputSize; y++) {
      final row = <List<double>>[];
      
      for (int x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);
        
        // Normalize to [-1, 1]
        row.add([
          (pixel.r / 127.5) - 1.0,
          (pixel.g / 127.5) - 1.0,
          (pixel.b / 127.5) - 1.0,
        ]);
      }
      
      batch.add(row);
    }
    
    input.add(batch);
    return input;
  }

  List<double> _normalizeEmbedding(List<double> embedding) {
    double sumSquares = 0.0;
    for (var value in embedding) {
      sumSquares += value * value;
    }
    
    final magnitude = sqrt(sumSquares);
    
    if (magnitude < 1e-6) {
      return embedding;
    }
    
    return embedding.map((value) => value / magnitude).toList();
  }

  Map<String, dynamic> _buildTemplate(Face face, List<double> embedding) {
    final qualityScore = calculateFaceQuality(face);
    
    return {
      'version': 3,
      'embedding': embedding,
      'embeddingSize': embedding.length,
      'qualityScore': qualityScore, // ✅ NEW: Store quality score
      'boundingBox': {
        'left': face.boundingBox.left,
        'top': face.boundingBox.top,
        'width': face.boundingBox.width,
        'height': face.boundingBox.height,
      },
      'qualityScores': {
        'leftEyeOpen': face.leftEyeOpenProbability ?? 0.0,
        'rightEyeOpen': face.rightEyeOpenProbability ?? 0.0,
        'smiling': face.smilingProbability ?? 0.0,
      },
      'headAngles': {
        'eulerY': face.headEulerAngleY ?? 0.0,
        'eulerZ': face.headEulerAngleZ ?? 0.0,
      },
    };
  }

  // ✅ NEW: Build multi-template with 3 poses (front, left, right)
  Map<String, dynamic> buildMultiTemplate(List<Map<String, dynamic>> templates) {
    if (templates.length != 3) {
      throw Exception('Multi-template requires exactly 3 templates (front, left, right)');
    }

    return {
      'version': 4, // Version 4 for multi-template
      'templates': templates,
      'templateCount': templates.length,
      'embeddingSize': templates.first['embeddingSize'] ?? 192,
    };
  }

  // ✅ IMPROVED: More robust comparison with quality weighting and better normalization
  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    final embedding1 = List<double>.from(template1['embedding'] ?? []);
    final embedding2 = List<double>.from(template2['embedding'] ?? []);

    if (embedding1.isEmpty || embedding2.isEmpty) {
      return 0.0;
    }

    if (embedding1.length != embedding2.length) {
      debugPrint('!!! Embedding size mismatch: ${embedding1.length} vs ${embedding2.length}');
      return 0.0;
    }

    // Calculate cosine similarity (embeddings are already normalized)
    double dotProduct = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
    }

    // Cosine similarity is already in range [-1, 1], normalize to [0, 1]
    final cosineSimilarity = dotProduct.clamp(-1.0, 1.0);
    final similarity = (cosineSimilarity + 1.0) / 2.0;
    
    // ✅ IMPROVED: Quality weighting with better boost for high quality matches
    // ✅ REMOVED QUALITY BOOST: Quality boost was causing false positives
    // Use raw similarity to prevent multiple people matching with high scores
    // Quality is still used for validation, but not for boosting similarity
    // This ensures only the truly best match is selected
    
    return similarity;
  }

  Future<bool> validatePhotoQuality(String imagePath) async {
    try {
      final faces = await detectFaces(imagePath);
      
      if (faces.isEmpty) {
        throw Exception('No face detected');
      }

      if (faces.length > 1) {
        throw Exception('Multiple faces detected');
      }

      final face = faces.first;

      // ✅ Use the new validation method
      if (!isValidFaceForRecognition(face, allowSidePose: false)) {
        final qualityScore = calculateFaceQuality(face);
        throw Exception('Face quality insufficient (score: ${qualityScore.toStringAsFixed(2)})');
      }

      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);
      
      if (image != null) {
        final imageArea = image.width * image.height;
        final faceArea = face.boundingBox.width * face.boundingBox.height;
        final faceRatio = faceArea / imageArea;
        
        if (faceRatio < 0.15) { // ✅ Slightly increased minimum
          throw Exception('Face too small. Please move closer');
        }

        if (faceRatio > 0.80) {
          throw Exception('Face too close. Please move back');
        }
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  Map<String, dynamic> getModelInfo() {
    if (!_isInitialized || _interpreter == null) {
      return {'status': 'not_initialized'};
    }

    return {
      'status': 'initialized',
      'inputSize': inputSize,
      'embeddingSize': embeddingSize,
      'inputShape': _interpreter!.getInputTensor(0).shape,
      'outputShape': _interpreter!.getOutputTensor(0).shape,
    };
  }

  void dispose() {
    _faceDetector.close();
    _interpreter?.close();
    _isInitialized = false;
    debugPrint('FaceRecognitionTFLiteService disposed');
  }
}