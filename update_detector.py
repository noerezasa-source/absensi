import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()

constructor_regex = r'FaceRecognitionTFLiteService\(\) \{[\s\S]*?\}'
new_constructor = '''FaceRecognitionTFLiteService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.05, // 🔥 VERY PERMISSIVE: Detect faces even if they are small in the frame
      ),
    );
  }'''
content = re.sub(constructor_regex, new_constructor, content)

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
print("Detector updated with minFaceSize: 0.05")
