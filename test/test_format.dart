import 'package:google_mlkit_commons/google_mlkit_commons.dart';

void main() {
  for (var val in InputImageFormat.values) {
    print('Format: ${val.name}, rawValue: ${val.rawValue}');
  }
}
