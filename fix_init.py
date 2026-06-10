import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'r', encoding='utf-8').read()

# Revert to creating its own instance
content = content.replace('late FaceRecognitionTFLiteService _faceService;', 'final FaceRecognitionTFLiteService _faceService = FaceRecognitionTFLiteService();')
content = content.replace('_faceService = await _biometricService.getFaceService();', 'await _faceService.initialize();')

# Restore the dispose method
content = content.replace('// Do NOT dispose _faceService since it\'s persistent\n    super.dispose();', '_faceService.dispose();\n    super.dispose();')

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'w', encoding='utf-8').write(content)
print("Reverted FaceRegistrationPage to use its own instance.")
