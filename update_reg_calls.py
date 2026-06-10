import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'r', encoding='utf-8').read()

# Update processCameraFrame to use detectFacesForRegistration
content = content.replace('await _faceService.detectFacesFromInputImage(inputImage)', 'await _faceService.detectFacesForRegistration(inputImage)')

# Update extractFaceFeatures calls
content = re.sub(
    r'final faceTemplate = await _faceService\.extractFaceFeatures\(\s*imagePath,\s*allowSidePose: _currentAngle != CaptureAngle\.front,\s*\);',
    '''final faceTemplate = await _faceService.extractFaceFeatures(
        imagePath,
        allowSidePose: _currentAngle != CaptureAngle.front,
        forRegistration: true,
      );''', content
)

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'w', encoding='utf-8').write(content)
print("Updated registration page calls.")
