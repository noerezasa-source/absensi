import 'package:absensimassal/services/objectbox_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:absensi/services/objectbox_service.dart';
import 'package:absensi/models/karyawan_wajah.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ObjectBoxService().init();
  
  // Dump before
  print('--- BEFORE PURGE ---');
  ObjectBoxService().dumpAllRegisteredFaces();

  final all = ObjectBoxService().box.getAll();
  for (var face in all) {
    final name = face.namaLengkap.toLowerCase();
    if (name.contains('akwwan') || name.contains('kahfi') || name.contains('reza') || name.contains('rafa')) {
      final emb = face.faceEmbedding;
      final snippet = emb != null && emb.length >= 5 ? emb.sublist(0, 5).toString() : 'null';
      print('Name: ${face.namaLengkap}, Emb: $snippet');
    }
  }

  print('\nPurging all local objectbox data to force fresh sync...');
  ObjectBoxService().clearAllData();
  
  print('--- AFTER PURGE ---');
  ObjectBoxService().dumpAllRegisteredFaces();
}
