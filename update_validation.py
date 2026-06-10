import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()

content = content.replace('bool isValidFaceForRecognition(Face face, {bool allowSidePose = false}) {', 'bool isValidFaceForRecognition(Face face, {bool allowSidePose = false, bool forRegistration = false}) {')

content = content.replace(
'''    if (faceArea < 12000) {
      debugPrint('❌ Face REJECTED: Too far/small (Area: ${faceArea.toInt()} < 12000)');
      return false;
    }''',
'''    if (!forRegistration && faceArea < 12000) {
      debugPrint('❌ Face REJECTED: Too far/small (Area: ${faceArea.toInt()} < 12000)');
      return false;
    }'''
)

content = content.replace(
'''    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose)) {''',
'''    if (!isValidFaceForRecognition(face, allowSidePose: allowSidePose, forRegistration: forRegistration)) {'''
)

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
print("Updated face validation for registration.")
