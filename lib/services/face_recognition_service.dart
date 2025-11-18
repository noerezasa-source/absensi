// lib/services/face_recognition_service.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:image/image.dart' as img;

class FaceRecognitionService {
  final FaceDetector _faceDetector = GoogleMlKit.vision.faceDetector(
    FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
    ),
  );

  // Deteksi wajah dari file gambar
  Future<List<Face>> detectFaces(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);
    return faces;
  }

  // Extract face features untuk template
  Future<Map<String, dynamic>> extractFaceFeatures(String imagePath) async {
    final faces = await detectFaces(imagePath);
    
    if (faces.isEmpty) {
      throw Exception('No face detected in the image');
    }

    if (faces.length > 1) {
      throw Exception('Multiple faces detected. Please use a single face photo');
    }

    final face = faces.first;
    
    // Extract landmarks dan kontur wajah
    final landmarks = <String, dynamic>{};
    
    // Left eye
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    if (leftEye != null) {
      landmarks['leftEye'] = {
        'x': leftEye.position.x,
        'y': leftEye.position.y,
      };
    }

    // Right eye
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    if (rightEye != null) {
      landmarks['rightEye'] = {
        'x': rightEye.position.x,
        'y': rightEye.position.y,
      };
    }

    // Nose
    final noseBase = face.landmarks[FaceLandmarkType.noseBase];
    if (noseBase != null) {
      landmarks['noseBase'] = {
        'x': noseBase.position.x,
        'y': noseBase.position.y,
      };
    }

    // Mouth
    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];
    if (leftMouth != null && rightMouth != null) {
      landmarks['leftMouth'] = {
        'x': leftMouth.position.x,
        'y': leftMouth.position.y,
      };
      landmarks['rightMouth'] = {
        'x': rightMouth.position.x,
        'y': rightMouth.position.y,
      };
    }

    // Bounding box
    final boundingBox = {
      'left': face.boundingBox.left,
      'top': face.boundingBox.top,
      'width': face.boundingBox.width,
      'height': face.boundingBox.height,
    };

    // Head rotation angles
    final headAngles = {
      'eulerY': face.headEulerAngleY ?? 0.0,
      'eulerZ': face.headEulerAngleZ ?? 0.0,
    };

    // Face quality scores
    final qualityScores = {
      'smilingProbability': face.smilingProbability ?? 0.0,
      'leftEyeOpenProbability': face.leftEyeOpenProbability ?? 0.0,
      'rightEyeOpenProbability': face.rightEyeOpenProbability ?? 0.0,
    };

    return {
      'landmarks': landmarks,
      'boundingBox': boundingBox,
      'headAngles': headAngles,
      'qualityScores': qualityScores,
      'trackingId': face.trackingId,
    };
  }

  // Membandingkan dua template wajah
  double compareFaces(
    Map<String, dynamic> template1,
    Map<String, dynamic> template2,
  ) {
    double totalScore = 0.0;
    int comparisonCount = 0;

    // Bandingkan landmarks
    final landmarks1 = template1['landmarks'] as Map<String, dynamic>;
    final landmarks2 = template2['landmarks'] as Map<String, dynamic>;

    for (var key in landmarks1.keys) {
      if (landmarks2.containsKey(key)) {
        final point1 = landmarks1[key] as Map<String, dynamic>;
        final point2 = landmarks2[key] as Map<String, dynamic>;

        final dx = (point1['x'] as num) - (point2['x'] as num);
        final dy = (point1['y'] as num) - (point2['y'] as num);
        final distance = (dx * dx + dy * dy).toDouble();

        // Normalisasi jarak (semakin kecil semakin mirip)
        final similarity = 1.0 / (1.0 + distance / 10000.0);
        totalScore += similarity;
        comparisonCount++;
      }
    }

    // Bandingkan head angles
    final angles1 = template1['headAngles'] as Map<String, dynamic>;
    final angles2 = template2['headAngles'] as Map<String, dynamic>;

    final angleDiffY = ((angles1['eulerY'] as num) - (angles2['eulerY'] as num)).abs();
    final angleDiffZ = ((angles1['eulerZ'] as num) - (angles2['eulerZ'] as num)).abs();
    
    final angleSimilarity = 1.0 - ((angleDiffY + angleDiffZ) / 180.0).clamp(0.0, 1.0);
    totalScore += angleSimilarity;
    comparisonCount++;

    return comparisonCount > 0 ? totalScore / comparisonCount : 0.0;
  }

  // Validasi kualitas foto untuk pendaftaran
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

      // Cek apakah mata terbuka
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.0;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.0;
      
      if (leftEyeOpen < 0.5 || rightEyeOpen < 0.5) {
        throw Exception('Please open your eyes');
      }

      // Cek rotasi kepala tidak terlalu miring
      final headY = (face.headEulerAngleY ?? 0.0).abs();
      final headZ = (face.headEulerAngleZ ?? 0.0).abs();
      
      if (headY > 15.0 || headZ > 15.0) {
        throw Exception('Please face the camera directly');
      }

      // Cek ukuran wajah cukup besar
      final faceSize = face.boundingBox.width * face.boundingBox.height;
      if (faceSize < 10000) {
        throw Exception('Face too small. Please move closer');
      }

      return true;
    } catch (e) {
      rethrow;
    }
  }

  // Compress dan resize image
  Future<Uint8List> compressImage(File imageFile, {int maxWidth = 800}) async {
    final imageBytes = await imageFile.readAsBytes();
    img.Image? image = img.decodeImage(imageBytes);
    
    if (image == null) {
      throw Exception('Failed to decode image');
    }

    // Resize jika terlalu besar
    if (image.width > maxWidth) {
      image = img.copyResize(image, width: maxWidth);
    }

    // Compress ke JPEG dengan quality 85
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  void dispose() {
    _faceDetector.close();
  }
}