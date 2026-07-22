import 'package:supabase/supabase.dart';
import 'dart:io';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
  );

  print('=== OPTIMIZED SCAN: FINDING NEWEST FRONT FACE PHOTO PER MEMBER ===');

  final sqlStatements = <String>[];
  sqlStatements.add('-- ============================================================');
  sqlStatements.add('-- OPTIMIZED BACKFILL: LINK LATEST FRONT FACE PHOTOS TO USER PROFILES');
  sqlStatements.add('-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run');
  sqlStatements.add('-- ============================================================');
  sqlStatements.add('');

  // Map to hold latest front photo per memberId: memberId -> { url, timestamp, filename }
  final latestPhotosByMember = <int, Map<String, dynamic>>{};

  try {
    final folders = await supabase.storage.from('face-templates').list();
    print('Scanning ${folders.length} folders in storage...');

    for (var folder in folders) {
      final folderName = folder.name;
      final files = await supabase.storage.from('face-templates').list(path: folderName);

      // Prioritize files containing '_template_front_'
      var frontFiles = files.where((f) => f.name.contains('_template_front_')).toList();
      if (frontFiles.isEmpty) {
        frontFiles = files.where((f) => f.name.contains('_template_')).toList();
      }

      for (var f in frontFiles) {
        final match = RegExp(r'^(\d+)_template').firstMatch(f.name);
        if (match != null) {
          final memberId = int.parse(match.group(1)!);
          
          // Extract numeric timestamp from filename (e.g. ..._1784518928763.jpg)
          final tsMatch = RegExp(r'(\d+)\.(jpg|png|jpeg)$').firstMatch(f.name);
          final timestamp = tsMatch != null ? int.tryParse(tsMatch.group(1)!) ?? 0 : 0;

          final filePath = '$folderName/${f.name}';
          final publicUrl = supabase.storage.from('face-templates').getPublicUrl(filePath);

          if (!latestPhotosByMember.containsKey(memberId) ||
              timestamp > (latestPhotosByMember[memberId]!['timestamp'] as int)) {
            latestPhotosByMember[memberId] = {
              'url': publicUrl,
              'timestamp': timestamp,
              'folder': folderName,
              'filename': f.name,
            };
          }
        }
      }
    }

    int count = 0;
    // Sort by memberId
    final sortedMemberIds = latestPhotosByMember.keys.toList()..sort();

    for (var memberId in sortedMemberIds) {
      final data = latestPhotosByMember[memberId]!;
      final url = data['url'];
      final folder = data['folder'];
      final filename = data['filename'];
      final ts = data['timestamp'];

      print('Member ID $memberId ($folder): $filename (TS: $ts)');

      sqlStatements.add('''
UPDATE public.user_profiles
SET profile_photo_url = '$url', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = $memberId);
''');
      count++;
    }

    sqlStatements.add('');
    sqlStatements.add('SELECT \'OK: Synchronized $count member profile photos\' AS status;');

    final sqlContent = sqlStatements.join('\n');
    final outputFile = File('sync_existing_face_photos.sql');
    await outputFile.writeAsString(sqlContent);

    print('\n✅ SUCCESS: Generated optimized ${outputFile.path} with $count member updates!');
  } catch (e, stack) {
    print('ERROR: $e');
    print(stack);
  }
}
