import 'package:supabase/supabase.dart';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
  );

  print('=== CHECKING FACE-TEMPLATES BUCKET ===');
  try {
    final folders = await supabase.storage.from('face-templates').list();
    print('Found ${folders.length} items in root of face-templates:');
    for (var item in folders) {
      print('  - Item: ${item.name} (isDir: ${item.metadata == null})');
      // If it's a folder (member_id), list its contents
      try {
        final files = await supabase.storage.from('face-templates').list(path: item.name);
        for (var f in files) {
          print('      -> File: ${item.name}/${f.name}');
        }
      } catch (e) {
        print('      -> Could not list subpath ${item.name}: $e');
      }
    }

    print('\n=== CHECKING MEMBERS & USER_PROFILES ===');
    final members = await supabase.from('organization_members').select('''
      id,
      user_id,
      user_profiles (
        id,
        display_name,
        first_name,
        last_name,
        profile_photo_url
      )
    ''');
    print('Found ${members.length} members:');
    for (var m in members) {
      final profile = m['user_profiles'];
      print('Member ID ${m['id']} (User ID ${m['user_id']}): ${profile?['display_name'] ?? profile?['first_name']} -> Photo: ${profile?['profile_photo_url']}');
    }

  } catch (e, stack) {
    print('ERROR: $e');
    print(stack);
  }
}
