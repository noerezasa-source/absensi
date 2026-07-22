import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()

# Add registration detector
content = content.replace('late final FaceDetector _faceDetector;', 'late final FaceDetector _faceDetector;\n  late final FaceDetector _registrationDetector;')

# Update constructor
constructor_regex = r'FaceRecognitionTFLiteService\(\) \{[\s\S]*?\}'
new_constructor = '''FaceRecognitionTFLiteService() {
    // ✅ ATTENDANCE detector: strict to prevent false positives from background faces
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.15, // Must occupy >=15% of frame — blocks distant bystanders
      ),
    );

    // ✅ REGISTRATION detector: more permissive so the bracket shows during enrollment
    _registrationDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.05, // Detect even smaller faces so bracket is visible
      ),
    );
  }'''
content = re.sub(constructor_regex, new_constructor, content)

# Add detectFacesForRegistration method
method_regex = r'  Future<List<Face>> detectFacesFromInputImage\(InputImage inputImage\) async \{\s*return await _faceDetector\.processImage\(inputImage\);\s*\}'
new_method = '''  Future<List<Face>> detectFacesFromInputImage(InputImage inputImage) async {
    return await _faceDetector.processImage(inputImage);
  }

  /// Permissive detector — used for registration so the face bracket shows clearly
  Future<List<Face>> detectFacesForRegistration(InputImage inputImage) async {
    return await _registrationDetector.processImage(inputImage);
  }'''
content = re.sub(method_regex, new_method, content)

# Update extractFaceFeatures
content = re.sub(
    r'  Future<Map<String, dynamic>> extractFaceFeatures\(\s*String imagePath, \{\s*bool allowSidePose = false,\s*bool forRegistration = false,\s*\}?\) async \{\s*final inputImage = InputImage\.fromFilePath\(imagePath\);\s*final faces = await detectFaces\(imagePath\);',
    r'''  Future<Map<String, dynamic>> extractFaceFeatures(
    String imagePath, {
    bool allowSidePose = false,
    bool forRegistration = false, // ← use permissive detector during enrollment
  }) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    // Use permissive detector for registration so photos captured during enrollment
    // aren't rejected because the face is slightly small in the high-res photo.
    final faces = forRegistration
        ? await _registrationDetector.processImage(inputImage)
        : await detectFaces(imagePath);''', content
)
# Update dispose
content = content.replace('_faceDetector.close();\n        _inferenceService.dispose();', '_faceDetector.close();\n    _registrationDetector.close();\n    _inferenceService.dispose();')

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
print("Restored dual detectors.")
