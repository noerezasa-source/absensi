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

  // Model config
  static const int inputSize = 112; // MobileFaceNet standard
  static const int embeddingSize = 192; // Output embedding dimension
  
  FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );
  }

  /// Initialize TFLite model
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      debugPrint('=== Initializing TFLite Model ===');
      
      // Load model from assets
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobile_face_net.tflite',
        options: InterpreterOptions()
          ..threads = 4
          ..useNnApiForAndroid = true,
      );

      // Get input/output tensor info
      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      
      debugPrint('Input shape: $inputShape');
      debugPrint('Output shape: $outputShape');
      debugPrint('✅ TFLite model loaded successfully');
      
      _isInitialized = true;
    } catch (e) {
      debugPrint('!!! Failed to load TFLite model: $e');
      rethrow;
    }
  }

  /// Detect faces using ML Kit
  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);
    return faces;
  }

  /// Extract face features using TFLite
  Future<Map<String, dynamic>> extractFaceFeatures(String imagePath) async {
    if (!_isInitialized) {
      await initialize();
    }

    // 1. Detect face using ML Kit
    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    final face = faces.first;

    // 2. Load and preprocess image
    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    // 3. Crop face region with margin
    final faceImage = _cropFaceWithMargin(image, face.boundingBox);

    // 4. Get embedding from TFLite
    final embedding = await _getEmbedding(faceImage);

    // 5. Build template with embedding + metadata
    return _buildTemplate(face, embedding);
  }

  /// Build template from detected face in real-time (kiosk mode)
  Future<Map<String, dynamic>> buildTemplateFromFace(
    Face face,
    String imagePath,
  ) async {
    if (!_isInitialized) {
      await initialize();
    }

    // Load image
    final imageFile = File(imagePath);
    final imageBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    // Crop and get embedding
    final faceImage = _cropFaceWithMargin(image, face.boundingBox);
    final embedding = await _getEmbedding(faceImage);

    return _buildTemplate(face, embedding);
  }

  /// Crop face from image with 30% margin
  img.Image _cropFaceWithMargin(img.Image image, Rect boundingBox) {
    // Add 30% margin around face
    const margin = 0.3;
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

    // Crop face region
    final croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);
    
    // Resize to model input size
    return img.copyResize(
      croppedFace,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// Get face embedding from preprocessed face image
  Future<List<double>> _getEmbedding(img.Image faceImage) async {
    // Preprocess image to 4D array
    final input = _preprocessImage(faceImage);

    // Prepare output buffer - 2D array [1, 192]
    final output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));

    // Run inference
    _interpreter!.run(input, output);

    // Get embedding and normalize (L2 normalization)
    final embedding = List<double>.from(output[0]);
    return _normalizeEmbedding(embedding);
  }

  /// Preprocess image for TFLite model input
  /// Returns 4D array: [1, 112, 112, 3]
  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    final input = <List<List<List<double>>>>[];
    
    // Batch dimension (always 1)
    final batch = <List<List<double>>>[];
    
    // Height dimension (112 rows)
    for (int y = 0; y < inputSize; y++) {
      final row = <List<double>>[];
      
      // Width dimension (112 columns)
      for (int x = 0; x < inputSize; x++) {
        final pixel = image.getPixel(x, y);
        
        // RGB channels (3 values), normalized to [-1, 1]
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

  /// L2 normalize embedding vector
  List<double> _normalizeEmbedding(List<double> embedding) {
    double sumSquares = 0.0;
    for (var value in embedding) {
      sumSquares += value * value;
    }
    
    final magnitude = sqrt(sumSquares);
    
    if (magnitude < 1e-6) {
      return embedding; // Avoid division by zero
    }
    
    return embedding.map((value) => value / magnitude).toList();
  }

  /// Build face template with embedding and metadata
  Map<String, dynamic> _buildTemplate(Face face, List<double> embedding) {
    return {
      'version': 3, // TFLite version
      'embedding': embedding,
      'embeddingSize': embedding.length,
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

  /// Compare two face embeddings using cosine similarity
  /// Returns similarity score between 0.0 and 1.0
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

    // Calculate cosine similarity
    double dotProduct = 0.0;
    for (int i = 0; i < embedding1.length; i++) {
      dotProduct += embedding1[i] * embedding2[i];
    }

    // Since embeddings are already L2 normalized, cosine similarity = dot product
    // Convert from [-1, 1] to [0, 1]
    final similarity = (dotProduct + 1.0) / 2.0;
    
    return similarity.clamp(0.0, 1.0);
  }

  /// Validate photo quality before registration
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

      // Check eye openness
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
      
      if (leftEyeOpen < 0.5 || rightEyeOpen < 0.5) {
        throw Exception('Please open your eyes');
      }

      // Check head rotation
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      
      if (headY > 20.0 || headZ > 20.0) {
        throw Exception('Please face the camera directly');
      }

      // Check face size (at least 15% of image)
      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      final image = img.decodeImage(imageBytes);
      
      if (image != null) {
        final imageArea = image.width * image.height;
        final faceArea = face.boundingBox.width * face.boundingBox.height;
        final faceRatio = faceArea / imageArea;
        
        if (faceRatio < 0.15) {
          throw Exception('Face too small. Please move closer');
        }

        if (faceRatio > 0.8) {
          throw Exception('Face too close. Please move back');
        }
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  /// Get model info
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