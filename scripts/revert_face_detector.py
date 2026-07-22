import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()

# Replace the two detectors with one
content = re.sub(r'late final FaceDetector _faceDetector;.*?\n.*?late final FaceDetector _registrationDetector;.*?\n', 
                 'late final FaceDetector _faceDetector;\n', content)

# In constructor, replace the initialization
constructor_regex = r'FaceRecognitionTFLiteService\(\) \{[\s\S]*?\}'
new_constructor = '''FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.1, // Middle ground: 0.1 allows registration but still blocks some distant faces
      ),
    );
  }'''
content = re.sub(constructor_regex, new_constructor, content)

# Remove detectFacesForRegistration
content = re.sub(r'  /// Permissive detector[\s\S]*?\}\n', '', content)

# Update extractFaceFeatures
content = re.sub(r'final faces = forRegistration\s*\?\s*await _registrationDetector\.processImage\(inputImage\)\s*:\s*await detectFaces\(imagePath\);', 
                 'final faces = await detectFaces(imagePath);', content)

# Update dispose
content = re.sub(r'_registrationDetector\.close\(\);\s*\n', '', content)

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
print("Reverted to single FaceDetector.")
