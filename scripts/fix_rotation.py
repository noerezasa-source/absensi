import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'r', encoding='utf-8').read()

# Fix rotationCompensation null check
content = content.replace(
'''      var rotationCompensation =
          _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;''', 
'''      var rotationCompensation =
          _orientations[_cameraController!.value.deviceOrientation] ?? 0;'''
)

content = content.replace(
'''      var rotationCompensation = _orientations[_cameraController!.value.deviceOrientation];
      if (rotationCompensation == null) return null;''',
'''      var rotationCompensation = _orientations[_cameraController!.value.deviceOrientation] ?? 0;'''
)


open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'w', encoding='utf-8').write(content)
print("Rotation compensation fixed.")
