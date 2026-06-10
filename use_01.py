import re
content = open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'r', encoding='utf-8').read()
content = content.replace('minFaceSize: 0.05,', 'minFaceSize: 0.1,')
open('/home/the-ardyansa/Abensimassalv1/lib/attendance/services/face_recognition_tflite_service.dart', 'w', encoding='utf-8').write(content)
