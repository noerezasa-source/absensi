import re

content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'r', encoding='utf-8').read()

# Replace detectFacesForRegistration with detectFacesFromInputImage
content = content.replace('await _faceService.detectFacesForRegistration(inputImage)', 'await _faceService.detectFacesFromInputImage(inputImage)')

# Remove forRegistration: true,
content = content.replace('forRegistration: true,', '')

open('/home/the-ardyansa/Abensimassalv1/lib/attendance/screens/face_registration_page.dart', 'w', encoding='utf-8').write(content)
print("Registration page fixed.")
