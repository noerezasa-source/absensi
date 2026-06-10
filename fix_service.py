import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()

# Replace variables
content = content.replace('late final FaceDetector _faceDetector;\n  late final FaceDetector _registrationDetector;', 'late final FaceDetector _faceDetector;')
content = content.replace('late final FaceDetector _registrationDetector;', '')

# Replace constructor
constructor_regex = r'FaceRecognitionTFLiteService\(\) \{[\s\S]*?\}'
new_constructor = '''FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
  }'''
content = re.sub(constructor_regex, new_constructor, content)

# Replace detectFacesFromInputImage and detectFacesForRegistration
method_regex = r'  Future<List<Face>> detectFacesFromInputImage\(InputImage inputImage\) async \{[\s\S]*?\}'
new_method = '''  Future<List<Face>> detectFacesFromInputImage(InputImage inputImage) async {
    return await _faceDetector.processImage(inputImage);
  }'''
content = re.sub(method_regex, new_method, content)

# Remove detectFacesForRegistration
content = re.sub(r'  /// Permissive detector — used for registration so the face bracket shows clearly\n  Future<List<Face>> detectFacesForRegistration\(InputImage inputImage\) async \{\s*return await _registrationDetector\.processImage\(inputImage\);\s*\}', '', content)

# Fix extractFaceFeatures
content = re.sub(
    r'final faces = forRegistration\s*\?\s*await _registrationDetector\.processImage\(inputImage\)\s*:\s*await detectFaces\(imagePath\);',
    'final faces = await detectFaces(imagePath);', content
)

# Fix dispose
content = content.replace('_faceDetector.close();\n    _registrationDetector.close();\n    _inferenceService.dispose();', '_faceDetector.close();\n    _inferenceService.dispose();')

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
print("Service cleaned up to single detector.")
